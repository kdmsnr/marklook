import Foundation
@testable import MarkLook
import XCTest

@MainActor
final class RecentDocumentsTests: XCTestCase {
    func testRecentFilesSurviveAServiceRelaunch() {
        withDefaults { defaults in
            let first = RecentDocuments(defaults: defaults)
            let alpha = fileURL("alpha.md")
            let beta = fileURL("beta.html")

            first.note(alpha)
            first.note(beta)

            let relaunched = RecentDocuments(defaults: defaults)
            XCTAssertEqual(relaunched.urls, [beta, alpha])
        }
    }

    func testActivationMergesAndRepopulatesTheSystemList() {
        withDefaults { defaults in
            let persisted = fileURL("persisted.md")
            RecentDocuments(defaults: defaults).note(persisted)

            let system = fileURL("system.html")
            let controller = RecentDocumentControllerSpy(urls: [system])
            let recentDocuments = RecentDocuments(defaults: defaults)

            recentDocuments.activate(documentController: controller)

            XCTAssertEqual(recentDocuments.urls, [system, persisted])
            XCTAssertEqual(controller.recentDocumentURLs, [system, persisted])
        }
    }

    func testClearRemovesTheAppAndSystemLists() {
        withDefaults { defaults in
            let controller = RecentDocumentControllerSpy()
            let recentDocuments = RecentDocuments(
                documentController: controller,
                defaults: defaults
            )
            recentDocuments.note(fileURL("document.md"))

            recentDocuments.clear()

            XCTAssertTrue(recentDocuments.urls.isEmpty)
            XCTAssertTrue(controller.recentDocumentURLs.isEmpty)
            XCTAssertEqual(controller.clearCount, 1)
            XCTAssertTrue(RecentDocuments(defaults: defaults).urls.isEmpty)
        }
    }

    func testRecentFilesAreDeduplicatedAndBounded() {
        withDefaults { defaults in
            let recentDocuments = RecentDocuments(
                defaults: defaults,
                maximumCount: 2
            )
            let alpha = fileURL("alpha.md")
            let beta = fileURL("beta.md")
            let gamma = fileURL("gamma.md")

            recentDocuments.note(alpha)
            recentDocuments.note(beta)
            recentDocuments.note(alpha)
            recentDocuments.note(gamma)

            XCTAssertEqual(recentDocuments.urls, [gamma, alpha])
        }
    }

    func testUnsupportedFilesAreNotPersisted() {
        withDefaults { defaults in
            let recentDocuments = RecentDocuments(defaults: defaults)

            recentDocuments.note(fileURL("notes.txt"))

            XCTAssertTrue(recentDocuments.urls.isEmpty)
            XCTAssertTrue(RecentDocuments(defaults: defaults).urls.isEmpty)
        }
    }

    func testRemoteFilesAreNotAddedToEitherList() {
        withDefaults { defaults in
            let controller = RecentDocumentControllerSpy()
            let recentDocuments = RecentDocuments(
                documentController: controller,
                defaults: defaults
            )

            recentDocuments.note(URL(string: "https://example.com/notes.md")!)

            XCTAssertTrue(recentDocuments.urls.isEmpty)
            XCTAssertTrue(controller.recentDocumentURLs.isEmpty)
        }
    }

    func testClearBeforeActivationClearsBothLists() {
        withDefaults { defaults in
            let recentDocuments = RecentDocuments(defaults: defaults)
            recentDocuments.note(fileURL("persisted.md"))
            recentDocuments.clear()

            let controller = RecentDocumentControllerSpy(urls: [fileURL("system.md")])
            recentDocuments.activate(documentController: controller)

            XCTAssertTrue(recentDocuments.urls.isEmpty)
            XCTAssertTrue(controller.recentDocumentURLs.isEmpty)
            XCTAssertEqual(controller.clearCount, 1)
        }
    }

    func testMovedFileReplacesItsPreviousLocation() {
        withDefaults { defaults in
            let oldURL = fileURL("old/document.md")
            let newURL = fileURL("new/document.md")
            let otherURL = fileURL("other.html")
            let controller = RecentDocumentControllerSpy(urls: [oldURL, otherURL])
            let recentDocuments = RecentDocuments(
                documentController: controller,
                defaults: defaults
            )

            recentDocuments.note(newURL, replacing: oldURL)

            XCTAssertEqual(recentDocuments.urls, [newURL, otherURL])
            XCTAssertEqual(controller.recentDocumentURLs, [newURL, otherURL])
            XCTAssertEqual(controller.clearCount, 1)
        }
    }

    func testClearingRecentFilesDoesNotRemoveBookmarks() {
        withDefaults { defaults in
            let bookmarkKey = "SecurityScopedBookmarks.v1"
            let bookmarkData = Data([0x01, 0x02, 0x03])
            defaults.set(bookmarkData, forKey: bookmarkKey)
            let recentDocuments = RecentDocuments(defaults: defaults)
            recentDocuments.note(fileURL("document.md"))

            recentDocuments.clear()

            XCTAssertEqual(defaults.data(forKey: bookmarkKey), bookmarkData)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "RecentDocumentsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/marklook-recent-tests/\(name)").standardizedFileURL
    }
}

@MainActor
private final class RecentDocumentControllerSpy: RecentDocumentControlling {
    private(set) var recentDocumentURLs: [URL]
    private(set) var clearCount = 0

    init(urls: [URL] = []) {
        recentDocumentURLs = urls
    }

    func noteNewRecentDocumentURL(_ url: URL) {
        recentDocumentURLs.removeAll(where: { $0.standardizedFileURL.path == url.path })
        recentDocumentURLs.insert(url.standardizedFileURL, at: 0)
    }

    func clearRecentDocuments(_: Any?) {
        clearCount += 1
        recentDocumentURLs.removeAll()
    }
}
