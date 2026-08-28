import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class DocumentSessionNavigationTests: XCTestCase {
    func testNavigationRestoresZoomForEachDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLookSessionNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try Data("# First".utf8).write(to: firstURL)
        try Data("# Second".utf8).write(to: secondURL)

        let suiteName = "DocumentSessionNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = DocumentSession(
            documentURL: firstURL,
            renderer: EmptyRenderEngine(),
            bookmarkStore: BookmarkStore(defaults: defaults),
            recentDocuments: RecentDocuments(
                defaults: defaults,
                storageKey: "recent"
            )
        )

        session.zoomIn()
        XCTAssertEqual(session.zoom, 1.1, accuracy: 0.0001)

        session.openRoutedFile(secondURL)
        XCTAssertEqual(session.currentURL.path, secondURL.path)
        XCTAssertEqual(session.zoom, 1, accuracy: 0.0001)

        session.zoomOut()
        XCTAssertEqual(session.zoom, 0.9, accuracy: 0.0001)

        session.goBack()
        XCTAssertEqual(session.currentURL.path, firstURL.path)
        XCTAssertEqual(session.zoom, 1.1, accuracy: 0.0001)

        session.goForward()
        XCTAssertEqual(session.currentURL.path, secondURL.path)
        XCTAssertEqual(session.zoom, 0.9, accuracy: 0.0001)
    }

    func testDocumentUpdatePolicyPreservesScrollOnlyForTheSameDocumentLocation() {
        let first = URL(string: "file:///tmp/document.md#first")!
        let secondFragment = URL(string: "file:///tmp/document.md#second")!
        let withoutFragment = URL(fileURLWithPath: "/tmp/document.md")
        let other = URL(fileURLWithPath: "/tmp/other.md")

        XCTAssertTrue(DocumentUpdatePolicy.preservesScroll(
            displayedURL: first,
            currentURL: first
        ))
        XCTAssertFalse(DocumentUpdatePolicy.preservesScroll(
            displayedURL: first,
            currentURL: secondFragment
        ))
        XCTAssertFalse(DocumentUpdatePolicy.preservesScroll(
            displayedURL: first,
            currentURL: withoutFragment
        ))
        XCTAssertFalse(DocumentUpdatePolicy.preservesScroll(
            displayedURL: first,
            currentURL: other
        ))
        XCTAssertFalse(DocumentUpdatePolicy.preservesScroll(
            displayedURL: nil,
            currentURL: first
        ))
        XCTAssertNil(DocumentUpdatePolicy.explicitAnchor(
            for: first,
            preservingScroll: true
        ))
        XCTAssertEqual(
            DocumentUpdatePolicy.explicitAnchor(
                for: secondFragment,
                preservingScroll: false
            ),
            "second"
        )
    }

    func testUnchangedReloadClearsTransientIssueButKeepsOtherIssues() {
        let monitoring = ViewerIssue(
            kind: .permission,
            title: "Automatic Reload Unavailable",
            message: "Folder access is required."
        )
        let resourcePermission = ViewerIssue(
            kind: .permission,
            title: "Local Resources Need Access",
            message: "Grant folder access."
        )
        let moved = ViewerIssue(
            kind: .moved,
            title: "File Not Found",
            message: "The file was temporarily unavailable."
        )
        let rendering = ViewerIssue(
            kind: .rendering,
            title: "Display Error",
            message: "The WebView rejected the update."
        )

        XCTAssertNil(DocumentUpdatePolicy.issueAfterUnchangedReload(
            currentIssue: moved,
            monitoringIssue: nil
        ))
        XCTAssertEqual(
            DocumentUpdatePolicy.issueAfterUnchangedReload(
                currentIssue: moved,
                monitoringIssue: monitoring
            ),
            monitoring
        )
        XCTAssertEqual(
            DocumentUpdatePolicy.issueAfterUnchangedReload(
                currentIssue: resourcePermission,
                monitoringIssue: nil
            ),
            resourcePermission
        )
        XCTAssertEqual(
            DocumentUpdatePolicy.issueAfterUnchangedReload(
                currentIssue: rendering,
                monitoringIssue: nil
            ),
            rendering
        )
    }

    func testRelocateReplacesMissingHistoryAndRecentEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLookSessionRelocate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.md")
        let missingURL = root.appendingPathComponent("missing.md")
        let relocatedURL = root.appendingPathComponent("relocated.md")
        for url in [firstURL, missingURL, relocatedURL] {
            try Data("# \(url.deletingPathExtension().lastPathComponent)".utf8).write(to: url)
        }

        let suiteName = "DocumentSessionRelocateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recents = RecentDocuments(defaults: defaults, storageKey: "recent")
        let session = DocumentSession(
            documentURL: firstURL,
            renderer: EmptyRenderEngine(),
            bookmarkStore: BookmarkStore(defaults: defaults),
            recentDocuments: recents
        )

        session.openRoutedFile(missingURL)
        session.relocateFile(to: relocatedURL, replacing: missingURL)

        XCTAssertEqual(session.currentURL.path, relocatedURL.path)
        XCTAssertFalse(recents.urls.contains(where: { $0.path == missingURL.path }))
        XCTAssertTrue(recents.urls.contains(where: { $0.path == relocatedURL.path }))

        session.goBack()
        XCTAssertEqual(session.currentURL.path, firstURL.path)
    }

}

private struct EmptyRenderEngine: RenderEngine {
    func render(
        source _: String,
        format _: DocumentFormat,
        context _: RenderContext
    ) async throws -> RenderOutput {
        RenderOutput(
            htmlFragment: "",
            title: nil,
            resources: [],
            warnings: [],
            containsMath: false,
            sizeClass: .full,
            timing: RenderPipelineTiming(
                preprocessing: .zero,
                markdownParsing: .zero,
                markdownFormatting: .zero,
                extensionPostprocessing: .zero,
                htmlParsing: .zero,
                htmlTransforming: .zero,
                htmlCleaning: .zero,
                htmlSerializing: .zero
            )
        )
    }
}
