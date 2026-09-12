import AppKit
import SwiftUI

@main
struct MarkLookApp: App {
    @NSApplicationDelegateAdaptor(MarkLookAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(
            "MarkLook",
            id: ViewerWindowRoute.sceneID,
            for: ViewerWindowRoute.self
        ) { route in
            ViewerWindowRoot(route: route)
        } defaultValue: {
            .welcome(UUID())
        }
        .defaultSize(width: 900, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            ViewerCommands(
                recentDocuments: .shared,
                windowLevel: appDelegate.windowLevel
            )
        }
    }
}

private struct ViewerWindowRoot: View {
    @Binding var route: ViewerWindowRoute
    @Environment(\.openWindow) private var openWindow
    @State private var sessionOwner = DocumentSessionOwner()

    var body: some View {
        let documentURL = route.documentURL
        let session = documentURL.map { sessionOwner.session(for: $0) }

        Group {
            if let documentURL, let session {
                DocumentRootView(
                    documentURL: documentURL,
                    session: session,
                    currentURLDidChange: updateDocumentRoute
                )
            } else {
                WelcomeDropView(route: $route)
            }
        }
        .navigationTitle(route.windowTitle)
        // Install the same toolbar before a Welcome window opens its first document.
        .toolbar {
            ViewerToolbar(session: session)
        }
        .background(WindowTabRegistrationView(route: $route))
        .onAppear {
            WindowOpenRouter.shared.install { destination in
                openWindow(id: ViewerWindowRoute.sceneID, value: destination)
            }
        }
    }

    private func updateDocumentRoute(_ url: URL) {
        guard let updatedRoute = ViewerWindowRoute.viewing(url),
              route != updatedRoute else { return }
        route = updatedRoute
    }
}

@MainActor
private final class MarkLookAppDelegate: NSObject, NSApplicationDelegate {
    let windowLevel = ViewerWindowLevelController()

    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_: Notification) {
        RecentDocuments.shared.activate(documentController: NSDocumentController.shared)
    }

    func application(_: NSApplication, open urls: [URL]) {
        WindowOpenRouter.shared.enqueueExternalOpen(urls)
    }

    // The native tab bar uses an AppKit action, separate from the SwiftUI New Tab command.
    @objc func newWindowForTab(_ sender: Any?) {
        let sourceWindow = (sender as? NSWindow) ?? (sender as? NSView)?.window
        WindowOpenRouter.shared.openNewTab(from: sourceWindow)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
