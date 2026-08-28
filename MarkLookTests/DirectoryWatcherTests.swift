import Dispatch
import Foundation
import XCTest
@testable import MarkLook

final class DirectoryWatcherTests: XCTestCase {
    func testWatcherOpensParentAndStaysActiveAcrossReplacementSignals() throws {
        let targetURL = URL(fileURLWithPath: "/tmp/marklook-tests/article.md")
        let fakeSource = TestDirectorySource()
        let openedURLs = LockedBox<[URL]>([])
        let closedDescriptors = LockedBox<[Int32]>([])
        let changes = LockedBox<[DirectoryChange]>([])
        let capturedMask = LockedBox<UInt?>(nil)

        let watcher = try DirectoryWatcher(
            fileURL: targetURL,
            sourceFactory: { _, maskRawValue, _ in
                capturedMask.withValue { $0 = maskRawValue }
                return fakeSource
            },
            openDirectory: { url in
                openedURLs.withValue { $0.append(url) }
                return 41
            },
            openTargetFile: { _ in -1 },
            closeDescriptor: { descriptor in
                closedDescriptors.withValue { $0.append(descriptor) }
            }
        )

        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }

        XCTAssertEqual(openedURLs.value, [targetURL.deletingLastPathComponent()])
        XCTAssertTrue(fakeSource.isActive)
        XCTAssertEqual(fakeSource.activationCount, 1)

        let mask = DispatchSource.FileSystemEvent(
            rawValue: try XCTUnwrap(capturedMask.value)
        )
        XCTAssertTrue(mask.contains(.write))
        XCTAssertTrue(mask.contains(.rename))

        // Atomic saves replace the document inode, but both notifications arrive through the
        // same parent-directory source and therefore require no watcher restart.
        fakeSource.emit([.write, .rename])
        fakeSource.emit(.write)

        XCTAssertEqual(changes.value.count, 2)
        XCTAssertEqual(changes.value[0].targetFileURL, targetURL)
        XCTAssertTrue(changes.value[0].kinds.contains(.contentsChanged))
        XCTAssertTrue(changes.value[0].kinds.contains(.directoryRenamed))
        XCTAssertEqual(fakeSource.activationCount, 1)

        watcher.cancel()
        watcher.cancel()

        XCTAssertTrue(fakeSource.isCancelled)
        XCTAssertEqual(fakeSource.cancellationCount, 1)
        XCTAssertEqual(closedDescriptors.value, [41])
    }

    func testLateEventFromCancelledSourceIsIgnoredAfterRestart() throws {
        let targetURL = URL(fileURLWithPath: "/tmp/marklook-tests/article.md")
        let firstSource = TestDirectorySource()
        let secondSource = TestDirectorySource()
        let sources = LockedBox([firstSource, secondSource])
        let changes = LockedBox<[DirectoryChange]>([])

        let watcher = try DirectoryWatcher(
            fileURL: targetURL,
            sourceFactory: { _, _, _ in
                sources.withValue { $0.removeFirst() }
            },
            openDirectory: { _ in 42 },
            openTargetFile: { _ in -1 },
            closeDescriptor: { _ in }
        )

        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }
        watcher.cancel()
        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }

        firstSource.emit(.write)
        secondSource.emit(.write)

        XCTAssertEqual(changes.value.count, 1)
        watcher.cancel()
    }

    func testRejectsNonFileURL() {
        XCTAssertThrowsError(try DirectoryWatcher(fileURL: URL(string: "https://example.com/a.md")!)) {
            XCTAssertEqual($0 as? DirectoryWatcherError, .fileURLRequired)
        }
    }

    func testSystemWatcherObservesAtomicWriteThroughParentDirectory() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("old".utf8).write(to: fileURL)

        let changes = LockedBox<[DirectoryChange]>([])
        let watcher = try DirectoryWatcher(fileURL: fileURL)
        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }

        try Data("new".utf8).write(to: fileURL, options: .atomic)

        try await waitUntil("atomic directory event") {
            !changes.value.isEmpty
        }
        watcher.cancel()

        XCTAssertTrue(changes.value.contains { $0.kinds.contains(.contentsChanged) })
    }

    func testStartsWithTargetSourceWhenParentDirectoryCannotBeOpened() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("content".utf8).write(to: fileURL)

        let targetSource = TestDirectorySource()
        let changes = LockedBox<[DirectoryChange]>([])
        let watcher = try DirectoryWatcher(
            fileURL: fileURL,
            sourceFactory: { _, _, _ in targetSource },
            openDirectory: { _ in
                errno = EACCES
                return -1
            },
            openTargetFile: { url in
                url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
                }
            },
            closeDescriptor: { descriptor in
                _ = Darwin.close(descriptor)
            }
        )

        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }
        targetSource.emit(.write)

        XCTAssertTrue(targetSource.isActive)
        XCTAssertEqual(changes.value.count, 1)
        XCTAssertTrue(changes.value[0].kinds.contains(.contentsChanged))

        watcher.cancel()
        XCTAssertEqual(targetSource.cancellationCount, 1)
    }

    func testSystemWatcherObservesInPlaceWriteThroughTargetInode() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("old".utf8).write(to: fileURL)

        let inodeBeforeWrite = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? NSNumber
        )
        let changes = LockedBox<[DirectoryChange]>([])
        let watcher = try DirectoryWatcher(fileURL: fileURL)
        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }
        try await Task.sleep(for: .milliseconds(50))

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new in place".utf8))
        try handle.synchronize()
        try handle.close()

        try await waitUntil("in-place target event") {
            changes.value.contains { $0.kinds.contains(.contentsChanged) }
        }
        watcher.cancel()

        let inodeAfterWrite = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? NSNumber
        )
        let observedChanges = changes.value
        XCTAssertEqual(inodeAfterWrite, inodeBeforeWrite)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("new in place".utf8))
        XCTAssertTrue(
            observedChanges.contains { $0.kinds.contains(.contentsChanged) },
            "Observed \(observedChanges.count) directory events: \(observedChanges.map(\.kinds.rawValue))"
        )
    }

    func testTargetSourceIsRearmedAfterAtomicReplacementAndCancelledExactlyOnce() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("old".utf8).write(to: fileURL)

        let directorySource = TestDirectorySource()
        let originalTargetSource = TestDirectorySource()
        let replacementTargetSource = TestDirectorySource()
        let availableSources = LockedBox([
            directorySource,
            originalTargetSource,
            replacementTargetSource,
        ])
        let openedDescriptors = LockedBox<[Int32]>([])
        let closedDescriptors = LockedBox<[Int32]>([])
        let changes = LockedBox<[DirectoryChange]>([])

        let openEventOnly: @Sendable (URL) -> Int32 = { url in
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            }
            if descriptor >= 0 {
                openedDescriptors.withValue { $0.append(descriptor) }
            }
            return descriptor
        }
        let watcher = try DirectoryWatcher(
            fileURL: fileURL,
            sourceFactory: { _, _, _ in
                availableSources.withValue { $0.removeFirst() }
            },
            openDirectory: openEventOnly,
            openTargetFile: openEventOnly,
            closeDescriptor: { descriptor in
                _ = Darwin.close(descriptor)
                closedDescriptors.withValue { $0.append(descriptor) }
            }
        )
        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }

        XCTAssertTrue(directorySource.isActive)
        XCTAssertTrue(originalTargetSource.isActive)
        XCTAssertFalse(replacementTargetSource.isActive)

        let originalInode = try fileInode(at: fileURL)
        try Data("atomic replacement".utf8).write(to: fileURL, options: .atomic)
        let replacementInode = try fileInode(at: fileURL)
        XCTAssertNotEqual(originalInode, replacementInode)

        directorySource.emit(.write)

        XCTAssertTrue(originalTargetSource.isCancelled)
        XCTAssertTrue(replacementTargetSource.isActive)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("after replacement".utf8))
        try handle.synchronize()
        try handle.close()
        replacementTargetSource.emit(.write)

        XCTAssertTrue(changes.value.contains { $0.kinds.contains(.contentsChanged) })
        let changeCountBeforeCancellation = changes.value.count

        watcher.cancel()
        watcher.cancel()
        directorySource.emit(.write)
        originalTargetSource.emit(.write)
        replacementTargetSource.emit(.write)

        XCTAssertEqual(changes.value.count, changeCountBeforeCancellation)
        XCTAssertEqual(directorySource.cancellationCount, 1)
        XCTAssertEqual(originalTargetSource.cancellationCount, 1)
        XCTAssertEqual(replacementTargetSource.cancellationCount, 1)
        XCTAssertEqual(availableSources.value.count, 0)
        XCTAssertEqual(closedDescriptors.value.sorted(), openedDescriptors.value.sorted())
    }

    func testTargetOnlyWatcherReattachesAfterDelayedReappearance() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("old".utf8).write(to: fileURL)

        let originalTargetSource = TestDirectorySource()
        let replacementTargetSource = TestDirectorySource()
        let availableSources = LockedBox([originalTargetSource, replacementTargetSource])
        let changes = LockedBox<[DirectoryChange]>([])
        let openEventOnly: @Sendable (URL) -> Int32 = { url in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            }
        }
        let watcher = try DirectoryWatcher(
            fileURL: fileURL,
            sourceFactory: { _, _, _ in
                availableSources.withValue { $0.removeFirst() }
            },
            openDirectory: { _ in
                errno = EACCES
                return -1
            },
            openTargetFile: openEventOnly,
            closeDescriptor: { descriptor in _ = Darwin.close(descriptor) }
        )
        try watcher.start { change in
            changes.withValue { $0.append(change) }
        }

        try FileManager.default.removeItem(at: fileURL)
        originalTargetSource.emit(.delete)

        // The rapid retry window ends after roughly 500 ms. Recreate the path only after that
        // point so recovery depends on the persistent, backed-off retry.
        try await Task.sleep(for: .milliseconds(650))
        try Data("reappeared".utf8).write(to: fileURL)

        try await waitUntil("delayed target reattachment", timeout: .seconds(3)) {
            replacementTargetSource.isActive
        }
        replacementTargetSource.emit(.write)

        XCTAssertTrue(originalTargetSource.isCancelled)
        XCTAssertTrue(replacementTargetSource.isActive)
        XCTAssertGreaterThanOrEqual(changes.value.count, 2)
        XCTAssertEqual(availableSources.value.count, 0)
        watcher.cancel()
    }

    func testPersistentTargetReattachmentStopsAfterCancellation() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("marklook-watcher-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("old".utf8).write(to: fileURL)

        let targetSource = TestDirectorySource()
        let openAttemptCount = LockedBox(0)
        let watcher = try DirectoryWatcher(
            fileURL: fileURL,
            sourceFactory: { _, _, _ in targetSource },
            openDirectory: { _ in
                errno = EACCES
                return -1
            },
            openTargetFile: { url in
                openAttemptCount.withValue { $0 += 1 }
                return url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
                }
            },
            closeDescriptor: { descriptor in _ = Darwin.close(descriptor) }
        )
        try watcher.start { _ in }

        try FileManager.default.removeItem(at: fileURL)
        targetSource.emit(.delete)
        try await waitUntil("target retry to begin") {
            openAttemptCount.value >= 3
        }

        watcher.cancel()
        // Allow an attempt that already passed its token check to settle before taking the
        // baseline, then verify the scheduled chain no longer performs filesystem opens.
        try await Task.sleep(for: .milliseconds(75))
        let attemptsAfterCancellation = openAttemptCount.value
        try await Task.sleep(for: .milliseconds(650))

        XCTAssertEqual(openAttemptCount.value, attemptsAfterCancellation)
        XCTAssertTrue(targetSource.isCancelled)
    }
}

private final class TestDirectorySource: DirectoryWatchingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var eventHandler: (@Sendable (UInt) -> Void)?
    private var cancelHandler: (@Sendable () -> Void)?
    private var active = false
    private var cancelled = false
    private var activations = 0
    private var cancellations = 0

    var isActive: Bool {
        lock.withLock { active }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var activationCount: Int {
        lock.withLock { activations }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func setEventHandler(_ handler: @escaping @Sendable (UInt) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { cancelHandler = handler }
    }

    func activate() {
        lock.withLock {
            active = true
            activations += 1
        }
    }

    func cancel() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            cancellations += 1
            return cancelHandler
        }
        handler?()
    }

    func emit(_ flags: DispatchSource.FileSystemEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(flags.rawValue)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
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

private func waitUntil(
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
        try await Task.sleep(for: .milliseconds(2))
    }
}

private func fileInode(at url: URL) throws -> NSNumber {
    try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    )
}
