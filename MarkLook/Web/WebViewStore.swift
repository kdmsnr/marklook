import AppKit
import Foundation
import WebKit

struct WebViewUpdateResult: Sendable {
    let warnings: [RenderWarning]
    let webDurationMilliseconds: Double?
    let stale: Bool
}

struct WebNavigationRequest: Sendable {
    let source: String
    let openInNewTab: Bool
}

struct PersistedScrollState: Codable, Sendable {
    let anchor: String?
    let offset: Double
    let ratio: Double
    let atBottom: Bool
    let fragment: String?
}

@MainActor
final class WebViewStore: NSObject {
    static let contentWorld = WKContentWorld.world(name: "MarkLookApp")
    static let contentSecurityPolicy = "default-src 'none'; connect-src 'none'; script-src 'none'; worker-src 'none'; child-src 'none'; img-src mark-resource: mark-remote-resource:; style-src 'unsafe-inline' mark-resource: mark-remote-resource:; font-src mark-resource: mark-remote-resource:; media-src mark-resource: mark-remote-resource:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; manifest-src 'none'"
    private static var outputOperationInProgress = false

    let webView: WKWebView
    let resourceHandler: LocalResourceSchemeHandler
    let remoteResourceHandler: RemoteResourceSchemeHandler

    var onDocumentNavigation: ((WebNavigationRequest) -> Void)?
    var onNavigationFailure: ((String) -> Void)?

    private let baseCSS: String
    private let katexCSS: String
    private let highlightCSS: String
    private var shellReady = false
    private var shellWaiters: [CheckedContinuation<Void, Never>] = []
    private var contentWidth: Double? = ViewerLayoutPreferences.defaultContentWidth
    private var contentWidthRevision: UInt64 = 0
    private var pdfExportInProgress = false
    private var pdfExportCompletion: (() -> Void)?
    private var pdfPanel: NSPDFPanel?

    init(
        documentURL: URL,
        scopes: [LocalResourceScope],
        resourceAuthority: String,
        remoteContentPolicy: RemoteContentPolicy = .init()
    ) {
        baseCSS = Self.asset(named: "Viewer", extension: "css") ?? ""
        katexCSS = Self.rewriteBundledKaTeXFonts(Self.asset(named: "katex.min", extension: "css") ?? "")
        let lightHighlightCSS = Self.asset(named: "github.min", extension: "css")
            ?? Self.asset(named: "highlight", extension: "css")
            ?? ""
        let darkHighlightCSS = Self.asset(named: "github-dark.min", extension: "css") ?? ""
        highlightCSS = lightHighlightCSS + "\n@media screen and (prefers-color-scheme: dark) {\n\(darkHighlightCSS)\n}"

        let runtime = Self.asset(named: "ViewerRuntime", extension: "js") ?? ""
        let katex = Self.asset(named: "katex.min", extension: "js") ?? ""
        let highlighter = Self.asset(named: "highlight.min", extension: "js") ?? ""

        resourceHandler = LocalResourceSchemeHandler(
            documentURL: documentURL,
            scopes: scopes,
            resourceAuthority: resourceAuthority
        )
        remoteResourceHandler = RemoteResourceSchemeHandler(
            resourceAuthority: resourceAuthority,
            policy: remoteContentPolicy
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "mark-resource")
        configuration.setURLSchemeHandler(
            remoteResourceHandler,
            forURLScheme: RemoteResourceURL.scheme
        )
        let userContentController = WKUserContentController()
        let userScript = WKUserScript(
            source: [katex, highlighter, runtime].joined(separator: "\n;\n"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.contentWorld
        )
        userContentController.addUserScript(userScript)
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        loadShell()
    }

    func updateAccess(documentURL: URL, scopes: [LocalResourceScope]) {
        resourceHandler.update(documentURL: documentURL, scopes: scopes)
    }

    func updateRemoteContentPolicy(_ policy: RemoteContentPolicy) {
        remoteResourceHandler.update(policy: policy)
    }

    func apply(
        output: RenderOutput,
        generation: ReloadGeneration,
        explicitAnchor: String?,
        preserveScroll: Bool = true
    ) async throws -> WebViewUpdateResult {
        await waitUntilShellReady()
        let fineDiff = output.sizeClass != .lightweight
        let highlight = output.sizeClass != .lightweight
        let arguments: [String: Any] = [
            "payload": [
                "html": output.htmlFragment,
                "generation": NSNumber(value: generation.rawValue),
                "explicitAnchor": explicitAnchor as Any,
                "preserveScroll": preserveScroll,
                "containsMath": output.containsMath,
                "useFineDiff": fineDiff,
                "highlight": highlight,
                "contentWidth": contentWidth.map(NSNumber.init(value:)) ?? NSNull(),
                "contentWidthRevision": NSNumber(value: contentWidthRevision),
                "baseCSS": baseCSS,
                "katexCSS": katexCSS,
                "highlightCSS": highlightCSS,
            ]
        ]
        let raw = try await webView.callAsyncJavaScript(
            "return await globalThis.marklookRuntime.applyUpdate(payload);",
            arguments: arguments,
            contentWorld: Self.contentWorld
        )
        let dictionary = raw as? [String: Any]
        let scriptWarnings = (dictionary?["warnings"] as? [String] ?? []).map { RenderWarning(message: $0) }
        return WebViewUpdateResult(
            warnings: output.warnings + scriptWarnings,
            webDurationMilliseconds: dictionary?["durationMS"] as? Double,
            stale: dictionary?["stale"] as? Bool ?? false
        )
    }

    func navigate(toAnchor anchor: String) async {
        _ = try? await webView.callAsyncJavaScript(
            "return globalThis.marklookRuntime.navigateAnchor(anchor);",
            arguments: ["anchor": anchor],
            contentWorld: Self.contentWorld
        )
    }

    func invalidateResources(_ sources: [String], revision: UInt64) async {
        _ = try? await webView.callAsyncJavaScript(
            "return await globalThis.marklookRuntime.invalidateResources(sources, revision);",
            arguments: ["sources": sources, "revision": NSNumber(value: revision)],
            contentWorld: Self.contentWorld
        )
    }

    func find(_ query: String, backwards: Bool = false) async -> Bool {
        guard !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        let result = try? await webView.find(query, configuration: configuration)
        return result?.matchFound ?? false
    }

    func captureScrollState() async -> PersistedScrollState? {
        guard shellReady else { return nil }
        let raw = try? await webView.callAsyncJavaScript(
            "return globalThis.marklookRuntime.scrollState();",
            contentWorld: Self.contentWorld
        )
        guard let dictionary = raw as? [String: Any] else { return nil }
        return PersistedScrollState(
            anchor: dictionary["anchor"] as? String,
            offset: dictionary["offset"] as? Double ?? 0,
            ratio: dictionary["ratio"] as? Double ?? 0,
            atBottom: dictionary["atBottom"] as? Bool ?? false,
            fragment: dictionary["fragment"] as? String
        )
    }

    func restoreScrollState(_ state: PersistedScrollState) async {
        _ = try? await webView.callAsyncJavaScript(
            "return await globalThis.marklookRuntime.restoreScrollState(snapshot);",
            arguments: [
                "snapshot": [
                    "anchor": state.anchor as Any,
                    "offset": state.offset,
                    "ratio": state.ratio,
                    "atBottom": state.atBottom,
                    "fragment": state.fragment as Any,
                ]
            ],
            contentWorld: Self.contentWorld
        )
    }

    func setZoom(_ value: Double) {
        webView.pageZoom = min(max(value, 0.5), 3.0)
    }

    func setContentWidth(_ value: Double?) {
        let normalized = value.map(ViewerLayoutPreferences.normalizedContentWidth)
        guard normalized != contentWidth else { return }
        contentWidth = normalized
        contentWidthRevision &+= 1
        guard shellReady else { return }

        let argument = normalized.map(NSNumber.init(value:)) ?? NSNull()
        let revision = contentWidthRevision
        Task { [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                "return await globalThis.marklookRuntime.setContentWidth(width, revision);",
                arguments: [
                    "width": argument,
                    "revision": NSNumber(value: revision),
                ],
                contentWorld: Self.contentWorld
            )
        }
    }

    func printDocument() {
        guard !Self.outputOperationInProgress,
              NSPrintOperation.current == nil
        else { return }

        Self.outputOperationInProgress = true
        defer { Self.outputOperationInProgress = false }
        let operation = webView.printOperation(with: .init())
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    @discardableResult
    func exportPDF(documentURL: URL, completion: @escaping () -> Void) -> Bool {
        guard !pdfExportInProgress,
              !Self.outputOperationInProgress,
              NSPrintOperation.current == nil,
              let window = webView.window
        else { return false }

        Self.outputOperationInProgress = true
        pdfExportInProgress = true
        pdfExportCompletion = completion
        let defaultFileName = Self.pdfDefaultFileName(for: documentURL)
        let printInfo = Self.pdfPrintInfo()
        let pdfInfo = NSPDFInfo()
        pdfInfo.orientation = printInfo.orientation
        pdfInfo.paperSize = printInfo.paperSize

        let panel = NSPDFPanel()
        panel.defaultFileName = defaultFileName
        var options = panel.options
        options.formUnion([.showsPaperSize, .showsOrientation])
        options.remove(.requestsParentDirectory)
        panel.options = options
        pdfPanel = panel
        panel.beginSheet(with: pdfInfo, modalFor: window) { [self] response in
            pdfPanel = nil
            guard response == NSApplication.ModalResponse.OK.rawValue,
                  let printInfo = Self.pdfPrintInfo(for: pdfInfo),
                  NSPrintOperation.current == nil,
                  webView.window === window
            else {
                finishPDFExport()
                return
            }

            let operation = webView.printOperation(with: printInfo)
            operation.jobTitle = defaultFileName
            operation.showsPrintPanel = false
            operation.showsProgressPanel = true
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(pdfExportDidFinish(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        return true
    }

    static func pdfDefaultFileName(for documentURL: URL) -> String {
        let fileName = documentURL.deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? "Document" : fileName
    }

    static func pdfPrintInfo() -> NSPrintInfo {
        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return printInfo
    }

    static func pdfPrintInfo(for pdfInfo: NSPDFInfo) -> NSPrintInfo? {
        guard let destinationURL = pdfInfo.url,
              destinationURL.isFileURL,
              !destinationURL.lastPathComponent.isEmpty,
              (try? destinationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return nil }

        let printInfo = pdfPrintInfo()
        printInfo.takeSettings(from: pdfInfo)
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destinationURL as NSURL
        printInfo.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        return printInfo
    }

    @objc
    private func pdfExportDidFinish(
        _: NSPrintOperation,
        success _: Bool,
        contextInfo _: UnsafeMutableRawPointer?
    ) {
        finishPDFExport()
    }

    private func finishPDFExport() {
        Self.outputOperationInProgress = false
        pdfExportInProgress = false
        pdfPanel = nil
        let completion = pdfExportCompletion
        pdfExportCompletion = nil
        completion?()
    }

    private func loadShell() {
        let shell = """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <meta http-equiv="Content-Security-Policy" content="\(Self.contentSecurityPolicy)">
            <style>
              html, body { background: #ffffff; color: #1f2328; margin: 0; min-height: 100%; }
              #content-host { min-height: 100vh; visibility: hidden; }
              @media screen and (prefers-color-scheme: dark) {
                html, body { background: #0d1117; color: #e6edf3; }
              }
              @media print {
                html, body { background: #ffffff; color: #1f2328; }
              }
            </style>
          </head>
          <body><main id="content-host"></main></body>
        </html>
        """
        webView.loadHTMLString(shell, baseURL: nil)
    }

    private func waitUntilShellReady() async {
        if shellReady { return }
        await withCheckedContinuation { continuation in
            shellWaiters.append(continuation)
        }
    }

    private func finishShellLoad() {
        guard !shellReady else { return }
        shellReady = true
        let waiters = shellWaiters
        shellWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func asset(named name: String, extension ext: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let value = try? String(contentsOf: url, encoding: .utf8)
        {
            return value
        }
        guard let root = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }
        let wanted = "\(name).\(ext)".lowercased()
        for case let url as URL in enumerator where url.lastPathComponent.lowercased() == wanted {
            if let value = try? String(contentsOf: url, encoding: .utf8) { return value }
        }
        return nil
    }

    private static func rewriteBundledKaTeXFonts(_ css: String) -> String {
        css.replacingOccurrences(of: "fonts/", with: "mark-resource://bundle/katex/fonts/")
    }
}

extension WebViewStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        finishShellLoad()
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error
    ) {
        finishShellLoad()
        onNavigationFailure?(error.localizedDescription)
    }

    func webView(
        _: WKWebView,
        didFail _: WKNavigation!,
        withError error: any Error
    ) {
        finishShellLoad()
        onNavigationFailure?(error.localizedDescription)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "about", navigationAction.navigationType != .linkActivated {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "mark-resource" || url.scheme == RemoteResourceURL.scheme {
            // Subresources are handled directly by WKURLSchemeHandler. Never allow the resource
            // scheme to become a navigated document in any frame.
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if url.scheme == "mark-navigation",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let source = components.queryItems?.first(where: { $0.name == "source" })?.value
        {
            onDocumentNavigation?(.init(
                source: source,
                openInNewTab: navigationAction.modifierFlags.contains(.command)
            ))
            decisionHandler(.cancel)
            return
        }

        if let fragment = url.fragment {
            Task { await navigate(toAnchor: fragment) }
        }
        decisionHandler(.cancel)
    }
}

extension WebViewStore: WKUIDelegate {}
