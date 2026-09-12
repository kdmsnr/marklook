import Foundation

/// Coalesces menu-state updates until AppKit leaves its menu-tracking run-loop mode.
@MainActor
final class MenuUpdateScheduler {
    private var pendingUpdate: (@MainActor () -> Void)?

    func schedule(_ update: @escaping @MainActor () -> Void) {
        let isScheduled = pendingUpdate != nil
        pendingUpdate = update
        guard !isScheduled else { return }

        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let update = self.pendingUpdate
                self.pendingUpdate = nil
                update?()
            }
        }
    }
}
