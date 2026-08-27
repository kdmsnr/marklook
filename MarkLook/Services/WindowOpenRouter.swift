import AppKit

/// One opening path shared by the menu, Welcome view, Finder/Dock, Recent Files,
/// and command-clicked document links.
@MainActor
final class WindowOpenRouter {
    static let shared = WindowOpenRouter()

    typealias WindowOpener = @MainActor (ViewerWindowRoute) -> Void

    private var openWindow: WindowOpener?
    private var queuedExternalURLs: [URL] = []
    private var hasRegisteredAWindow = false
    private var openingLeases: [ViewerWindowRoute: SecurityScopedLease] = [:]

    private init() {}

    func install(openWindow: @escaping WindowOpener) {
        self.openWindow = openWindow
        drainExternalURLsIfReady()
    }

    /// Called by NSApplicationDelegate for Finder's Open With and Dock drops.
    func enqueueExternalOpen(_ urls: [URL]) {
        queuedExternalURLs.append(contentsOf: urls)
        drainExternalURLsIfReady()
    }

    /// Opens into a Welcome tab without replacing its NSWindow. If there is no Welcome tab,
    /// a new value-backed window is opened and attached as a native tab to the source window.
    @discardableResult
    func open(
        _ url: URL,
        from sourceWindow: NSWindow? = nil,
        replacingRecentURL: URL? = nil,
        replaceCurrentWelcome: ((ViewerWindowRoute) -> Void)? = nil
    ) -> Bool {
        guard url.isFileURL,
              (try? DocumentFormat(url: url)) != nil else {
            return false
        }

        // The URL delivered by NSOpenPanel, Finder, or a resolved bookmark carries the
        // sandbox extension. Start access and create the bookmark from that exact URL before
        // constructing the normalized URL used only for scene identity and presentation.
        let lease = SecurityScopedLease(url: url)
        try? BookmarkStore().save(url, asFolder: false)

        guard let route = ViewerWindowRoute.viewing(url),
              let documentURL = route.documentURL else {
            return false
        }

        let accessURL = ViewerWindowRoute.fileAccessURL(documentURL)
        retainLease(lease, for: route)

        let didOpen: Bool
        if WindowTabCoordinator.replaceWelcome(
            in: sourceWindow,
            with: route
        ) {
            didOpen = true
        } else if let replaceCurrentWelcome,
                  !WindowTabCoordinator.focusExistingWindow(for: route) {
            // The SwiftUI binding is available before its backing NSWindow registration during
            // first launch. Updating it directly still keeps the exact same window instance.
            replaceCurrentWelcome(route)
            didOpen = true
        } else if let openWindow {
            WindowTabCoordinator.open(
                route,
                asTabOf: sourceWindow ?? WindowTabCoordinator.preferredParentWindow(),
                perform: { openWindow(route) }
            )
            didOpen = true
        } else {
            queuedExternalURLs.append(url)
            didOpen = false
        }

        if didOpen {
            RecentDocuments.shared.note(accessURL, replacing: replacingRecentURL)
        }
        return didOpen
    }

    func openNewTab(from sourceWindow: NSWindow? = nil) {
        guard let openWindow else { return }
        let route = ViewerWindowRoute.welcome(UUID())
        WindowTabCoordinator.open(
            route,
            asTabOf: sourceWindow ?? WindowTabCoordinator.preferredParentWindow(),
            perform: { openWindow(route) }
        )
    }

    func windowDidRegister() {
        hasRegisteredAWindow = true
        drainExternalURLsIfReady()
    }

    /// The session has established its own security-scoped lease and no longer needs the
    /// handoff lease retained while SwiftUI creates or updates the destination content.
    func documentSessionDidStart(for url: URL) {
        guard let route = ViewerWindowRoute.viewing(url) else { return }
        openingLeases.removeValue(forKey: route.normalizedIdentity)
    }

    private func drainExternalURLsIfReady() {
        guard openWindow != nil,
              hasRegisteredAWindow || WindowTabCoordinator.hasRegisteredWindows,
              !queuedExternalURLs.isEmpty else {
            return
        }

        let urls = queuedExternalURLs
        queuedExternalURLs.removeAll()
        var parent = WindowTabCoordinator.preferredParentWindow()
        for url in urls where open(url, from: parent) {
            if let route = ViewerWindowRoute.viewing(url) {
                parent = WindowTabCoordinator.window(for: route) ?? parent
            }
        }
    }

    private func retainLease(
        _ lease: SecurityScopedLease,
        for route: ViewerWindowRoute
    ) {
        let identity = route.normalizedIdentity
        openingLeases[identity] = lease
        Task { @MainActor [weak self, weak lease] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                  let lease,
                  self.openingLeases[identity] === lease else { return }
            self.openingLeases.removeValue(forKey: identity)
        }
    }
}
