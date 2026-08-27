import AppKit

enum WelcomeWindowIdentity {
    static let sceneID = "welcome"
    static let initialValue = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
}

@MainActor
enum WindowTabCoordinator {
    static let sharedTabbingIdentifier = "com.example.MarkLook.document-tabs"

    struct Snapshot {
        fileprivate let parent: NSWindow?
        fileprivate let windowIDs: Set<ObjectIdentifier>
    }

    static func snapshot() -> Snapshot {
        let windows = NSApp.windows
        return Snapshot(
            parent: preferredParentWindow(
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                orderedWindows: NSApp.orderedWindows
            ),
            windowIDs: Set(windows.map(ObjectIdentifier.init))
        )
    }

    /// A file panel can still be the key window when its completion handler runs. It must not
    /// become the parent of a document tab; the underlying main document window is the parent.
    static func preferredParentWindow(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        orderedWindows: [NSWindow]
    ) -> NSWindow? {
        ([keyWindow, mainWindow].compactMap { $0 } + orderedWindows)
            .first(where: isTabEligible)
    }

    static func configureDraggableTabs(for window: NSWindow) {
        guard isTabEligible(window) else { return }

        window.tabbingIdentifier = sharedTabbingIdentifier
        window.tabbingMode = .preferred

        // A single-window group normally hides its tab bar. Keeping it visible gives every
        // window a draggable tab, so it can be dropped into another MarkLook window.
        if window.tabGroup?.isTabBarVisible != true {
            window.toggleTabBar(nil)
        }
    }

    static func attachNextWindow(
        after snapshot: Snapshot,
        replacingParent: Bool = false
    ) async {
        for _ in 0 ..< 24 {
            if let newWindow = NSApp.windows.first(where: {
                !snapshot.windowIDs.contains(ObjectIdentifier($0)) && isTabEligible($0)
            }) {
                if let parent = snapshot.parent,
                   parent !== newWindow,
                   parent.isVisible,
                   parent.tabbedWindows?.contains(where: { $0 === newWindow }) != true
                {
                    parent.addTabbedWindow(newWindow, ordered: .above)
                }
                newWindow.makeKeyAndOrderFront(nil)
                if replacingParent {
                    snapshot.parent?.close()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(15))
        }

        // Opening a file that is already open activates its existing tab and creates no window.
        if replacingParent {
            snapshot.parent?.close()
        }
    }

    private static func isTabEligible(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.tabbingMode != .disallowed
    }
}
