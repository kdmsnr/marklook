import Foundation

/// Preserves the latency-critical ordering between a filesystem notification and native UI work.
///
/// The scheduler must observe the change before waiting for the main actor to update transient UI
/// such as the delayed progress indicator.
enum ReloadChangeForwarder {
    static func forward(
        observedAt: ContinuousClock.Instant,
        signalChange: @escaping @Sendable (ContinuousClock.Instant) async -> Void,
        beginActivity: @escaping @MainActor @Sendable () -> Void
    ) async {
        await signalChange(observedAt)
        await beginActivity()
    }
}
