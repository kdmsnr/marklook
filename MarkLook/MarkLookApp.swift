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
            ViewerCommands(recentDocuments: .shared)
        }
    }
}

private struct ViewerWindowRoot: View {
    @Binding var route: ViewerWindowRoute
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch route {
            case let .document(url):
                DocumentRootView(
                    documentURL: url,
                    currentURLDidChange: updateDocumentRoute
                )
            case .welcome:
                WelcomeDropView(route: $route)
            }
        }
        .navigationTitle(route.windowTitle)
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
    func applicationWillFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_: Notification) {
        RecentDocuments.shared.activate(documentController: NSDocumentController.shared)
    }

    func application(_: NSApplication, open urls: [URL]) {
        WindowOpenRouter.shared.enqueueExternalOpen(urls)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
