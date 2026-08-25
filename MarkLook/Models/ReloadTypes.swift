import CryptoKit
import Foundation

/// A content-derived identity used to discard directory events that did not change the file.
///
/// Modification dates and inode numbers are intentionally not part of the identity: editors
/// commonly replace a file atomically even when the bytes are unchanged.
struct ContentFingerprint: Hashable, Sendable {
    let byteCount: Int
    let sha256: Data

    init(data: Data) {
        byteCount = data.count
        sha256 = Data(SHA256.hash(data: data))
    }
}

/// Input passed to document decoding/rendering for one generation.
struct ReloadInput: Sendable {
    let generation: ReloadGeneration
    let fileURL: URL
    let data: Data
    let fingerprint: ContentFingerprint
}

/// Monotonic, in-memory timings for one successful scheduler generation.
///
/// These values contain no document identity or contents. `eventToProcessing` is nil for manual
/// and initial reloads because they do not originate from a filesystem notification.
struct ReloadTiming: Sendable, Equatable {
    let eventToProcessing: Duration?
    let read: Duration
    let fingerprint: Duration
    let process: Duration
    let schedulerWork: Duration
}

/// The only reload value that is eligible to replace the currently displayed document.
struct ReloadSnapshot<Output: Sendable>: Sendable {
    let generation: ReloadGeneration
    let fileURL: URL
    let fingerprint: ContentFingerprint
    let output: Output
    let timing: ReloadTiming
}

enum ReloadFailureKind: String, Sendable, Equatable {
    case temporarilyMissing
    case read
    case processing
}

/// A diagnostic for the overlay UI. It deliberately carries no replacement document, so a
/// failed update cannot clear the last successful WebView contents.
struct ReloadFailure: Sendable, Equatable {
    let generation: ReloadGeneration
    let fileURL: URL
    let kind: ReloadFailureKind
    let message: String
    let lastSuccessfulGeneration: ReloadGeneration?
}

enum ReloadSchedulerEvent<Output: Sendable>: Sendable {
    /// A current-generation result that may replace the displayed DOM.
    case loaded(ReloadSnapshot<Output>)

    /// The file bytes matched the last successfully displayed generation. No UI work is needed.
    case unchanged(generation: ReloadGeneration, fingerprint: ContentFingerprint)

    /// The update failed. Consumers should show an overlay and keep the existing DOM intact.
    case failed(ReloadFailure)
}

struct ReloadSchedulerConfiguration: Sendable, Equatable {
    /// Quiet period for combining adjacent directory events. The default is 16 ms.
    let coalescingDelay: Duration

    /// Hard deadline measured from the first event in a burst. The default is 100 ms.
    let maximumCoalescingLatency: Duration

    /// Delay between reads while an atomically replaced file is temporarily absent.
    let missingFileRetryDelay: Duration

    /// Maximum time to tolerate a temporarily absent file before surfacing a failure.
    let missingFileRetryWindow: Duration

    init(
        coalescingDelay: Duration = .milliseconds(16),
        maximumCoalescingLatency: Duration = .milliseconds(100),
        missingFileRetryDelay: Duration = .milliseconds(25),
        missingFileRetryWindow: Duration = .milliseconds(500)
    ) {
        precondition(coalescingDelay >= .zero)
        precondition(maximumCoalescingLatency >= .zero)
        precondition(missingFileRetryDelay > .zero)
        precondition(missingFileRetryWindow >= .zero)

        self.coalescingDelay = coalescingDelay
        self.maximumCoalescingLatency = maximumCoalescingLatency
        self.missingFileRetryDelay = missingFileRetryDelay
        self.missingFileRetryWindow = missingFileRetryWindow
    }
}

/// Injectable monotonic time. Tests can advance it without sleeping in wall-clock time.
struct ReloadSchedulerClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
    }

    static var continuous: Self {
        let clock = ContinuousClock()
        return Self(
            now: { clock.now },
            sleepUntil: { deadline in
                try await clock.sleep(until: deadline, tolerance: .milliseconds(1))
            }
        )
    }
}

/// Synchronous by design: `ReloadScheduler` invokes it from a detached task, keeping filesystem
/// I/O off the main actor. Injection also makes temporary-disappearance tests deterministic.
struct ReloadFileReader: Sendable {
    let read: @Sendable (URL) throws -> Data

    init(read: @escaping @Sendable (URL) throws -> Data) {
        self.read = read
    }

    static let local = Self { url in
        try Data(contentsOf: url)
    }
}

extension Duration {
    var markLookMilliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
