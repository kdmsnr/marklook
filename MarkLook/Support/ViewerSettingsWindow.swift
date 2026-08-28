import AppKit
import SwiftUI

/// Keeps the utility window independent from viewer-window routing and native tab groups.
/// This restores the previously working root-scene shape after an observed launch crash inside
/// PlatformDocumentController, while still hosting the same SwiftUI settings view and state.
@MainActor
enum ViewerSettingsWindow {
    private static var windowController: NSWindowController?

    static func show() {
        let controller = windowController ?? makeWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private static func makeWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: ViewerSettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 500, height: 520)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.setFrameAutosaveName("MarkLook.ViewerSettingsWindow.v3")
        window.center()
        return NSWindowController(window: window)
    }
}
