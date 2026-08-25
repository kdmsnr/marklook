import Foundation
import XCTest
@testable import MarkLook

final class ReloadSchedulerTests: XCTestCase {
    func testConcurrentImmediateRequestsReceiveUniqueMonotonicGenerations() async throws {
        let scheduler = ReloadScheduler<Data>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            fileReader: ReloadFileReader { _ in Data("content".utf8) }
        )

        let generations = await withTaskGroup(
            of: ReloadGeneration?.self,
            returning: [ReloadGeneration].self
        ) { group in
            for _ in 0..<32 {
                group.addTask { await scheduler.reloadNow() }
            }

            var values: [ReloadGeneration] = []
            for await generation in group {
                if let generation { values.append(generation) }
            }
            return values.sorted()
        }

        XCTAssertEqual(generations.map(\.rawValue), Array(1...32).map(UInt64.init))
        await scheduler.cancel()
    }

    func testContinuousEventsBeginWorkAtMaximumLatency() async throws {
        let clock = ManualReloadClock()
        let processTimes = ReloadLockedBox<[Duration]>([])
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            clock: clock.schedulerClock,
            fileReader: ReloadFileReader { _ in Data("content".utf8) },
            processor: { input in
                processTimes.withValue { $0.append(clock.elapsed) }
                return String(decoding: input.data, as: UTF8.self)
            }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        await scheduler.signalChange()
        try await waitForReloadCondition("initial debounce sleeper") {
            clock.hasSleeper(at: .milliseconds(16))
        }

        for millisecond in stride(from: 10, through: 90, by: 10) {
            clock.advance(by: .milliseconds(10))
            await scheduler.signalChange()
            let expected = min(millisecond + 16, 100)
            try await waitForReloadCondition("debounce sleeper at \(expected) ms") {
                clock.hasSleeper(at: .milliseconds(expected))
            }
        }

        clock.advance(by: .milliseconds(9))
        await Task.yield()
        XCTAssertTrue(processTimes.value.isEmpty)

        clock.advance(by: .milliseconds(1))
        try await waitForReloadCondition("loaded event at hard deadline") {
            await recorder.loadedOutputs == ["content"]
        }

        XCTAssertEqual(processTimes.value.count, 1)
        XCTAssertLessThanOrEqual(processTimes.value[0], .milliseconds(100))
        await scheduler.cancel()
    }

    func testUnchangedContentSkipsProcessingAndDisplayReplacement() async throws {
        let processCount = ReloadLockedBox(0)
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            fileReader: ReloadFileReader { _ in Data("same bytes".utf8) },
            processor: { input in
                processCount.withValue { $0 += 1 }
                return String(decoding: input.data, as: UTF8.self)
            }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        let firstGenerationValue = await scheduler.reloadNow()
        let firstGeneration = try XCTUnwrap(firstGenerationValue)
        try await waitForReloadCondition("first loaded event") {
            await recorder.loadedOutputs.count == 1
        }
        let firstWasAcknowledged = await scheduler.acknowledgeApplied(firstGeneration)
        XCTAssertTrue(firstWasAcknowledged)

        let secondGenerationValue = await scheduler.reloadNow()
        let secondGeneration = try XCTUnwrap(secondGenerationValue)
        try await waitForReloadCondition("unchanged event") {
            await recorder.unchangedGenerations.count == 1
        }

        XCTAssertLessThan(firstGeneration, secondGeneration)
        XCTAssertEqual(processCount.value, 1)
        let loadedOutputs = await recorder.loadedOutputs
        let unchangedGenerations = await recorder.unchangedGenerations
        XCTAssertEqual(loadedOutputs, ["same bytes"])
        XCTAssertEqual(unchangedGenerations, [secondGeneration])
        await scheduler.cancel()
    }

    func testStaleNonCooperativeProcessorCannotPublishAfterNewGeneration() async throws {
        let source = ReloadLockedBox(Data("old".utf8))
        let oldProcessorGate = AsyncTestGate()
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            fileReader: ReloadFileReader { _ in source.value },
            processor: { input in
                let text = String(decoding: input.data, as: UTF8.self)
                if text == "old" {
                    await oldProcessorGate.wait()
                }
                return text
            }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        let firstGenerationValue = await scheduler.reloadNow()
        let firstGeneration = try XCTUnwrap(firstGenerationValue)
        try await waitForReloadCondition("old processor to start") {
            await oldProcessorGate.waiterCount == 1
        }

        source.withValue { $0 = Data("new".utf8) }
        let secondGenerationValue = await scheduler.reloadNow()
        let secondGeneration = try XCTUnwrap(secondGenerationValue)
        try await waitForReloadCondition("new generation result") {
            await recorder.loadedOutputs == ["new"]
        }
        let secondWasAcknowledged = await scheduler.acknowledgeApplied(secondGeneration)
        XCTAssertTrue(secondWasAcknowledged)

        await oldProcessorGate.open()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertLessThan(firstGeneration, secondGeneration)
        let loadedGenerations = await recorder.loadedGenerations
        let lastSuccessful = await scheduler.lastSuccessful
        XCTAssertEqual(loadedGenerations, [secondGeneration])
        XCTAssertEqual(lastSuccessful?.output, "new")
        await scheduler.cancel()
    }

    func testUnacknowledgedDisplayResultIsRetriedInsteadOfMarkedUnchanged() async throws {
        let source = ReloadLockedBox(Data("displayed".utf8))
        let processCount = ReloadLockedBox(0)
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            fileReader: ReloadFileReader { _ in source.value },
            processor: { input in
                processCount.withValue { $0 += 1 }
                return String(decoding: input.data, as: UTF8.self)
            }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        let displayedGenerationValue = await scheduler.reloadNow()
        let displayedGeneration = try XCTUnwrap(displayedGenerationValue)
        try await waitForReloadCondition("displayed generation") {
            await recorder.loadedOutputs.count == 1
        }
        let displayedWasAcknowledged = await scheduler.acknowledgeApplied(displayedGeneration)
        XCTAssertTrue(displayedWasAcknowledged)

        source.withValue { $0 = Data("web apply failed".utf8) }
        let unacknowledgedGenerationValue = await scheduler.reloadNow()
        _ = try XCTUnwrap(unacknowledgedGenerationValue)
        try await waitForReloadCondition("unacknowledged generation") {
            await recorder.loadedOutputs.count == 2
        }

        let retained = await scheduler.lastSuccessful
        XCTAssertEqual(retained?.output, "displayed")

        let retryGenerationValue = await scheduler.reloadNow()
        let retryGeneration = try XCTUnwrap(retryGenerationValue)
        try await waitForReloadCondition("retry after display failure") {
            await recorder.loadedOutputs.count == 3
        }

        XCTAssertEqual(processCount.value, 3)
        let unchangedGenerations = await recorder.unchangedGenerations
        XCTAssertTrue(unchangedGenerations.isEmpty)
        let retryWasAcknowledged = await scheduler.acknowledgeApplied(retryGeneration)
        XCTAssertTrue(retryWasAcknowledged)
        let lastSuccessful = await scheduler.lastSuccessful
        XCTAssertEqual(lastSuccessful?.output, "web apply failed")
        await scheduler.cancel()
    }

    func testTemporaryMissingFileRetriesAndRecovers() async throws {
        let clock = ManualReloadClock()
        let source = ReloadLockedBox<ReaderState>(.missing)
        let readCount = ReloadLockedBox(0)
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            clock: clock.schedulerClock,
            fileReader: ReloadFileReader { _ in
                readCount.withValue { $0 += 1 }
                switch source.value {
                case let .data(data):
                    return data
                case .missing:
                    throw CocoaError(.fileReadNoSuchFile)
                }
            },
            processor: { String(decoding: $0.data, as: UTF8.self) }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        _ = await scheduler.reloadNow()
        try await waitForReloadCondition("first missing-file retry") {
            clock.hasSleeper(at: .milliseconds(25))
        }

        clock.advance(by: .milliseconds(25))
        try await waitForReloadCondition("second missing-file retry") {
            clock.hasSleeper(at: .milliseconds(50))
        }

        source.withValue { $0 = .data(Data("reappeared".utf8)) }
        clock.advance(by: .milliseconds(25))
        try await waitForReloadCondition("recovered load") {
            await recorder.loadedOutputs == ["reappeared"]
        }

        XCTAssertGreaterThanOrEqual(readCount.value, 3)
        let failures = await recorder.failures
        XCTAssertTrue(failures.isEmpty)
        await scheduler.cancel()
    }

    func testFailureAfterRetryWindowPreservesLastSuccessfulResult() async throws {
        let clock = ManualReloadClock()
        let source = ReloadLockedBox<ReaderState>(.data(Data("last good".utf8)))
        let recorder = ReloadEventRecorder<String>()
        let scheduler = ReloadScheduler<String>(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            clock: clock.schedulerClock,
            fileReader: ReloadFileReader { _ in
                switch source.value {
                case let .data(data):
                    return data
                case .missing:
                    throw CocoaError(.fileReadNoSuchFile)
                }
            },
            processor: { String(decoding: $0.data, as: UTF8.self) }
        )
        let consumer = startEventRecording(scheduler.events, in: recorder)
        defer { consumer.cancel() }

        let successfulGenerationValue = await scheduler.reloadNow()
        let successfulGeneration = try XCTUnwrap(successfulGenerationValue)
        try await waitForReloadCondition("initial successful load") {
            await recorder.loadedOutputs == ["last good"]
        }
        let successWasAcknowledged = await scheduler.acknowledgeApplied(successfulGeneration)
        XCTAssertTrue(successWasAcknowledged)

        source.withValue { $0 = .missing }
        let failedGenerationValue = await scheduler.reloadNow()
        let failedGeneration = try XCTUnwrap(failedGenerationValue)
        try await waitForReloadCondition("missing-file retry") {
            clock.hasSleeper(at: .milliseconds(25))
        }

        clock.advance(by: .milliseconds(500))
        try await waitForReloadCondition("retry-window failure") {
            await recorder.failures.count == 1
        }

        let recordedFailures = await recorder.failures
        let failure = try XCTUnwrap(recordedFailures.first)
        XCTAssertEqual(failure.kind, .temporarilyMissing)
        XCTAssertEqual(failure.generation, failedGeneration)
        XCTAssertEqual(failure.lastSuccessfulGeneration, successfulGeneration)
        let loadedOutputs = await recorder.loadedOutputs
        let lastSuccessful = await scheduler.lastSuccessful
        XCTAssertEqual(loadedOutputs, ["last good"])
        XCTAssertEqual(lastSuccessful?.output, "last good")
        await scheduler.cancel()
    }
}

private enum ReaderState: Sendable {
    case data(Data)
    case missing
}

private actor ReloadEventRecorder<Output: Sendable> {
    private var events: [ReloadSchedulerEvent<Output>] = []

    func append(_ event: ReloadSchedulerEvent<Output>) {
        events.append(event)
    }

    var loadedOutputs: [Output] {
        events.compactMap {
            guard case let .loaded(snapshot) = $0 else { return nil }
            return snapshot.output
        }
    }

    var loadedGenerations: [ReloadGeneration] {
        events.compactMap {
            guard case let .loaded(snapshot) = $0 else { return nil }
            return snapshot.generation
        }
    }

    var unchangedGenerations: [ReloadGeneration] {
        events.compactMap {
            guard case let .unchanged(generation, _) = $0 else { return nil }
            return generation
        }
    }

    var failures: [ReloadFailure] {
        events.compactMap {
            guard case let .failed(failure) = $0 else { return nil }
            return failure
        }
    }
}

private func startEventRecording<Output: Sendable>(
    _ stream: AsyncStream<ReloadSchedulerEvent<Output>>,
    in recorder: ReloadEventRecorder<Output>
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await recorder.append(event)
        }
    }
}

private final class ManualReloadClock: @unchecked Sendable {
    private typealias Sleeper = (
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<Void, any Error>
    )

    private let lock = NSLock()
    private let origin: ContinuousClock.Instant
    private var instant: ContinuousClock.Instant
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []

    init() {
        let now = ContinuousClock().now
        origin = now
        instant = now
    }

    var schedulerClock: ReloadSchedulerClock {
        ReloadSchedulerClock(
            now: { self.now },
            sleepUntil: { deadline in try await self.sleep(until: deadline) }
        )
    }

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    var elapsed: Duration {
        lock.withLock { origin.duration(to: instant) }
    }

    func hasSleeper(at offset: Duration) -> Bool {
        let deadline = origin.advanced(by: offset)
        return lock.withLock {
            sleepers.values.contains { $0.deadline == deadline }
        }
    }

    func advance(by duration: Duration) {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            instant = instant.advanced(by: duration)
            let readyIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= instant ? id : nil
            }
            return readyIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: SleepRegistrationAction = lock.withLock {
                    if cancelledSleeperIDs.remove(id) != nil {
                        return .cancel
                    }
                    if deadline <= instant {
                        return .complete
                    }
                    sleepers[id] = (deadline, continuation)
                    return .wait
                }

                switch action {
                case .wait:
                    break
                case .complete:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleeper(id: id)
        }
    }

    private func cancelSleeper(id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            if let sleeper = sleepers.removeValue(forKey: id) {
                return sleeper.continuation
            }
            cancelledSleeperIDs.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private enum SleepRegistrationAction {
    case wait
    case complete
    case cancel
}

private actor AsyncTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        let continuations = self.continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class ReloadLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storedValue)
        }
    }
}

private func waitForReloadCondition(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !(await condition()) {
        if clock.now >= deadline {
            XCTFail("Timed out waiting for \(description)")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
