import AppKit
import SwiftUI

/// A zero-sized bridge that registers the SwiftUI-owned window and can update its route in place.
struct WindowTabRegistrationView: NSViewRepresentable {
    @Binding var route: ViewerWindowRoute

    func makeNSView(context _: Context) -> WindowTabRegistrationNSView {
        WindowTabRegistrationNSView(route: route, routeBinding: $route)
    }

    func updateNSView(_ view: WindowTabRegistrationNSView, context _: Context) {
        view.update(route: route, routeBinding: $route)
    }

    static func dismantleNSView(_ view: WindowTabRegistrationNSView, coordinator _: ()) {
        view.unregisterWindowIfAvailable()
    }
}

@MainActor
final class WindowTabRegistrationNSView: NSView {
    private var route: ViewerWindowRoute
    private var routeBinding: Binding<ViewerWindowRoute>

    init(
        route: ViewerWindowRoute,
        routeBinding: Binding<ViewerWindowRoute>
    ) {
        self.route = route
        self.routeBinding = routeBinding
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            unregisterWindowIfAvailable()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        WindowTabCoordinator.register(self, window: window, route: route)
    }

    func update(
        route newRoute: ViewerWindowRoute,
        routeBinding newBinding: Binding<ViewerWindowRoute>
    ) {
        routeBinding = newBinding
        setRoute(newRoute, updateBinding: false)
    }

    func replaceRoute(
        with newRoute: ViewerWindowRoute,
        registeredWindow: NSWindow? = nil
    ) {
        setRoute(
            newRoute,
            updateBinding: true,
            registeredWindow: registeredWindow
        )
    }

    func unregisterWindowIfAvailable() {
        WindowTabCoordinator.unregister(self, route: route)
    }

    private func setRoute(
        _ newRoute: ViewerWindowRoute,
        updateBinding: Bool,
        registeredWindow: NSWindow? = nil
    ) {
        guard route != newRoute else {
            if updateBinding { routeBinding.wrappedValue = newRoute }
            return
        }
        unregisterWindowIfAvailable()
        route = newRoute
        if updateBinding {
            routeBinding.wrappedValue = newRoute
        }
        if let window = registeredWindow ?? window {
            WindowTabCoordinator.register(self, window: window, route: route)
        }
    }
}
