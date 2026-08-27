import AppKit
import SwiftUI

/// A zero-sized AppKit bridge that configures the SwiftUI-owned window as soon as it is attached.
struct WindowTabRegistrationView: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowTabRegistrationNSView {
        WindowTabRegistrationNSView()
    }

    func updateNSView(_ view: WindowTabRegistrationNSView, context _: Context) {
        view.configureWindowIfAvailable()
    }
}

final class WindowTabRegistrationNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfAvailable()
    }

    func configureWindowIfAvailable() {
        guard let window else { return }
        WindowTabCoordinator.configureDraggableTabs(for: window)
    }
}
