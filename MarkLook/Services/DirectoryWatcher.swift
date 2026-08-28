import Darwin
import Dispatch
import Foundation

struct DirectoryChangeKind: OptionSet, Sendable, Equatable {
    let rawValue: UInt16

    static let contentsChanged = Self(rawValue: 1 << 0)
    static let metadataChanged = Self(rawValue: 1 << 1)
    static let directoryRenamed = Self(rawValue: 1 << 2)
    static let directoryDeleted = Self(rawValue: 1 << 3)
    static let accessRevoked = Self(rawValue: 1 << 4)
}

struct DirectoryChange: Sendable, Equatable {
    let watchedDirectoryURL: URL
    let targetFileURL: URL
    let kinds: DirectoryChangeKind
    let observedAt: ContinuousClock.Instant

    var directoryMayBeInvalid: Bool {
        !kinds.intersection([.directoryRenamed, .directoryDeleted, .accessRevoked]).isEmpty
    }
}

enum DirectoryWatcherError: LocalizedError, Sendable, Equatable {
    case fileURLRequired
    case alreadyRunning
    case cannotOpenDirectory(URL, POSIXErrorCode?)

    var errorDescription: String? {
        switch self {
        case .fileURLRequired:
            "DirectoryWatcher requires a local file URL."
        case .alreadyRunning:
            "The directory watcher is already running."
        case let .cannotOpenDirectory(url, code):
            if let code {
                "Could not monitor \(url.path): \(String(cString: strerror(code.rawValue)))."
            } else {
                "Could not monitor \(url.path)."
            }
        }
    }
}

/// Small type-erased boundary around DispatchSource so lifecycle behavior can be unit tested
/// without depending on filesystem timing.
protocol DirectoryWatchingSource: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (UInt) -> Void)
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void)
    func activate()
    func cancel()
}

typealias DirectoryWatchingSourceFactory = @Sendable (
    _ descriptor: Int32,
    _ eventMaskRawValue: UInt,
    _ queue: DispatchQueue
) -> any DirectoryWatchingSource

private final class SystemDirectoryWatchingSource: DirectoryWatchingSource, @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init(
        descriptor: Int32,
        eventMaskRawValue: UInt,
        queue: DispatchQueue
    ) {
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: DispatchSource.FileSystemEvent(rawValue: eventMaskRawValue),
            queue: queue
        )
    }

    func setEventHandler(
        _ handler: @escaping @Sendable (UInt) -> Void
    ) {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            handler(source.data.rawValue)
        }
    }

    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setCancelHandler(handler: handler)
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

/// Watches both the containing directory and the current document inode. The directory source
/// survives atomic saves, while the document source catches editors that truncate and rewrite the
/// existing inode. Directory notifications refresh the document source after an inode replacement.
final class DirectoryWatcher: @unchecked Sendable {
    typealias OpenDirectory = @Sendable (URL) -> Int32
    typealias OpenTargetFile = @Sendable (URL) -> Int32
    typealias CloseDescriptor = @Sendable (Int32) -> Void

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    let targetFileURL: URL
    let watchedDirectoryURL: URL

    private static var eventMaskRawValue: UInt {
        DispatchSource.FileSystemEvent([
            .write,
            .extend,
            .attrib,
            .link,
            .rename,
            .delete,
            .revoke,
        ]).rawValue
    }

    private let queue: DispatchQueue
    private let sourceFactory: DirectoryWatchingSourceFactory
    private let openDirectory: OpenDirectory
    private let openTargetFile: OpenTargetFile
    private let closeDescriptor: CloseDescriptor
    private let lock = NSLock()

    private var directorySource: (any DirectoryWatchingSource)?
    private var targetSource: (any DirectoryWatchingSource)?
    private var eventHandler: (@Sendable (DirectoryChange) -> Void)?
    private var watchToken: UUID?
    private var targetSourceToken: UUID?
    private var targetIdentity: FileIdentity?
    private var targetRetryToken: UUID?

    convenience init(fileURL: URL, queue: DispatchQueue? = nil) throws {
        try self.init(
            fileURL: fileURL,
            queue: queue,
            sourceFactory: { descriptor, maskRawValue, queue in
                SystemDirectoryWatchingSource(
                    descriptor: descriptor,
                    eventMaskRawValue: maskRawValue,
                    queue: queue
                )
            },
            openDirectory: { directoryURL in
                directoryURL.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return -1 }
                    return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
                }
            },
            openTargetFile: { targetURL in
                targetURL.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return -1 }
                    return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
                }
            },
            closeDescriptor: { descriptor in
                _ = Darwin.close(descriptor)
            }
        )
    }

    init(
        fileURL: URL,
        queue: DispatchQueue? = nil,
        sourceFactory: @escaping DirectoryWatchingSourceFactory,
        openDirectory: @escaping OpenDirectory,
        openTargetFile: @escaping OpenTargetFile,
        closeDescriptor: @escaping CloseDescriptor
    ) throws {
        guard fileURL.isFileURL else {
            throw DirectoryWatcherError.fileURLRequired
        }

        let standardizedTarget = fileURL.standardizedFileURL
        targetFileURL = standardizedTarget
        watchedDirectoryURL = standardizedTarget.deletingLastPathComponent()
        self.queue = queue ?? DispatchQueue(
            label: "com.marklook.directory-watcher",
            qos: .userInitiated
        )
        self.sourceFactory = sourceFactory
        self.openDirectory = openDirectory
        self.openTargetFile = openTargetFile
        self.closeDescriptor = closeDescriptor
    }

    /// Starts a source for the target's current inode and, when sandbox access allows it, a
    /// parent-directory source as replacement/reappearance insurance. Either source is sufficient
    /// to start; unrelated directory events and duplicates are filtered by the reload scheduler.
    func start(handler: @escaping @Sendable (DirectoryChange) -> Void) throws {
        lock.lock()

        guard watchToken == nil else {
            lock.unlock()
            throw DirectoryWatcherError.alreadyRunning
        }

        let token = UUID()
        watchToken = token
        eventHandler = handler

        let descriptor = openDirectory(watchedDirectoryURL)
        let directoryOpenError: POSIXErrorCode?
        if descriptor >= 0 {
            directoryOpenError = nil
            let newSource = sourceFactory(descriptor, Self.eventMaskRawValue, queue)
            newSource.setCancelHandler { [closeDescriptor] in
                closeDescriptor(descriptor)
            }
            newSource.setEventHandler { [weak self] flagsRawValue in
                self?.handleDirectoryEvent(flagsRawValue: flagsRawValue, watchToken: token)
            }
            directorySource = newSource
            newSource.activate()
        } else {
            directoryOpenError = POSIXErrorCode(rawValue: errno)
        }
        lock.unlock()

        _ = refreshTargetSource(watchToken: token)

        let didStart = lock.withLock {
            watchToken == token && (directorySource != nil || targetSource != nil)
        }
        guard didStart else {
            lock.withLock {
                guard watchToken == token else { return }
                watchToken = nil
                eventHandler = nil
            }
            throw DirectoryWatcherError.cannotOpenDirectory(
                watchedDirectoryURL,
                directoryOpenError
            )
        }
    }

    /// Cancellation is idempotent. The descriptor is closed by the source cancellation handler,
    /// after Dispatch has stopped using it.
    func cancel() {
        lock.lock()
        let directorySourceToCancel = directorySource
        let targetSourceToCancel = targetSource
        directorySource = nil
        targetSource = nil
        watchToken = nil
        targetSourceToken = nil
        targetIdentity = nil
        targetRetryToken = nil
        eventHandler = nil
        lock.unlock()

        directorySourceToCancel?.cancel()
        targetSourceToCancel?.cancel()
    }

    deinit {
        cancel()
    }

    private func handleDirectoryEvent(
        flagsRawValue: UInt,
        watchToken token: UUID
    ) {
        deliverDirectoryEvent(flagsRawValue: flagsRawValue, watchToken: token)
        if !refreshTargetSource(watchToken: token) {
            beginTargetReattachment(watchToken: token)
        }
    }

    private func handleTargetEvent(
        flagsRawValue: UInt,
        watchToken expectedWatchToken: UUID,
        targetSourceToken expectedSourceToken: UUID
    ) {
        let flags = DispatchSource.FileSystemEvent(rawValue: flagsRawValue)
        let targetWasInvalidated = !flags.intersection([.rename, .delete, .revoke]).isEmpty

        let handler: (@Sendable (DirectoryChange) -> Void)? = lock.withLock {
            guard watchToken == expectedWatchToken,
                  targetSourceToken == expectedSourceToken else {
                return nil
            }
            if targetWasInvalidated {
                targetIdentity = nil
            }
            return eventHandler
        }

        guard let handler else { return }
        deliver(flagsRawValue: flagsRawValue, to: handler)

        if targetWasInvalidated,
           !refreshTargetSource(watchToken: expectedWatchToken) {
            beginTargetReattachment(watchToken: expectedWatchToken)
        }
    }

    private func deliverDirectoryEvent(
        flagsRawValue: UInt,
        watchToken expectedWatchToken: UUID
    ) {
        let handler: (@Sendable (DirectoryChange) -> Void)? = lock.withLock {
            guard watchToken == expectedWatchToken else { return nil }
            return eventHandler
        }

        guard let handler else { return }
        deliver(flagsRawValue: flagsRawValue, to: handler)
    }

    private func deliver(
        flagsRawValue: UInt,
        to handler: @escaping @Sendable (DirectoryChange) -> Void
    ) {
        let observedAt = ContinuousClock().now

        handler(
            DirectoryChange(
                watchedDirectoryURL: watchedDirectoryURL,
                targetFileURL: targetFileURL,
                kinds: Self.changeKinds(forRawValue: flagsRawValue),
                observedAt: observedAt
            )
        )
    }

    /// Opens the current path before taking the lock. If cancellation or a newer start wins the
    /// race, the candidate descriptor is closed without publishing a source. Comparing the opened
    /// descriptor's identity avoids tearing down the inode source for unrelated directory writes.
    @discardableResult
    private func refreshTargetSource(watchToken expectedWatchToken: UUID) -> Bool {
        let descriptor = openTargetFile(targetFileURL)
        guard descriptor >= 0 else { return false }
        guard let identity = Self.fileIdentity(for: descriptor) else {
            closeDescriptor(descriptor)
            return false
        }

        lock.lock()
        guard watchToken == expectedWatchToken else {
            lock.unlock()
            closeDescriptor(descriptor)
            return false
        }
        guard targetSource == nil || targetIdentity != identity else {
            targetRetryToken = nil
            lock.unlock()
            closeDescriptor(descriptor)
            return true
        }

        let replacementSource = sourceFactory(descriptor, Self.eventMaskRawValue, queue)
        let replacementToken = UUID()
        replacementSource.setCancelHandler { [closeDescriptor] in
            closeDescriptor(descriptor)
        }
        replacementSource.setEventHandler { [weak self] flagsRawValue in
            self?.handleTargetEvent(
                flagsRawValue: flagsRawValue,
                watchToken: expectedWatchToken,
                targetSourceToken: replacementToken
            )
        }

        let sourceToCancel = targetSource
        targetSource = replacementSource
        targetSourceToken = replacementToken
        targetIdentity = identity
        targetRetryToken = nil
        replacementSource.activate()
        lock.unlock()

        sourceToCancel?.cancel()
        return true
    }

    private func beginTargetReattachment(watchToken expectedWatchToken: UUID) {
        let retryToken: UUID? = lock.withLock {
            guard watchToken == expectedWatchToken, targetRetryToken == nil else {
                return nil
            }
            let token = UUID()
            targetRetryToken = token
            return token
        }
        guard let retryToken else { return }
        scheduleTargetReattachment(
            watchToken: expectedWatchToken,
            retryToken: retryToken,
            remainingRapidAttempts: 20,
            delayMilliseconds: 25
        )
    }

    private func scheduleTargetReattachment(
        watchToken expectedWatchToken: UUID,
        retryToken expectedRetryToken: UUID,
        remainingRapidAttempts: Int,
        delayMilliseconds: Int
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            let isCurrent = self.lock.withLock {
                self.watchToken == expectedWatchToken
                    && self.targetRetryToken == expectedRetryToken
            }
            guard isCurrent else { return }

            if self.refreshTargetSource(watchToken: expectedWatchToken) {
                return
            }

            let nextRapidAttempts = max(0, remainingRapidAttempts - 1)
            // Keep the 25 ms retry cadence for ordinary atomic saves, then back off instead of
            // abandoning a target-only watcher. A file-scoped sandbox grant can deny access to the
            // parent directory, leaving this retry as the only way to observe a later replacement
            // inode. The retry token makes the chain stop promptly on cancellation or success.
            let nextDelayMilliseconds = if remainingRapidAttempts > 1 {
                25
            } else {
                min(max(delayMilliseconds * 2, 500), 5_000)
            }
            self.scheduleTargetReattachment(
                watchToken: expectedWatchToken,
                retryToken: expectedRetryToken,
                remainingRapidAttempts: nextRapidAttempts,
                delayMilliseconds: nextDelayMilliseconds
            )
        }
    }

    private static func fileIdentity(for descriptor: Int32) -> FileIdentity? {
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { return nil }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func changeKinds(
        forRawValue rawValue: UInt
    ) -> DirectoryChangeKind {
        let flags = DispatchSource.FileSystemEvent(rawValue: rawValue)
        var kinds: DirectoryChangeKind = []

        if !flags.intersection([.write, .extend, .link]).isEmpty {
            kinds.insert(.contentsChanged)
        }
        if flags.contains(.attrib) {
            kinds.insert(.metadataChanged)
        }
        if flags.contains(.rename) {
            kinds.insert(.directoryRenamed)
        }
        if flags.contains(.delete) {
            kinds.insert(.directoryDeleted)
        }
        if flags.contains(.revoke) {
            kinds.insert(.accessRevoked)
        }

        return kinds
    }
}
