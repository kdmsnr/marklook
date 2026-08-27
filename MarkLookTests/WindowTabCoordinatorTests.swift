import AppKit
import SwiftUI
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

    func testDraggableTabConfigurationUsesSharedIdentityAndPreferredTabbing() {
        let window = NSWindow()

        WindowTabCoordinator.configureDraggableTabs(for: window)

        XCTAssertEqual(
            window.tabbingIdentifier,
            WindowTabCoordinator.sharedTabbingIdentifier
        )
        XCTAssertEqual(window.tabbingMode, .preferred)
    }

    func testNewTabInheritsCurrentWindowFrame() {
        let parentFrame = NSRect(x: 120, y: 180, width: 1130, height: 780)
        let parent = NSWindow(
            contentRect: parentFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let newTab = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowTabCoordinator.inheritFrame(from: parent, to: newTab)

        XCTAssertEqual(newTab.frame, parent.frame)
    }

    func testCloseTargetIsTheSelectedNativeTab() {
        let firstTab = NSWindow()
        let secondTab = NSWindow()
        firstTab.addTabbedWindow(secondTab, ordered: .above)
        firstTab.tabGroup?.selectedWindow = secondTab

        let target = WindowTabCoordinator.selectedWindowToClose(from: firstTab)

        XCTAssertTrue(target === secondTab)
    }

    func testDocumentIdentityIgnoresFragmentAndDotSegments() {
        let first = ViewerWindowRoute.viewing(
            URL(string: "file:///tmp/folder/../document.md#first")!
        )
        let second = ViewerWindowRoute.viewing(
            URL(string: "file:///tmp/document.md#second")!
        )

        XCTAssertEqual(first?.normalizedIdentity, second?.normalizedIdentity)
        XCTAssertEqual(first?.documentURL?.fragment, "first")
    }

    func testUnsupportedAndRemoteRoutesAreRejected() {
        XCTAssertNil(
            ViewerWindowRoute.viewing(URL(fileURLWithPath: "/tmp/document.txt"))
        )
        XCTAssertNil(
            ViewerWindowRoute.viewing(URL(string: "https://example.com/document.md")!)
        )
    }

    func testDocumentTabUsesTheFileName() {
        let route = ViewerWindowRoute.viewing(
            URL(fileURLWithPath: "/tmp/a folder/README.md#installation")
        )!
        let window = NSWindow()

        WindowTabCoordinator.configureWindowMetadata(for: window, route: route)

        XCTAssertEqual(route.windowTitle, "README.md")
        XCTAssertEqual(window.title, "README.md")
        XCTAssertEqual(window.representedURL?.path, "/tmp/a folder/README.md")
        XCTAssertNil(window.representedURL?.fragment)
    }

    func testSameDocumentIsRequestedOnlyOnceWhileItsWindowIsPending() {
        let route = ViewerWindowRoute.viewing(
            URL(fileURLWithPath: "/tmp/pending-\(UUID().uuidString).md")
        )!
        var requestCount = 0

        let first = WindowTabCoordinator.open(route, asTabOf: nil) {
            requestCount += 1
        }
        let second = WindowTabCoordinator.open(route, asTabOf: nil) {
            requestCount += 1
        }

        XCTAssertEqual(first, .requestedNewWindow)
        XCTAssertEqual(second, .awaitingExistingRequest)
        XCTAssertEqual(requestCount, 1)
    }

    func testWelcomeRouteCanBecomeDocumentWithoutChangingItsWindow() {
        let welcome = ViewerWindowRoute.welcome(UUID())
        let document = ViewerWindowRoute.viewing(
            URL(fileURLWithPath: "/tmp/document.md")
        )!
        var boundRoute = welcome
        let registration = WindowTabRegistrationNSView(
            route: welcome,
            routeBinding: Binding(
                get: { boundRoute },
                set: { boundRoute = $0 }
            )
        )
        let window = NSWindow()
        window.contentView?.addSubview(registration)

        XCTAssertTrue(WindowTabCoordinator.window(for: welcome) === window)
        XCTAssertTrue(WindowTabCoordinator.replaceWelcome(in: window, with: document))
        XCTAssertEqual(boundRoute, document)
        XCTAssertTrue(WindowTabCoordinator.window(for: document) === window)

        registration.removeFromSuperview()
    }
}
