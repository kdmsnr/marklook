import SwiftUI

struct DocumentRootView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openDocument) private var openDocument
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ViewerLayoutPreferences.contentWidthKey)
    private var configuredContentWidth = ViewerLayoutPreferences.defaultContentWidth
    @AppStorage(ViewerLayoutPreferences.usesFullWidthKey)
    private var usesFullContentWidth = false
    @State private var session: DocumentSession
    @State private var warningsArePresented = false

    init(documentURL: URL) {
        _session = State(initialValue: DocumentSession(documentURL: documentURL))
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
        .navigationTitle(session.title)
        .task {
            // Finder and state restoration can open a document without passing through the
            // welcome view's explicit replacement path.
            dismissWindow(
                id: WelcomeWindowIdentity.sceneID,
                value: WelcomeWindowIdentity.initialValue
            )
            session.setContentWidth(effectiveContentWidth)
            session.start()
        }
        .onChange(of: effectiveContentWidth) { _, width in
            session.setContentWidth(width)
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
            printDocument: session.printDocument
        )
    }

    private var effectiveContentWidth: Double? {
        ViewerLayoutPreferences.effectiveContentWidth(
            configuredWidth: configuredContentWidth,
            usesFullWidth: usesFullContentWidth
        )
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
        let snapshot = WindowTabCoordinator.snapshot()
        Task {
            do {
                try await openDocument(at: url)
                await WindowTabCoordinator.attachNextWindow(after: snapshot)
            } catch {
                session.reportOpenFailure(error)
            }
        }
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
