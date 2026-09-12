import AppKit
import Combine

/// Keeps the Window menu in sync with the active viewer's native tab group.
@MainActor
final class ViewerWindowLevelController: NSObject, ObservableObject {
    @Published private(set) var canToggle = false
    @Published private(set) var isAlwaysOnTop = false

    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabObservation: NSKeyValueObservation?

    override init() {
        super.init()
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChange),
                name: name,
                object: nil
            )
        }
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        guard let window = activeViewerWindow else { return }
        setLevel(enabled ? .floating : .normal, for: window)
        refresh()
    }

    private var activeViewerWindow: NSWindow? {
        guard let window = NSApp?.keyWindow,
              !(window is NSPanel),
              window.tabbingIdentifier == WindowTabCoordinator.sharedTabbingIdentifier,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return nil }
        return window
    }

    @objc private func windowDidChange(_: Notification) {
        // AppKit may still be updating key-window and tab ownership during a notification.
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let window = activeViewerWindow
        let group = window?.tabGroup
        if observedTabGroup !== group {
            tabObservation = nil
            observedTabGroup = group
            // `windows` is KVO compliant, including native tab merges and detachments.
            tabObservation = group?.observe(\.windows) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }

        canToggle = window != nil
        guard let window else {
            isAlwaysOnTop = false
            return
        }

        // Preserve pinning when a new tab or another window joins a pinned group.
        let enabled = (group?.windows ?? [window]).contains { $0.level == .floating }
        setLevel(enabled ? .floating : .normal, for: window)
        isAlwaysOnTop = enabled
    }

    private func setLevel(_ level: NSWindow.Level, for window: NSWindow) {
        for tab in window.tabGroup?.windows ?? [window] where tab.level != level {
            tab.level = level
        }
    }
}
