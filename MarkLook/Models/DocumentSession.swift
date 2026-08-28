import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class DocumentSession {
    private(set) var currentURL: URL
    private(set) var displayedURL: URL?
    private(set) var phase: ViewerPhase = .loading
    private(set) var issue: ViewerIssue?
    private(set) var warnings: [RenderWarning] = []
    private(set) var isProcessingVisible = false
    private(set) var zoom: Double
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isExportingPDF = false
    var isFindPresented = false
    var findQuery = ""
    var openDocumentRequest: OpenDocumentRequest?

    @ObservationIgnored let webViewStore: WebViewStore
    @ObservationIgnored private let renderer: any RenderEngine
    @ObservationIgnored private let bookmarkStore: BookmarkStore
    @ObservationIgnored private let recentDocuments: RecentDocuments
    @ObservationIgnored private let rootDocumentURL: URL
    @ObservationIgnored private var scopes: [LocalResourceScope]
    @ObservationIgnored private var leases: [SecurityScopedLease]
    @ObservationIgnored private var scheduler: ReloadScheduler<PreparedDocument>?
    @ObservationIgnored private var documentWatcher: DirectoryWatcher?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var activityToken = UUID()
    @ObservationIgnored private var pendingNavigationSource: String?
    @ObservationIgnored private var backHistory: [URL] = []
    @ObservationIgnored private var forwardHistory: [URL] = []
    @ObservationIgnored private let resourceAuthority: String
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didRestoreScroll = false
    @ObservationIgnored private var currentResources = Set<ResourceReference>()
    @ObservationIgnored private var resourceRevision: UInt64 = 0
    @ObservationIgnored private var presentationGate = ReloadPresentationGate()
    @ObservationIgnored private var monitoringIssue: ViewerIssue?
    @ObservationIgnored private var markdownLineBreakMode: MarkdownLineBreakMode
    @ObservationIgnored private var remoteContentPolicy: RemoteContentPolicy
    @ObservationIgnored private var shouldOpenInCurrentWindow: ((URL, URL) -> Bool)?

    init(
        documentURL: URL,
        renderer: any RenderEngine = GFMRenderEngine(),
        bookmarkStore: BookmarkStore = BookmarkStore(),
        recentDocuments: RecentDocuments = .shared,
        markdownLineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks,
        remoteContentPolicy: RemoteContentPolicy = .init()
    ) {
        let rootURL = Self.normalizedDocumentURL(documentURL)
        let restoredNavigation = Self.persistedNavigation(for: rootURL)
        let initialURL = restoredNavigation?.currentURL ?? rootURL
        currentURL = initialURL
        self.renderer = renderer
        self.bookmarkStore = bookmarkStore
        self.recentDocuments = recentDocuments
        self.markdownLineBreakMode = markdownLineBreakMode
        self.remoteContentPolicy = remoteContentPolicy
        rootDocumentURL = rootURL
        resourceAuthority = UUID().uuidString.lowercased()
        backHistory = restoredNavigation?.backHistory ?? []
        forwardHistory = restoredNavigation?.forwardHistory ?? []

        let restored = bookmarkStore.resolveAll()
        let directURLs = Set([rootURL, initialURL].map(Self.fileAccessURL))
        leases = Self.deduplicatedLeases(
            restored.leases + directURLs.map(SecurityScopedLease.init(url:))
        )
        scopes = Self.deduplicatedScopes(
            restored.scopes + directURLs.map(LocalResourceScope.file)
        )
        zoom = Self.persistedZoom(for: initialURL)

        webViewStore = WebViewStore(
            documentURL: initialURL,
            scopes: scopes,
            resourceAuthority: resourceAuthority,
            remoteContentPolicy: remoteContentPolicy
        )
        webViewStore.setZoom(zoom)
        webViewStore.onDocumentNavigation = { [weak self] request in
            self?.handleNavigation(request)
        }
        webViewStore.onNavigationFailure = { [weak self] message in
            self?.showOverlay(kind: .rendering, title: "Display Error", message: message)
        }
        try? bookmarkStore.save(Self.fileAccessURL(rootURL), asFolder: false)
        if initialURL.path != rootURL.path {
            try? bookmarkStore.save(Self.fileAccessURL(initialURL), asFolder: false)
        }
        updateHistoryFlags()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        // Updating the observable Recent Files model during this object's SwiftUI-driven
        // construction can invalidate the window graph while AppKit is laying it out.
        recentDocuments.note(Self.fileAccessURL(currentURL))
        configureReloadPipeline()
    }

    func reload() {
        guard let scheduler else { return }
        beginActivity()
        let sources = currentResources.flatMap { resource in
            [resource.source, resource.resolvedURL?.absoluteString].compactMap { $0 }
        }
        let revision = nextResourceRevision()
        Task {
            if !sources.isEmpty {
                await webViewStore.invalidateResources(Array(sources), revision: revision)
            }
            await scheduler.reloadNow()
        }
    }

    func zoomIn() { setZoom(zoom + 0.1) }
    func zoomOut() { setZoom(zoom - 0.1) }
    func resetZoom() { setZoom(1) }

    func setContentWidth(_ value: Double?) {
        webViewStore.setContentWidth(value)
    }

    func setMarkdownLineBreakMode(_ mode: MarkdownLineBreakMode) {
        guard markdownLineBreakMode != mode else { return }
        markdownLineBreakMode = mode
        if didStart {
            configureReloadPipeline()
        }
    }

    func setRemoteContentPolicy(_ policy: RemoteContentPolicy) {
        guard remoteContentPolicy != policy else { return }
        remoteContentPolicy = policy
        // Revoke the network boundary before replacing the rendered document so removed hosts
        // cannot finish an in-flight request during the next render.
        webViewStore.updateRemoteContentPolicy(policy)
        if didStart {
            configureReloadPipeline()
        }
    }

    func setCurrentWindowNavigationPolicy(
        _ policy: @escaping (URL, URL) -> Bool
    ) {
        shouldOpenInCurrentWindow = policy
    }

    func openRoutedFile(_ url: URL) {
        let normalized = Self.normalizedDocumentURL(url)
        guard normalized != currentURL else { return }
        openFile(
            normalized,
            recordingHistory: true,
            checkingWindowIdentity: false
        )
    }

    func findNext(backwards: Bool = false) {
        let query = findQuery
        Task { _ = await webViewStore.find(query, backwards: backwards) }
    }

    func printDocument() {
        webViewStore.printDocument()
    }

    func exportPDF() {
        guard let displayedURL, !isExportingPDF else { return }
        isExportingPDF = true
        let started = webViewStore.exportPDF(documentURL: displayedURL) { [weak self] in
            self?.isExportingPDF = false
        }
        if !started { isExportingPDF = false }
    }

    func goBack() {
        guard let destination = backHistory.last,
              canOpenInCurrentWindow(destination) else { return }
        backHistory.removeLast()
        forwardHistory.append(currentURL)
        openFile(destination, recordingHistory: false, checkingWindowIdentity: false)
    }

    func goForward() {
        guard let destination = forwardHistory.last,
              canOpenInCurrentWindow(destination) else { return }
        forwardHistory.removeLast()
        backHistory.append(currentURL)
        openFile(destination, recordingHistory: false, checkingWindowIdentity: false)
    }

    func grantFolderAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.message = "Choose a folder whose local images, stylesheets, and fonts MarkLook may read."
        panel.prompt = "Grant Access"
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in self?.didGrant(folder: folder) }
        }
    }

    func locateFile() {
        let missingURL = currentURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.markLookMarkdown, .html]
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.prompt = "Locate"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.relocateFile(to: url, replacing: missingURL)
            }
        }
    }

    func dismissIssue() {
        issue = nil
    }

    func persistViewState() {
        let url = currentURL
        persistNavigation()
        Task { [webViewStore] in
            guard let state = await webViewStore.captureScrollState(),
                  let data = try? PropertyListEncoder().encode(state)
            else { return }
            UserDefaults.standard.set(data, forKey: Self.scrollKey(for: url))
        }
    }

    func openDroppedFile(_ url: URL) {
        guard let route = ViewerWindowRoute.viewing(url),
              let documentURL = route.documentURL else {
            NSWorkspace.shared.open(url)
            return
        }
        openFile(documentURL, recordingHistory: true)
    }

    func consumeOpenDocumentRequest() {
        openDocumentRequest = nil
    }

    func reportOpenFailure(_ error: any Error) {
        showOverlay(
            kind: .reload,
            title: "Cannot Open File",
            message: error.localizedDescription
        )
    }

    private func configureReloadPipeline() {
        let pipelineEpoch = presentationGate.beginPipeline()
        stopReloadPipeline()
        monitoringIssue = nil
        phase = phase == .ready ? .ready : .loading
        beginActivity()

        let url = currentURL
        let format: DocumentFormat
        do {
            format = try DocumentFormat(url: url)
        } catch {
            handleInitialOrOverlayFailure(kind: .rendering, message: error.localizedDescription)
            return
        }
        let renderer = self.renderer
        let contextAuthority = resourceAuthority
        let markdownLineBreakMode = self.markdownLineBreakMode
        let remoteContentPolicy = self.remoteContentPolicy
        let scheduler = ReloadScheduler<PreparedDocument>(fileURL: url) { input in
            let clock = ContinuousClock()
            let decodeStarted = clock.now
            let decoded = try CharacterDecoder().decode(
                input.data,
                allowsHTMLMetaCharset: format == .html
            )
            let decodeDuration = decodeStarted.duration(to: clock.now)
            let sizeClass = try DocumentSizeClass.classify(byteCount: input.data.count)
            let renderStarted = clock.now
            let output = try await renderer.render(
                source: decoded.text,
                format: format,
                context: RenderContext(
                    documentURL: input.fileURL,
                    resourceAuthority: contextAuthority,
                    sizeClass: sizeClass,
                    markdownLineBreakMode: markdownLineBreakMode,
                    remoteContentPolicy: remoteContentPolicy
                )
            )
            let renderDuration = renderStarted.duration(to: clock.now)
            return PreparedDocument(
                renderOutput: output,
                decodeDuration: decodeDuration,
                renderDuration: renderDuration
            )
        }
        self.scheduler = scheduler

        do {
            let watcher = try DirectoryWatcher(fileURL: url)
            try watcher.start { [weak self, weak scheduler] change in
                Task { [weak self, weak scheduler] in
                    guard let scheduler else { return }
                    await ReloadChangeForwarder.forward(
                        observedAt: change.observedAt,
                        signalChange: { observedAt in
                            await scheduler.signalChange(observedAt: observedAt)
                        },
                        beginActivity: { [weak self] in
                            guard let self,
                                  self.presentationGate.isCurrent(pipelineEpoch)
                            else { return }
                            self.beginActivity()
                        }
                    )
                }
            }
            documentWatcher = watcher
        } catch {
            let issue = ViewerIssue(
                kind: .permission,
                title: "Automatic Reload Unavailable",
                message: error.localizedDescription
            )
            monitoringIssue = issue
            self.issue = issue
        }

        eventTask = Task { [weak self, weak scheduler] in
            guard let scheduler else { return }
            for await event in scheduler.events {
                guard !Task.isCancelled else { return }
                await self?.consume(
                    event,
                    scheduler: scheduler,
                    pipelineEpoch: pipelineEpoch
                )
            }
        }
        Task { await scheduler.reloadNow() }
    }

    private func consume(
        _ event: ReloadSchedulerEvent<PreparedDocument>,
        scheduler: ReloadScheduler<PreparedDocument>,
        pipelineEpoch: ReloadPipelineEpoch
    ) async {
        guard presentationGate.isCurrent(pipelineEpoch) else { return }

        switch event {
        case let .loaded(snapshot):
            guard await scheduler.isCurrent(snapshot.generation),
                  presentationGate.isCurrent(pipelineEpoch),
                  let presentationTicket = presentationGate.issueTicket(for: pipelineEpoch)
            else { return }
            do {
                let webStartedAt = ContinuousClock().now
                let preserveScroll = DocumentUpdatePolicy.preservesScroll(
                    displayedURL: displayedURL,
                    currentURL: currentURL
                )
                let result = try await webViewStore.apply(
                    output: snapshot.output.renderOutput,
                    generation: presentationTicket.webGeneration,
                    explicitAnchor: DocumentUpdatePolicy.explicitAnchor(
                        for: currentURL,
                        preservingScroll: preserveScroll
                    ),
                    preserveScroll: preserveScroll
                )
                let webRoundTrip = webStartedAt.duration(to: ContinuousClock().now)
                let isCurrentSchedulerGeneration = await scheduler.isCurrent(snapshot.generation)
                let isCurrentPresentation = presentationGate.accepts(presentationTicket)
                ReloadPerformanceLogger.record(
                    snapshot: snapshot,
                    decode: snapshot.output.decodeDuration,
                    render: snapshot.output.renderDuration,
                    renderStages: snapshot.output.renderOutput.timing,
                    webRoundTrip: webRoundTrip,
                    webRuntimeMilliseconds: result.webDurationMilliseconds,
                    stale: result.stale
                        || !isCurrentSchedulerGeneration
                        || !isCurrentPresentation
                )
                guard !result.stale,
                      isCurrentSchedulerGeneration,
                      isCurrentPresentation,
                      await scheduler.acknowledgeApplied(snapshot.generation) else {
                    return
                }
                guard presentationGate.accepts(presentationTicket) else { return }
                currentResources = snapshot.output.renderOutput.resources
                warnings = result.warnings + resourceWarnings(for: currentResources)
                displayedURL = currentURL
                phase = .ready
                issue = monitoringIssue
                finishActivity()
                if !didRestoreScroll {
                    didRestoreScroll = true
                    if currentURL.fragment == nil,
                       let savedState = Self.persistedScroll(for: currentURL) {
                        await webViewStore.restoreScrollState(savedState)
                    }
                }
                promptForFolderAccessIfNeeded(resources: currentResources)
            } catch {
                guard presentationGate.accepts(presentationTicket) else { return }
                finishActivity()
                handleInitialOrOverlayFailure(kind: .rendering, message: error.localizedDescription)
            }

        case .unchanged:
            issue = DocumentUpdatePolicy.issueAfterUnchangedReload(
                currentIssue: issue,
                monitoringIssue: monitoringIssue
            )
            finishActivity()

        case let .failed(failure):
            finishActivity()
            let kind: ViewerIssueKind = failure.kind == .temporarilyMissing ? .moved : .reload
            handleInitialOrOverlayFailure(kind: kind, message: failure.message)
        }
    }

    private func handleNavigation(_ request: WebNavigationRequest) {
        if request.source.hasPrefix("#") {
            Task { await webViewStore.navigate(toAnchor: String(request.source.dropFirst())) }
            return
        }
        do {
            let validatedTarget = try LocalPathValidator().validate(
                requestPath: request.source,
                relativeTo: currentURL.deletingLastPathComponent(),
                allowedScopes: scopes
            )
            var targetComponents = URLComponents(
                url: validatedTarget,
                resolvingAgainstBaseURL: false
            )
            targetComponents?.fragment = URLComponents(
                string: request.source
            )?.fragment
            let target = targetComponents?.url ?? validatedTarget
            if (try? DocumentFormat(url: target)) == nil {
                NSWorkspace.shared.open(target)
            } else if request.openInNewTab {
                openDocumentRequest = OpenDocumentRequest(url: target)
            } else {
                openFile(target, recordingHistory: true)
            }
        } catch LocalPathValidationError.outsideAllowedScopes {
            pendingNavigationSource = request.source
            showOverlay(
                kind: .permission,
                title: "Folder Access Required",
                message: "Grant access to the folder containing this local file before opening it."
            )
        } catch {
            showOverlay(kind: .reload, title: "Cannot Open Link", message: error.localizedDescription)
        }
    }

    private func openFile(
        _ url: URL,
        recordingHistory: Bool,
        checkingWindowIdentity: Bool = true,
        replacingRecentURL: URL? = nil
    ) {
        let normalized = Self.normalizedDocumentURL(url)
        if checkingWindowIdentity,
           !canOpenInCurrentWindow(normalized) {
            return
        }
        if recordingHistory, normalized != currentURL {
            backHistory.append(currentURL)
            forwardHistory.removeAll()
        }
        currentURL = normalized
        let accessURL = Self.fileAccessURL(normalized)
        retainAccess(to: accessURL, asFolder: false)
        try? bookmarkStore.save(accessURL, asFolder: false)
        recentDocuments.note(accessURL, replacing: replacingRecentURL)
        webViewStore.updateAccess(documentURL: normalized, scopes: scopes)
        zoom = Self.persistedZoom(for: normalized)
        webViewStore.setZoom(zoom)
        didRestoreScroll = false
        updateHistoryFlags()
        persistNavigation()
        configureReloadPipeline()
    }

    private func canOpenInCurrentWindow(_ url: URL) -> Bool {
        shouldOpenInCurrentWindow?(currentURL, Self.normalizedDocumentURL(url)) ?? true
    }

    func relocateFile(to url: URL, replacing missingURL: URL) {
        let normalized = Self.normalizedDocumentURL(url)
        guard Self.isSupportedDocumentURL(normalized),
              canOpenInCurrentWindow(normalized) else { return }
        let missingAccessURL = Self.fileAccessURL(missingURL)
        backHistory.removeAll { Self.fileAccessURL($0) == missingAccessURL }
        forwardHistory.removeAll { Self.fileAccessURL($0) == missingAccessURL }
        openFile(
            normalized,
            recordingHistory: false,
            checkingWindowIdentity: false,
            replacingRecentURL: missingAccessURL
        )
    }

    private func didGrant(folder: URL) {
        do {
            try bookmarkStore.save(folder, asFolder: true)
            retainAccess(to: folder, asFolder: true)
            webViewStore.updateAccess(documentURL: currentURL, scopes: scopes)
            issue = nil
            if let pendingNavigationSource {
                self.pendingNavigationSource = nil
                handleNavigation(.init(source: pendingNavigationSource, openInNewTab: false))
            } else if documentWatcher == nil {
                // A file-scoped sandbox grant may allow reading the document while denying the
                // parent-directory descriptor used for atomic-save monitoring. Retry the whole
                // pipeline once a folder grant is available instead of leaving reload disabled.
                configureReloadPipeline()
            } else {
                reload()
            }
        } catch {
            showOverlay(kind: .permission, title: "Access Was Not Saved", message: error.localizedDescription)
        }
    }

    private func promptForFolderAccessIfNeeded(resources: Set<ResourceReference>) {
        let validator = LocalPathValidator()
        let needsAccess = resources.compactMap(\.resolvedURL).contains { url in
            do {
                _ = try validator.validate(fileURL: url, allowedScopes: scopes)
                return false
            } catch LocalPathValidationError.outsideAllowedScopes {
                return true
            } catch {
                return false
            }
        }
        if needsAccess {
            showOverlay(
                kind: .permission,
                title: "Local Resources Need Access",
                message: "Grant folder access to load referenced images, stylesheets, and fonts."
            )
        }
    }

    private func resourceWarnings(for resources: Set<ResourceReference>) -> [RenderWarning] {
        resources.compactMap { resource in
            guard let url = resource.resolvedURL,
                  !FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return RenderWarning(message: "Missing \(resource.kind.rawValue): \(resource.source)")
        }
    }

    private func setZoom(_ newValue: Double) {
        zoom = min(max(newValue, 0.5), 3)
        webViewStore.setZoom(zoom)
        UserDefaults.standard.set(zoom, forKey: Self.zoomKey(for: currentURL))
    }

    private func nextResourceRevision() -> UInt64 {
        resourceRevision &+= 1
        return resourceRevision
    }

    private func beginActivity() {
        activityToken = UUID()
        let token = activityToken
        spinnerTask?.cancel()
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, self?.activityToken == token else { return }
            self?.isProcessingVisible = true
        }
    }

    private func finishActivity() {
        activityToken = UUID()
        spinnerTask?.cancel()
        spinnerTask = nil
        isProcessingVisible = false
    }

    private func handleInitialOrOverlayFailure(kind: ViewerIssueKind, message: String) {
        if phase != .ready { phase = .failedInitially }
        showOverlay(kind: kind, title: kind == .moved ? "File Not Found" : "Update Failed", message: message)
    }

    private func showOverlay(kind: ViewerIssueKind, title: String, message: String) {
        issue = ViewerIssue(kind: kind, title: title, message: message)
    }

    private func stopReloadPipeline() {
        eventTask?.cancel()
        eventTask = nil
        documentWatcher?.cancel()
        documentWatcher = nil
        if let scheduler { Task { await scheduler.cancel() } }
        scheduler = nil
    }

    private func retainAccess(to url: URL, asFolder: Bool) {
        let normalized = Self.fileAccessURL(url)
        let scope: LocalResourceScope = asFolder ? .folder(normalized) : .file(normalized)
        if !scopes.contains(scope) {
            scopes.append(scope)
        }
        if !leases.contains(where: { Self.fileAccessURL($0.url) == normalized }) {
            leases.append(SecurityScopedLease(url: normalized))
        }
    }

    private func updateHistoryFlags() {
        canGoBack = !backHistory.isEmpty
        canGoForward = !forwardHistory.isEmpty
    }

    private func persistNavigation() {
        let state = PersistedNavigationState(
            currentURL: currentURL,
            backHistory: backHistory,
            forwardHistory: forwardHistory
        )
        guard let data = try? PropertyListEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.navigationKey(for: rootDocumentURL))
        UserDefaults.standard.set(data, forKey: Self.navigationKey(for: currentURL))
    }

    private struct PersistedNavigationState: Codable {
        let currentURL: URL
        let backHistory: [URL]
        let forwardHistory: [URL]
    }

    private static func normalizedDocumentURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard let fragment = url.fragment,
              var components = URLComponents(url: standardized, resolvingAgainstBaseURL: false)
        else { return standardized }
        components.fragment = fragment
        return components.url ?? standardized
    }

    private static func fileAccessURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.standardizedFileURL
        }
        components.fragment = nil
        components.query = nil
        return components.url?.standardizedFileURL ?? url.standardizedFileURL
    }

    private static func deduplicatedScopes(
        _ candidates: [LocalResourceScope]
    ) -> [LocalResourceScope] {
        var seen = Set<LocalResourceScope>()
        return candidates.compactMap { scope in
            let normalized: LocalResourceScope = switch scope {
            case let .file(url): .file(fileAccessURL(url))
            case let .folder(url): .folder(fileAccessURL(url))
            }
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func deduplicatedLeases(
        _ candidates: [SecurityScopedLease]
    ) -> [SecurityScopedLease] {
        var seen = Set<URL>()
        return candidates.filter { lease in
            seen.insert(fileAccessURL(lease.url)).inserted
        }
    }

    private static func persistedNavigation(for rootURL: URL) -> PersistedNavigationState? {
        guard let data = UserDefaults.standard.data(forKey: navigationKey(for: rootURL)),
              let decoded = try? PropertyListDecoder().decode(PersistedNavigationState.self, from: data),
              isSupportedDocumentURL(decoded.currentURL)
        else { return nil }
        return PersistedNavigationState(
            currentURL: normalizedDocumentURL(decoded.currentURL),
            backHistory: decoded.backHistory
                .filter(isSupportedDocumentURL)
                .map(normalizedDocumentURL),
            forwardHistory: decoded.forwardHistory
                .filter(isSupportedDocumentURL)
                .map(normalizedDocumentURL)
        )
    }

    private static func isSupportedDocumentURL(_ url: URL) -> Bool {
        url.isFileURL && (try? DocumentFormat(url: url)) != nil
    }

    private static func navigationKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "DocumentNavigation.\(digest)"
    }

    private static func zoomKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "DocumentZoom.\(digest)"
    }

    private static func persistedZoom(for url: URL) -> Double {
        let value = UserDefaults.standard.double(forKey: zoomKey(for: url))
        return value == 0 ? 1 : min(max(value, 0.5), 3)
    }

    private static func scrollKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "DocumentScroll.\(digest)"
    }

    private static func persistedScroll(for url: URL) -> PersistedScrollState? {
        guard let data = UserDefaults.standard.data(forKey: scrollKey(for: url)) else { return nil }
        return try? PropertyListDecoder().decode(PersistedScrollState.self, from: data)
    }

    deinit {
        eventTask?.cancel()
        spinnerTask?.cancel()
        documentWatcher?.cancel()
        if let scheduler { Task { await scheduler.cancel() } }
    }
}
