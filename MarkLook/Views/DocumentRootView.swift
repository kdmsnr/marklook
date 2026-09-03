import SwiftUI

struct DocumentRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ViewerLayoutPreferences.contentWidthKey)
    private var configuredContentWidth = ViewerLayoutPreferences.defaultContentWidth
    @AppStorage(ViewerLayoutPreferences.usesFullWidthKey)
    private var usesFullContentWidth = false
    @AppStorage(ViewerFontPreferences.fontFamilyKey)
    private var storedFontFamily = ViewerFontPreferences.defaultFontFamily.rawValue
    @AppStorage(MarkdownRenderingPreferences.lineBreakModeKey)
    private var storedMarkdownLineBreakMode = MarkdownRenderingPreferences.defaultLineBreakMode.rawValue
    @AppStorage(MarkdownRenderingPreferences.showsFrontMatterKey)
    private var showsFrontMatter = MarkdownRenderingPreferences.defaultShowsFrontMatter
    @AppStorage(RemoteContentPreferences.allowedHostsKey)
    private var storedRemoteContentHosts = RemoteContentPreferences.defaultStoredValue
    @State private var sessionOwner = DocumentSessionOwner()
    @State private var warningsArePresented = false
    private let documentURL: URL
    private let currentURLDidChange: (URL) -> Void

    init(
        documentURL: URL,
        currentURLDidChange: @escaping (URL) -> Void = { _ in }
    ) {
        self.documentURL = documentURL
        self.currentURLDidChange = currentURLDidChange
    }

    private var session: DocumentSession {
        sessionOwner.session(for: documentURL)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if session.phase == .failedInitially {
                InitialDocumentFailureView(
                    issue: session.issue,
                    retry: session.reload,
                    grantAccess: session.grantFolderAccess,
                    locate: session.locateFile
                )
            } else {
                DocumentWebView(store: session.webViewStore)
                    .accessibilityIdentifier("viewer.webView")
            }

            VStack(alignment: .trailing, spacing: 10) {
                if UITestSupport.isEnabled {
                    uiTestControls
                }

                if session.isFindPresented {
                    FindOverlay(session: session)
                }

                if session.phase == .ready, let issue = session.issue {
                    ViewerIssueOverlay(
                        issue: issue,
                        retry: session.reload,
                        grantAccess: session.grantFolderAccess,
                        locate: session.locateFile,
                        dismiss: session.dismissIssue
                    )
                }

                if session.isProcessingVisible {
                    ProgressView()
                        .controlSize(.small)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                        .accessibilityLabel("Updating document")
                        .accessibilityIdentifier("viewer.progress")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 380)
        .task {
            WindowOpenRouter.shared.documentSessionDidStart(for: documentURL)
            session.setCurrentWindowNavigationPolicy(Self.shouldOpenInCurrentWindow)
            session.setContentWidth(effectiveContentWidth)
            session.setFontFamily(fontFamily)
            session.setMarkdownLineBreakMode(markdownLineBreakMode)
            session.setShowsFrontMatter(showsFrontMatter)
            session.setRemoteContentPolicy(remoteContentPolicy)
            session.start()
            currentURLDidChange(session.currentURL)
        }
        .onChange(of: effectiveContentWidth) { _, width in
            session.setContentWidth(width)
        }
        .onChange(of: fontFamily) { _, fontFamily in
            session.setFontFamily(fontFamily)
        }
        .onChange(of: markdownLineBreakMode) { _, mode in
            session.setMarkdownLineBreakMode(mode)
        }
        .onChange(of: showsFrontMatter) { _, showsFrontMatter in
            session.setShowsFrontMatter(showsFrontMatter)
        }
        .onChange(of: remoteContentPolicy) { _, policy in
            session.setRemoteContentPolicy(policy)
        }
        .onDisappear { session.persistViewState() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.persistViewState()
            }
        }
        .onChange(of: session.openDocumentRequest) { _, request in
            guard let request else { return }
            session.consumeOpenDocumentRequest()
            openInNewTab(request.url)
        }
        .onChange(of: session.currentURL) { _, url in
            currentURLDidChange(url)
        }
        .onChange(of: documentURL) { _, url in
            session.openRoutedFile(url)
        }
        .focusedSceneValue(\.viewerActions, viewerActions)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.openDroppedFile(url)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: session.goBack) {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .disabled(!session.canGoBack)
                .accessibilityIdentifier("viewer.back")

                Button(action: session.goForward) {
                    Image(systemName: "chevron.right")
                }
                .help("Forward")
                .disabled(!session.canGoForward)
                .accessibilityIdentifier("viewer.forward")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if !session.warnings.isEmpty {
                    Button {
                        warningsArePresented.toggle()
                    } label: {
                        Label(
                            "\(session.warnings.count) warnings",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    .help("Show Warnings")
                    .accessibilityIdentifier("viewer.warnings")
                    .popover(isPresented: $warningsArePresented, arrowEdge: .bottom) {
                        WarningListView(warnings: session.warnings)
                    }
                }

                Button(action: session.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .accessibilityIdentifier("viewer.reload")
            }
        }
    }

    private var viewerActions: ViewerActions {
        ViewerActions(
            reload: session.reload,
            presentFind: { session.isFindPresented = true },
            zoomIn: session.zoomIn,
            zoomOut: session.zoomOut,
            resetZoom: session.resetZoom,
            goBack: session.goBack,
            goForward: session.goForward,
            exportPDF: session.exportPDF,
            canExportPDF: session.displayedURL != nil && !session.isExportingPDF,
            printDocument: session.printDocument
        )
    }

    private var effectiveContentWidth: Double? {
        ViewerLayoutPreferences.effectiveContentWidth(
            configuredWidth: configuredContentWidth,
            usesFullWidth: usesFullContentWidth
        )
    }

    private var markdownLineBreakMode: MarkdownLineBreakMode {
        MarkdownRenderingPreferences.lineBreakMode(storedValue: storedMarkdownLineBreakMode)
    }

    private var fontFamily: ViewerFontFamily {
        ViewerFontPreferences.fontFamily(storedValue: storedFontFamily)
    }

    private var remoteContentPolicy: RemoteContentPolicy {
        RemoteContentPolicy(storedValue: storedRemoteContentHosts)
    }

    private var uiTestControls: some View {
        HStack(spacing: 8) {
            Text(UITestSupport.phaseLabel(session.phase))
                .accessibilityIdentifier("uitest.viewerPhase")

            if UITestSupport.supportsAtomicUpdate {
                Button("Apply Atomic Update") {
                    try? UITestSupport.applyAtomicUpdate(to: session.currentURL)
                }
                .accessibilityIdentifier("uitest.atomicReload")
            }
        }
        .font(.caption)
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func openInNewTab(_ url: URL) {
        let sourceRoute = ViewerWindowRoute.viewing(session.currentURL)
        let sourceWindow = WindowTabCoordinator.window(for: sourceRoute)
        if !WindowOpenRouter.shared.open(
            url,
            from: sourceWindow
        ) {
            session.reportOpenFailure(
                DocumentLoadError.unsupportedType(url.pathExtension)
            )
        }
    }

    private static func shouldOpenInCurrentWindow(
        _ currentURL: URL,
        _ targetURL: URL
    ) -> Bool {
        guard let targetRoute = ViewerWindowRoute.viewing(targetURL) else {
            return true
        }
        let currentRoute = ViewerWindowRoute.viewing(currentURL)
        let currentWindow = WindowTabCoordinator.window(for: currentRoute)
        return !WindowTabCoordinator.focusExistingWindow(
            for: targetRoute,
            excluding: currentWindow
        )
    }
}

/// Keeps expensive document state out of the SwiftUI view initializer. SwiftUI may construct
/// transient `DocumentRootView` values while evaluating the graph; creating a `WKWebView` there
/// would launch a WebContent process for every transient value.
@MainActor
private final class DocumentSessionOwner {
    private var storedSession: DocumentSession?

    func session(for documentURL: URL) -> DocumentSession {
        if let storedSession {
            return storedSession
        }
        let session = DocumentSession(documentURL: documentURL)
        storedSession = session
        return session
    }
}

private struct WarningListView: View {
    let warnings: [RenderWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Warnings")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 390, height: min(300, CGFloat(80 + warnings.count * 46)))
        .accessibilityIdentifier("viewer.warningList")
    }
}
