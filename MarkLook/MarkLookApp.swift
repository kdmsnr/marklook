import AppKit
import SwiftUI

@main
struct MarkLookApp: App {
    @NSApplicationDelegateAdaptor(MarkLookAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(
            "MarkLook",
            id: WelcomeWindowIdentity.sceneID,
            for: UUID.self
        ) { _ in
            WelcomeDropView()
                .background(WindowTabRegistrationView())
        } defaultValue: {
            WelcomeWindowIdentity.initialValue
        }
        .defaultSize(width: 620, height: 420)
        .windowToolbarStyle(.unified)
        .commands {
            ViewerCommands(
                recentDocuments: .shared,
                replacingParentOnOpen: true
            )
        }

        DocumentGroup(viewing: ViewerDocument.self) { configuration in
            if let fileURL = configuration.fileURL {
                DocumentRootView(documentURL: fileURL)
                    .id(fileURL.standardizedFileURL)
                    .background(WindowTabRegistrationView())
            } else {
                ContentUnavailableView(
                    "File Unavailable",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("MarkLook could not determine the document location.")
                )
                .background(WindowTabRegistrationView())
            }
        }
        .defaultSize(width: 900, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            ViewerCommands(
                recentDocuments: .shared,
                replacingParentOnOpen: false
            )
        }

    }
}

@MainActor
private final class MarkLookAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        RecentDocuments.shared.activate(documentController: .shared)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }
}
