import AppKit
import SwiftUI

@MainActor
struct ViewerActions {
    let reload: () -> Void
    let presentFind: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let printDocument: () -> Void
}

private struct ViewerActionsKey: FocusedValueKey {
    typealias Value = ViewerActions
}

extension FocusedValues {
    var viewerActions: ViewerActions? {
        get { self[ViewerActionsKey.self] }
        set { self[ViewerActionsKey.self] = newValue }
    }
}

struct ViewerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openDocument) private var openDocument
    @FocusedValue(\.viewerActions) private var actions
    let recentDocuments: RecentDocuments
    let replacingParentOnOpen: Bool

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                ViewerSettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                let snapshot = WindowTabCoordinator.snapshot()
                openWindow(id: WelcomeWindowIdentity.sceneID, value: UUID())
                Task { await WindowTabCoordinator.attachNextWindow(after: snapshot) }
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Open…") {
                chooseFile()
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if recentDocuments.urls.isEmpty {
                    Button("No Recent Files") {}
                        .disabled(true)
                } else {
                    ForEach(recentDocuments.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            openRecentDocument(url)
                        }
                        .help(url.path)
                    }
                }

                Divider()

                Button("Clear Menu") {
                    recentDocuments.clear()
                }
                .disabled(recentDocuments.urls.isEmpty)
            }
        }

        CommandGroup(replacing: .saveItem) {}

        CommandMenu("Viewer") {
            Button("Reload") { actions?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)

            Button("Find…") { actions?.presentFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions == nil)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions == nil)
            Button("Actual Size") { actions?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Back") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions == nil)
            Button("Forward") { actions?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Print…") { actions?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions == nil)
        }
    }

    private func chooseFile() {
        // Capture the document window before the open panel becomes key.
        let windowSnapshot = WindowTabCoordinator.snapshot()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.markLookMarkdown, .html]
        panel.prompt = "Open"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openDocumentURL(url, windowSnapshot: windowSnapshot)
        }
    }

    private func openRecentDocument(_ recentURL: URL) {
        let bookmarkResolution = BookmarkStore().resolveFile(matching: recentURL)
        let targetURL = bookmarkResolution?.url ?? recentURL
        openDocumentURL(targetURL, bookmarkResolution: bookmarkResolution)
    }

    private func openDocumentURL(
        _ targetURL: URL,
        bookmarkResolution: BookmarkFileResolution? = nil,
        windowSnapshot: WindowTabCoordinator.Snapshot? = nil
    ) {
        let snapshot = windowSnapshot ?? WindowTabCoordinator.snapshot()
        let directLease = bookmarkResolution == nil
            ? SecurityScopedLease(url: targetURL)
            : nil

        Task { @MainActor in
            do {
                try await openDocument(at: targetURL)
                recentDocuments.note(targetURL)
                await WindowTabCoordinator.attachNextWindow(
                    after: snapshot,
                    replacingParent: replacingParentOnOpen
                )
            } catch {
                NSDocumentController.shared.presentError(error)
            }

            withExtendedLifetime(bookmarkResolution) {}
            withExtendedLifetime(directLease) {}
        }
    }
}
