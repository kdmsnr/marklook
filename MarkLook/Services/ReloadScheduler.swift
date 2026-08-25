import Darwin
import Foundation

/// Coalesces noisy parent-directory notifications into generation-gated reload work.
///
/// Reading, decoding, and rendering happen through a detached task. Only `.loaded` events may
/// replace the currently displayed DOM; `.failed` leaves `lastSuccessful` untouched.
actor ReloadScheduler<Output: Sendable> {
    typealias Processor = @Sendable (ReloadInput) async throws -> Output

    nonisolated let events: AsyncStream<ReloadSchedulerEvent<Output>>

    private let fileURL: URL
    private let configuration: ReloadSchedulerConfiguration
    private let clock: ReloadSchedulerClock
    private let fileReader: ReloadFileReader
    private let processor: Processor
    private let eventContinuation: AsyncStream<ReloadSchedulerEvent<Output>>.Continuation

    private var firstPendingEvent: ContinuousClock.Instant?
    private var lastPendingEvent: ContinuousClock.Instant?
    private var debounceTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var debounceToken: UInt64 = 0
    private var generationRawValue: UInt64 = 0
    private var latestStartedGeneration: ReloadGeneration?
    private var pendingLoaded: ReloadSnapshot<Output>?
    private(set) var lastSuccessful: ReloadSnapshot<Output>?
    private var isCancelled = false

    init(
        fileURL: URL,
        configuration: ReloadSchedulerConfiguration = .init(),
        clock: ReloadSchedulerClock = .continuous,
        fileReader: ReloadFileReader = .local,
        processor: @escaping Processor
    ) {
        let streamAndContinuation = AsyncStream<ReloadSchedulerEvent<Output>>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )

        self.fileURL = fileURL.standardizedFileURL
        self.configuration = configuration
        self.clock = clock
        self.fileReader = fileReader
        self.processor = processor
        events = streamAndContinuation.stream
        eventContinuation = streamAndContinuation.continuation
    }

    /// Records a filesystem notification. The first event fixes the 100 ms hard deadline, while
    /// subsequent events move only the short quiet-period deadline.
    func signalChange(observedAt: ContinuousClock.Instant? = nil) {
        guard !isCancelled else { return }

        let now = clock.now()
        let eventTime = observedAt ?? now
        firstPendingEvent = firstPendingEvent.map { min($0, eventTime) } ?? eventTime
        lastPendingEvent = lastPendingEvent.map { max($0, eventTime) } ?? eventTime
        armDebounce()
    }

    /// Bypasses coalescing for Command-R and initial document loading.
    @discardableResult
    func reloadNow() -> ReloadGeneration? {
        guard !isCancelled else { return nil }

        clearPendingEvents()
        return beginReload(eventObservedAt: nil)
    }

    func isCurrent(_ generation: ReloadGeneration) -> Bool {
        !isCancelled && latestStartedGeneration == generation
    }

    /// Commits a processed result only after the consumer successfully applied it to the
    /// long-lived WebView. Until this acknowledgement arrives, equal bytes are processed again so
    /// a transient WebView failure cannot make Command-R incorrectly look unchanged.
    @discardableResult
    func acknowledgeApplied(_ generation: ReloadGeneration) -> Bool {
        guard !isCancelled,
              latestStartedGeneration == generation,
              pendingLoaded?.generation == generation,
              let pendingLoaded else {
            return false
        }

        lastSuccessful = pendingLoaded
        self.pendingLoaded = nil
        return true
    }

    /// Stops timers and in-flight work and finishes the event stream. Safe to call repeatedly.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true

        clearPendingEvents()
        reloadTask?.cancel()
        reloadTask = nil
        latestStartedGeneration = nil
        pendingLoaded = nil
        eventContinuation.finish()
    }

    private func armDebounce() {
        guard let firstPendingEvent, let lastPendingEvent else { return }

        debounceTask?.cancel()
        debounceToken &+= 1
        let token = debounceToken

        let quietDeadline = lastPendingEvent.advanced(by: configuration.coalescingDelay)
        let maximumDeadline = firstPendingEvent.advanced(
            by: configuration.maximumCoalescingLatency
        )
        let deadline = min(quietDeadline, maximumDeadline)
        let clock = self.clock

        debounceTask = Task { [weak self] in
            do {
                try await clock.sleepUntil(deadline)
                try Task.checkCancellation()
            } catch {
                return
            }

            await self?.debounceDidFire(token: token)
        }
    }

    private func debounceDidFire(token: UInt64) {
        guard !isCancelled, token == debounceToken, firstPendingEvent != nil else {
            return
        }

        let eventObservedAt = firstPendingEvent
        firstPendingEvent = nil
        lastPendingEvent = nil
        debounceTask = nil
        _ = beginReload(eventObservedAt: eventObservedAt)
    }

    private func clearPendingEvents() {
        debounceToken &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        lastPendingEvent = nil
    }

    @discardableResult
    private func beginReload(
        eventObservedAt: ContinuousClock.Instant?
    ) -> ReloadGeneration {
        precondition(
            generationRawValue < UInt64.max,
            "Reload generation exhausted its UInt64 identifier space"
        )
        generationRawValue += 1
        let generation = ReloadGeneration(rawValue: generationRawValue)
        latestStartedGeneration = generation
        pendingLoaded = nil

        reloadTask?.cancel()

        let fileURL = self.fileURL
        let configuration = self.configuration
        let clock = self.clock
        let fileReader = self.fileReader
        let processor = self.processor
        let schedulerStartedAt = clock.now()
        let eventToProcessing = eventObservedAt.map {
            max(.zero, $0.duration(to: schedulerStartedAt))
        }

        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data: Data
            let readStartedAt = clock.now()

            do {
                data = try await Self.readWithRetry(
                    fileURL: fileURL,
                    configuration: configuration,
                    clock: clock,
                    fileReader: fileReader
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch let failure as PipelineFailure {
                await self?.completeFailure(failure, generation: generation)
                return
            } catch {
                let failure = PipelineFailure(
                    kind: .read,
                    message: Self.message(for: error)
                )
                await self?.completeFailure(failure, generation: generation)
                return
            }
            let readDuration = readStartedAt.duration(to: clock.now())

            let fingerprintStartedAt = clock.now()
            let fingerprint = ContentFingerprint(data: data)
            let fingerprintDuration = fingerprintStartedAt.duration(to: clock.now())
            let decision = await self?.decision(
                for: generation,
                fingerprint: fingerprint
            ) ?? .stale

            switch decision {
            case .stale:
                return
            case .unchanged:
                await self?.completeUnchanged(
                    generation: generation,
                    fingerprint: fingerprint
                )
                return
            case .process:
                break
            }

            let input = ReloadInput(
                generation: generation,
                fileURL: fileURL,
                data: data,
                fingerprint: fingerprint
            )

            do {
                let processStartedAt = clock.now()
                let output = try await processor(input)
                let processCompletedAt = clock.now()
                try Task.checkCancellation()
                await self?.completeLoaded(
                    ReloadSnapshot(
                        generation: generation,
                        fileURL: fileURL,
                        fingerprint: fingerprint,
                        output: output,
                        timing: ReloadTiming(
                            eventToProcessing: eventToProcessing,
                            read: readDuration,
                            fingerprint: fingerprintDuration,
                            process: processStartedAt.duration(to: processCompletedAt),
                            schedulerWork: schedulerStartedAt.duration(to: processCompletedAt)
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.completeFailure(
                    PipelineFailure(kind: .processing, message: Self.message(for: error)),
                    generation: generation
                )
            }
        }

        return generation
    }

    private func decision(
        for generation: ReloadGeneration,
        fingerprint: ContentFingerprint
    ) -> FingerprintDecision {
        guard !isCancelled,
              latestStartedGeneration == generation else {
            return .stale
        }

        return lastSuccessful?.fingerprint == fingerprint ? .unchanged : .process
    }

    private func completeLoaded(_ snapshot: ReloadSnapshot<Output>) {
        guard !isCancelled,
              latestStartedGeneration == snapshot.generation else {
            return
        }

        pendingLoaded = snapshot
        reloadTask = nil
        eventContinuation.yield(.loaded(snapshot))
    }

    private func completeUnchanged(
        generation: ReloadGeneration,
        fingerprint: ContentFingerprint
    ) {
        guard !isCancelled,
              latestStartedGeneration == generation else {
            return
        }

        reloadTask = nil
        eventContinuation.yield(.unchanged(generation: generation, fingerprint: fingerprint))
    }

    private func completeFailure(
        _ pipelineFailure: PipelineFailure,
        generation: ReloadGeneration
    ) {
        guard !isCancelled,
              latestStartedGeneration == generation else {
            return
        }

        reloadTask = nil
        eventContinuation.yield(
            .failed(
                ReloadFailure(
                    generation: generation,
                    fileURL: fileURL,
                    kind: pipelineFailure.kind,
                    message: pipelineFailure.message,
                    lastSuccessfulGeneration: lastSuccessful?.generation
                )
            )
        )
    }

    private nonisolated static func readWithRetry(
        fileURL: URL,
        configuration: ReloadSchedulerConfiguration,
        clock: ReloadSchedulerClock,
        fileReader: ReloadFileReader
    ) async throws -> Data {
        let retryDeadline = clock.now().advanced(by: configuration.missingFileRetryWindow)

        while true {
            try Task.checkCancellation()

            do {
                return try fileReader.read(fileURL)
            } catch {
                guard isMissingFileError(error) else {
                    throw PipelineFailure(kind: .read, message: message(for: error))
                }

                let now = clock.now()
                guard now < retryDeadline else {
                    throw PipelineFailure(
                        kind: .temporarilyMissing,
                        message: "The file is still unavailable after the retry window."
                    )
                }

                let nextAttempt = min(
                    now.advanced(by: configuration.missingFileRetryDelay),
                    retryDeadline
                )
                try await clock.sleepUntil(nextAttempt)
            }
        }
    }

    private nonisolated static func isMissingFileError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError
        }
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT)
        }
        return false
    }

    private nonisolated static func message(for error: any Error) -> String {
        (error as NSError).localizedDescription
    }
}

extension ReloadScheduler where Output == Data {
    init(
        fileURL: URL,
        configuration: ReloadSchedulerConfiguration = .init(),
        clock: ReloadSchedulerClock = .continuous,
        fileReader: ReloadFileReader = .local
    ) {
        self.init(
            fileURL: fileURL,
            configuration: configuration,
            clock: clock,
            fileReader: fileReader,
            processor: { input in input.data }
        )
    }
}

private enum FingerprintDecision: Sendable {
    case stale
    case unchanged
    case process
}

private struct PipelineFailure: Error, Sendable {
    let kind: ReloadFailureKind
    let message: String
}
