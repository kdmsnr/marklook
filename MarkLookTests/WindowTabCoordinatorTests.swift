import AppKit
@testable import MarkLook
import XCTest

@MainActor
final class WindowTabCoordinatorTests: XCTestCase {
    func testOpenPanelIsNotSelectedAsTabParent() {
        let documentWindow = NSWindow()
        let openPanel = NSOpenPanel()

        let parent = WindowTabCoordinator.preferredParentWindow(
            keyWindow: openPanel,
            mainWindow: documentWindow,
            orderedWindows: [openPanel, documentWindow]
        )

        XCTAssertTrue(parent === documentWindow)
    }

    func testDisallowedUtilityWindowIsNotSelectedAsTabParent() {
        let documentWindow = NSWindow()
        let utilityWindow = NSWindow()
        utilityWindow.tabbingMode = .disallowed

        let parent = WindowTabCoordinator.preferredParentWindow(
            keyWindow: utilityWindow,
            mainWindow: documentWindow,
            orderedWindows: [utilityWindow, documentWindow]
        )

        XCTAssertTrue(parent === documentWindow)
    }

    func testDraggableTabConfigurationUsesSharedIdentity() {
        let window = NSWindow()

        WindowTabCoordinator.configureDraggableTabs(for: window)

        XCTAssertEqual(
            window.tabbingIdentifier,
            WindowTabCoordinator.sharedTabbingIdentifier
        )
        XCTAssertEqual(window.tabbingMode, .preferred)
    }
}
