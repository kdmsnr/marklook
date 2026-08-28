import XCTest

final class MarkLookScaffoldUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeWindowShowsOpenAndDropEntryPoints() {
        let application = launchApplication()

        XCTAssertTrue(application.groups["welcome.dropZone"].waitForExistence(timeout: 5))
        XCTAssertTrue(application.buttons["welcome.open"].exists)
        XCTAssertTrue(application.staticTexts["Open a Markdown or HTML file"].exists)
        XCTAssertTrue(application.staticTexts["Drop a file here, or choose one from your Mac."].exists)
    }

    @MainActor
    func testDeterministicFixtureOpensInDocumentViewer() throws {
        let application = launchApplication(scenario: "open")

        XCTAssertTrue(application.descendants(matching: .any)["viewer.webView"].waitForExistence(timeout: 8))
        XCTAssertTrue(application.staticTexts["Open fixture ready"].waitForExistence(timeout: 8))
        XCTAssertTrue(application.staticTexts["Ready"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.groups["welcome.dropZone"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testAtomicSaveReloadsRenderedContent() throws {
        let application = launchApplication(scenario: "reload")
        let initialMarker = application.staticTexts["Reload version one"]
        XCTAssertTrue(initialMarker.waitForExistence(timeout: 8))

        let updateButton = application.buttons["uitest.atomicReload"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 3))
        updateButton.click()

        XCTAssertTrue(application.staticTexts["Reload version two"].waitForExistence(timeout: 8))
        XCTAssertFalse(initialMarker.exists)
        XCTAssertTrue(application.descendants(matching: .any)["viewer.webView"].exists)
    }

    @MainActor
    func testNewTabMenuCreatesAStandardWindowTab() {
        let application = launchApplication()
        XCTAssertTrue(application.buttons["welcome.open"].waitForExistence(timeout: 5))

        application.menuBars.menuBarItems["File"].click()
        let newTabItem = application.menuItems["New Tab"]
        XCTAssertTrue(newTabItem.waitForExistence(timeout: 3))
        newTabItem.click()

        let tabGroup = application.tabGroups.firstMatch
        XCTAssertTrue(tabGroup.waitForExistence(timeout: 5))
        XCTAssertEqual(tabGroup.tabs.count, 2)
    }

    @MainActor
    func testPDFExportMenuIsDisabledWithoutAReadyDocument() {
        let application = launchApplication()
        XCTAssertTrue(application.buttons["welcome.open"].waitForExistence(timeout: 5))

        application.menuBars.menuBarItems["File"].click()
        let exportItem = application.menuItems["Export as PDF…"]

        XCTAssertTrue(exportItem.waitForExistence(timeout: 3))
        XCTAssertFalse(exportItem.isEnabled)
    }

    @MainActor
    func testPDFExportMenuIsEnabledForAReadyDocument() {
        let application = launchApplication(scenario: "open")
        XCTAssertTrue(application.staticTexts["Ready"].waitForExistence(timeout: 8))

        application.menuBars.menuBarItems["File"].click()
        let exportItem = application.menuItems["Export as PDF…"]

        XCTAssertTrue(exportItem.waitForExistence(timeout: 3))
        XCTAssertTrue(exportItem.isEnabled)
    }

    @MainActor
    func testPDFExportPanelUsesSourceNameAndCanBeCancelled() {
        let application = launchApplication(scenario: "open")
        XCTAssertTrue(application.staticTexts["Ready"].waitForExistence(timeout: 8))

        application.menuBars.menuBarItems["File"].click()
        let exportItem = application.menuItems["Export as PDF…"]
        XCTAssertTrue(exportItem.waitForExistence(timeout: 3))
        exportItem.click()

        let panel = application.sheets["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        let cancelButton = panel.buttons["CancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))

        let nameField = panel.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertEqual(nameField.value as? String, "open-fixture.pdf")

        cancelButton.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testScrollPositionSurvivesAtomicReload() throws {
        let application = launchApplication(scenario: "scroll")
        XCTAssertTrue(application.staticTexts["Scroll fixture version one"].waitForExistence(timeout: 8))

        let webView = application.descendants(matching: .any)["viewer.webView"]
        let anchor = application.staticTexts["Section 24"].firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        for _ in 0 ..< 20 where !isVisible(anchor, in: webView) {
            webView.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(isVisible(anchor, in: webView))
        let originalY = anchor.frame.minY

        application.buttons["uitest.atomicReload"].click()
        XCTAssertTrue(application.staticTexts["Scroll fixture version two"].waitForExistence(timeout: 8))

        let restoredY = anchor.frame.minY
        XCTAssertLessThanOrEqual(abs(restoredY - originalY), 4)
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        let frame = element.frame
        return !frame.isEmpty && frame.intersects(container.frame)
    }

    @MainActor
    func testDocumentWindowRestoresAfterRelaunch() {
        let fixtureID = UUID().uuidString
        let application = configuredApplication(
            scenario: "open",
            fixtureID: fixtureID,
            ignoresPersistentState: false,
            keepsWindowsOnQuit: true
        )
        application.launch()
        XCTAssertTrue(application.windows["open-fixture.md"].waitForExistence(timeout: 8))

        application.terminate()
        XCTAssertTrue(application.wait(for: .notRunning, timeout: 8))

        application.launchEnvironment.removeValue(forKey: "UITEST_SCENARIO")
        application.launchArguments = [
            "-ApplePersistenceIgnoreState", "NO",
            "-NSQuitAlwaysKeepsWindows", "YES",
        ]
        application.launch()

        XCTAssertTrue(application.windows["open-fixture.md"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func launchApplication(scenario: String? = nil) -> XCUIApplication {
        let application = configuredApplication(
            scenario: scenario,
            fixtureID: UUID().uuidString,
            ignoresPersistentState: true,
            keepsWindowsOnQuit: false
        )
        application.launch()
        XCTAssertTrue(application.wait(for: .runningForeground, timeout: 5))
        return application
    }

    @MainActor
    private func configuredApplication(
        scenario: String?,
        fixtureID: String,
        ignoresPersistentState: Bool,
        keepsWindowsOnQuit: Bool
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["UITEST_MODE"] = "1"
        application.launchEnvironment["UITEST_FIXTURE_ID"] = fixtureID
        if let scenario {
            application.launchEnvironment["UITEST_SCENARIO"] = scenario
        }
        application.launchArguments = [
            "-ApplePersistenceIgnoreState", ignoresPersistentState ? "YES" : "NO",
            "-NSQuitAlwaysKeepsWindows", keepsWindowsOnQuit ? "YES" : "NO",
        ]
        return application
    }

}
