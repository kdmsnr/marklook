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
    let exportPDF: () -> Void
    let canExportPDF: Bool
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
    let recentDocuments: RecentDocuments
    let windowLevel: ViewerWindowLevelController

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                ViewerSettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                WindowOpenRouter.shared.openNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Open…") {
                chooseFile()
            }
            .keyboardShortcut("o", modifiers: .command)

            RecentDocumentsMenu(
                recentDocuments: recentDocuments,
                openDocument: openRecentDocument
            )
        }

        CommandGroup(replacing: .saveItem) {
            ExportPDFMenuItem()

            Divider()

            Button("Close Tab") {
                WindowTabCoordinator.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .windowArrangement) {
            Divider()

            ViewerWindowLevelMenuItem(windowLevel: windowLevel)
        }

        CommandMenu("Viewer") {
            ViewerDocumentMenuItems()
        }
    }

    private func chooseFile() {
        let sourceWindow = WindowTabCoordinator.preferredParentWindow()
        DocumentOpenPanel.chooseFile(attachedTo: sourceWindow) { url in
            openDocumentURL(url, from: sourceWindow)
        }
    }

    private func openRecentDocument(_ recentURL: URL) {
        let bookmarkResolution = BookmarkStore().resolveFile(matching: recentURL)
        let targetURL = bookmarkResolution?.url ?? recentURL
        openDocumentURL(
            targetURL,
            from: WindowTabCoordinator.preferredParentWindow(),
            replacingRecentURL: recentURL
        )
        withExtendedLifetime(bookmarkResolution) {}
    }

    private func openDocumentURL(
        _ targetURL: URL,
        from sourceWindow: NSWindow?,
        replacingRecentURL: URL? = nil
    ) {
        guard WindowOpenRouter.shared.open(
            targetURL,
            from: sourceWindow,
            replacingRecentURL: replacingRecentURL
        ) else {
            NSDocumentController.shared.presentError(
                DocumentLoadError.unsupportedType(targetURL.pathExtension)
            )
            return
        }
    }
}

// Keep observable state below Commands so changing one item's state does not
// rebuild the standard menus while AppKit is tracking across the menu bar.
private struct RecentDocumentsMenu: View {
    let recentDocuments: RecentDocuments
    let openDocument: (URL) -> Void

    var body: some View {
        Menu("Open Recent") {
            if recentDocuments.urls.isEmpty {
                Button("No Recent Files") {}
                    .disabled(true)
            } else {
                ForEach(recentDocuments.urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        openDocument(url)
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
}

private struct ExportPDFMenuItem: View {
    @FocusedValue(\.viewerActions) private var actions

    var body: some View {
        Button("Export as PDF…") {
            actions?.exportPDF()
        }
        .disabled(actions?.canExportPDF != true)
    }
}

private struct ViewerWindowLevelMenuItem: View {
    @ObservedObject var windowLevel: ViewerWindowLevelController

    var body: some View {
        Toggle("Always on Top", isOn: Binding(
            get: { windowLevel.isAlwaysOnTop },
            set: { windowLevel.setAlwaysOnTop($0) }
        ))
        .disabled(!windowLevel.canToggle)
    }
}

private struct ViewerDocumentMenuItems: View {
    @FocusedValue(\.viewerActions) private var actions

    var body: some View {
        Group {
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
}
