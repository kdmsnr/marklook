import AppKit

/// The narrow AppKit boundary for native tab attachment and existing-window lookup.
@MainActor
enum WindowTabCoordinator {
    static let sharedTabbingIdentifier = "com.example.MarkLook.document-tabs"

    enum OpenDisposition: Equatable {
        case focusedExisting
        case awaitingExistingRequest
        case requestedNewWindow
    }

    private final class WeakRegistration {
        weak var value: WindowTabRegistrationNSView?
        weak var window: NSWindow?

        init(_ value: WindowTabRegistrationNSView?, window: NSWindow?) {
            self.value = value
            self.window = window
        }
    }

    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow?) {
            self.value = value
        }
    }

    private struct PendingOpen {
        let id: UUID
        let parent: WeakWindow
    }

    private static var registrations: [ViewerWindowRoute: WeakRegistration] = [:]
    private static var pendingOpens: [ViewerWindowRoute: PendingOpen] = [:]

    static var hasRegisteredWindows: Bool {
        cleanup()
        return registrations.values.contains(where: { $0.window != nil })
    }

    static func preferredParentWindow() -> NSWindow? {
        preferredParentWindow(
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow,
            orderedWindows: NSApp.orderedWindows
        )
    }

    /// An open panel can still be key when its completion runs, so panels are never tab parents.
    static func preferredParentWindow(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        orderedWindows: [NSWindow]
    ) -> NSWindow? {
        ([keyWindow, mainWindow].compactMap { $0 } + orderedWindows)
            .first(where: isTabEligible)
    }

    /// AppKit decides whether to aggregate a newly shown window into a native tab group at
    /// presentation time, so these two properties must be set synchronously before that point.
    static func configureTabbingBeforeShow(for window: NSWindow) {
        guard isTabEligible(window) else { return }
        window.tabbingIdentifier = sharedTabbingIdentifier
        window.tabbingMode = .preferred
    }

    static func configureDraggableTabs(for window: NSWindow) {
        configureTabbingBeforeShow(for: window)

        // A visible tab bar makes a single tab draggable into another MarkLook window.
        if window.tabGroup?.isTabBarVisible != true {
            window.toggleTabBar(nil)
        }
    }

    static func configureWindowMetadata(
        for window: NSWindow,
        route: ViewerWindowRoute
    ) {
        window.title = route.windowTitle
        window.representedURL = route.documentURL.map(ViewerWindowRoute.fileAccessURL)
    }

    @discardableResult
    static func open(
        _ route: ViewerWindowRoute,
        asTabOf parent: NSWindow?,
        perform: () -> Void
    ) -> OpenDisposition {
        cleanup()
        let identity = route.normalizedIdentity
        if focusExistingWindow(for: route) {
            return .focusedExisting
        }
        if pendingOpens[identity] != nil {
            return .awaitingExistingRequest
        }

        let pendingID = UUID()
        pendingOpens[identity] = PendingOpen(
            id: pendingID,
            parent: WeakWindow(parent)
        )
        perform()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard pendingOpens[identity]?.id == pendingID else { return }
            pendingOpens.removeValue(forKey: identity)
        }
        return .requestedNewWindow
    }

    /// Turns a Welcome tab into a document in place. No NSWindow is created or closed.
    @discardableResult
    static func replaceWelcome(
        in preferredWindow: NSWindow?,
        with route: ViewerWindowRoute
    ) -> Bool {
        cleanup()
        let identity = route.normalizedIdentity
        if let existing = registrations[identity],
           let existingWindow = existing.window {
            existing.value?.replaceRoute(
                with: route,
                registeredWindow: existingWindow
            )
            focus(existingWindow)
            if let welcome = welcomeRegistration(in: preferredWindow),
               let welcomeWindow = welcome.window,
               welcomeWindow !== existingWindow {
                welcomeWindow.performClose(nil)
            }
            return true
        }

        guard let welcome = welcomeRegistration(in: preferredWindow) else {
            return false
        }
        welcome.value?.replaceRoute(with: route, registeredWindow: welcome.window)
        if let window = welcome.window {
            focus(window)
        }
        return true
    }

    @discardableResult
    static func focusExistingWindow(
        for route: ViewerWindowRoute,
        excluding excludedWindow: NSWindow? = nil
    ) -> Bool {
        cleanup()
        guard let existing = registrations[route.normalizedIdentity],
              let window = existing.window,
              window !== excludedWindow else {
            return false
        }
        existing.value?.replaceRoute(with: route, registeredWindow: window)
        focus(window)
        return true
    }

    static func window(for route: ViewerWindowRoute?) -> NSWindow? {
        guard let route else { return nil }
        cleanup()
        return registrations[route.normalizedIdentity]?.window
    }

    static func register(
        _ registration: WindowTabRegistrationNSView,
        window: NSWindow,
        route: ViewerWindowRoute
    ) {
        cleanup()
        let identity = route.normalizedIdentity
        configureTabbingBeforeShow(for: window)
        let pendingParent = pendingOpens.removeValue(forKey: identity)?.parent.value
        if let existing = registrations[identity],
           let existingWindow = existing.window,
           existingWindow !== window {
            let concealedAlphaValue = concealUntilTabResolution(
                window,
                pendingParent: visibleTabParent(
                    preferred: pendingParent,
                    fallback: existingWindow,
                    excluding: window
                )
            )
            resolveRegistrationCollision(
                registration,
                window: window,
                identity: identity,
                pendingParent: pendingParent,
                concealedAlphaValue: concealedAlphaValue
            )
            return
        }
        registrations[identity] = WeakRegistration(registration, window: window)

        // SwiftUI's openWindow always creates an NSWindow first. Keep that transient window
        // transparent before returning from viewDidMoveToWindow, then reveal it only after it
        // belongs to the requested native tab group. The tab mutation itself remains deferred
        // by one actor turn because mutating it during the SwiftUI view-move callback is unsafe.
        let concealedAlphaValue = concealUntilTabResolution(
            window,
            pendingParent: pendingParent
        )
        finishRegistrationAfterViewMove(
            registration,
            window: window,
            identity: identity,
            pendingParent: pendingParent,
            concealedAlphaValue: concealedAlphaValue
        )
    }

    static func unregister(
        _ registration: WindowTabRegistrationNSView,
        route: ViewerWindowRoute
    ) {
        let identity = route.normalizedIdentity
        guard registrations[identity]?.value === registration else { return }
        registrations.removeValue(forKey: identity)
    }

    static func inheritFrame(from parent: NSWindow, to window: NSWindow) {
        window.setFrame(parent.frame, display: false)
    }

    static func closeSelectedTab() {
        guard let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        selectedWindowToClose(from: activeWindow).performClose(nil)
    }

    static func selectedWindowToClose(from activeWindow: NSWindow) -> NSWindow {
        activeWindow.tabGroup?.selectedWindow ?? activeWindow
    }

    @discardableResult
    private static func attach(_ window: NSWindow, to parent: NSWindow) -> Bool {
        inheritFrame(from: parent, to: window)
        let alreadyTabbedTogether = parent.tabGroup != nil
            && parent.tabGroup === window.tabGroup
        if !alreadyTabbedTogether {
            parent.addTabbedWindow(window, ordered: .above)
        }
        guard let tabGroup = parent.tabGroup,
              tabGroup === window.tabGroup else { return false }
        inheritFrame(from: parent, to: window)
        tabGroup.selectedWindow = window
        return true
    }

    private static func welcomeRegistration(
        in preferredWindow: NSWindow?
    ) -> WeakRegistration? {
        let welcomes = registrations.compactMap { route, reference -> WeakRegistration? in
            guard case .welcome = route else { return nil }
            return reference
        }
        if let preferredWindow {
            return welcomes.first(where: { $0.window === preferredWindow })
        }
        if let keyWindow = NSApp.keyWindow,
           let key = welcomes.first(where: { $0.window === keyWindow }) {
            return key
        }
        return welcomes.first(where: { $0.window?.isVisible == true }) ?? welcomes.first
    }

    private static func focus(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private static func finishRegistrationAfterViewMove(
        _ registration: WindowTabRegistrationNSView,
        window: NSWindow,
        identity: ViewerWindowRoute,
        pendingParent: NSWindow?,
        concealedAlphaValue: CGFloat?
    ) {
        Task { @MainActor [weak registration, weak window, weak pendingParent] in
            await Task.yield()
            guard let window else { return }
            defer {
                restorePresentation(
                    of: window,
                    concealedAlphaValue: concealedAlphaValue
                )
            }
            guard let registration,
                  registrations[identity]?.value === registration,
                  registrations[identity]?.window === window else { return }
            configureWindowMetadata(for: window, route: identity)
            configureDraggableTabs(for: window)
            var attachedAsTab = false
            if let pendingParent,
               pendingParent !== window,
               belongsToVisibleTabGroup(pendingParent) {
                attachedAsTab = attach(window, to: pendingParent)
            }
            if attachedAsTab {
                restorePresentation(
                    of: window,
                    concealedAlphaValue: concealedAlphaValue
                )
                focus(window)
            }
            WindowOpenRouter.shared.windowDidRegister()
        }
    }

    private static func resolveRegistrationCollision(
        _ registration: WindowTabRegistrationNSView,
        window: NSWindow,
        identity: ViewerWindowRoute,
        pendingParent: NSWindow?,
        concealedAlphaValue: CGFloat?
    ) {
        Task { @MainActor [weak registration, weak window, weak pendingParent] in
            await Task.yield()
            guard let window else { return }
            guard let registration,
                  registration.window === window else {
                restorePresentation(
                    of: window,
                    concealedAlphaValue: concealedAlphaValue
                )
                return
            }
            cleanup()
            if let currentWindow = registrations[identity]?.window,
               currentWindow !== window {
                focus(currentWindow)
                window.performClose(nil)
                return
            }

            // The originally registered tab may have closed while this task yielded. Adopt the
            // new window instead of leaving a visible but unregistered document window behind.
            registrations[identity] = WeakRegistration(registration, window: window)
            finishRegistrationAfterViewMove(
                registration,
                window: window,
                identity: identity,
                pendingParent: pendingParent,
                concealedAlphaValue: concealedAlphaValue
            )
        }
    }

    private static func visibleTabParent(
        preferred: NSWindow?,
        fallback: NSWindow,
        excluding window: NSWindow
    ) -> NSWindow? {
        if let preferred,
           preferred !== window,
           belongsToVisibleTabGroup(preferred) {
            return preferred
        }
        guard fallback !== window,
              belongsToVisibleTabGroup(fallback) else { return nil }
        return fallback
    }

    /// Returns the opacity to restore after the pending native-tab operation. Merely ordering
    /// the window out is insufficient because SwiftUI may order it front again before the
    /// deferred AppKit attachment runs.
    private static func concealUntilTabResolution(
        _ window: NSWindow,
        pendingParent: NSWindow?
    ) -> CGFloat? {
        guard let pendingParent,
              pendingParent !== window,
              belongsToVisibleTabGroup(pendingParent) else { return nil }
        let originalAlphaValue = window.alphaValue
        window.alphaValue = 0
        return originalAlphaValue
    }

    /// AppKit reports non-selected native tab windows as not visible even though their tab group
    /// is on screen. Such a window is still a valid attachment parent.
    private static func belongsToVisibleTabGroup(_ window: NSWindow) -> Bool {
        window.isVisible
            || window.tabGroup?.windows.contains(where: { $0.isVisible }) == true
    }

    private static func restorePresentation(
        of window: NSWindow,
        concealedAlphaValue: CGFloat?
    ) {
        guard let concealedAlphaValue else { return }
        window.alphaValue = concealedAlphaValue
    }

    private static func cleanup() {
        registrations = registrations.filter {
            $0.value.value != nil && $0.value.window != nil
        }
    }

    private static func isTabEligible(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.tabbingMode != .disallowed
    }
}
