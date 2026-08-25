import AppKit

enum WelcomeWindowIdentity {
    static let sceneID = "welcome"
    static let initialValue = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
}

@MainActor
enum WindowTabCoordinator {
    struct Snapshot {
        fileprivate let parent: NSWindow?
        fileprivate let windowIDs: Set<ObjectIdentifier>
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            parent: NSApp.keyWindow,
            windowIDs: Set(NSApp.windows.map(ObjectIdentifier.init))
        )
    }

    static func attachNextWindow(
        after snapshot: Snapshot,
        replacingParent: Bool = false
    ) async {
        for _ in 0 ..< 24 {
            if let newWindow = NSApp.windows.first(where: {
                !snapshot.windowIDs.contains(ObjectIdentifier($0)) && $0.isVisible
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
}
