import AppKit
import Combine

/// Keeps the Window menu in sync with the active viewer's native tab group.
@MainActor
final class ViewerWindowLevelController: NSObject, ObservableObject {
    @Published private(set) var canToggle = false
    @Published private(set) var isAlwaysOnTop = false

    private weak var targetWindow: NSWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabObservation: NSKeyValueObservation?
    private let menuUpdates = MenuUpdateScheduler()

    override init() {
        super.init()
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
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
        // Keep the action aimed at the viewer that supplied the menu state, even
        // when a menu's search field temporarily becomes the key window.
        guard let window = targetWindow,
              window.isVisible,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return }
        setLevel(enabled ? .floating : .normal, for: window)
        scheduleRefresh()
    }

    private var activeViewerWindow: NSWindow? {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow,
              !(window is NSPanel),
              window.tabbingIdentifier == WindowTabCoordinator.sharedTabbingIdentifier,
              window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return nil }
        return window
    }

    @objc private func windowDidChange(_: Notification) {
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        menuUpdates.schedule { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        let window = activeViewerWindow
        targetWindow = window
        let group = window?.tabGroup
        if observedTabGroup !== group {
            tabObservation = nil
            observedTabGroup = group
            // `windows` is KVO compliant, including native tab merges and detachments.
            tabObservation = group?.observe(\.windows) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
        }

        if canToggle != (window != nil) {
            canToggle = window != nil
        }
        guard let window else {
            if isAlwaysOnTop { isAlwaysOnTop = false }
            return
        }

        // Preserve pinning when a new tab or another window joins a pinned group.
        let enabled = (group?.windows ?? [window]).contains { $0.level == .floating }
        setLevel(enabled ? .floating : .normal, for: window)
        if isAlwaysOnTop != enabled {
            isAlwaysOnTop = enabled
        }
    }

    private func setLevel(_ level: NSWindow.Level, for window: NSWindow) {
        for tab in window.tabGroup?.windows ?? [window] where tab.level != level {
            tab.level = level
        }
    }
}
