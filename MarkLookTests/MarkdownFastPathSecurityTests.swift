import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class MarkdownFastPathSecurityTests: XCTestCase {
    private let context = RenderContext(
        documentURL: URL(fileURLWithPath: "/tmp/fast-path/document.md"),
        resourceAuthority: "fast-path-session",
        sizeClass: .full
    )

    func testTypedMarkdownRewritesURLsWithoutWholeDocumentHTMLParse() async throws {
        let source = "[web](https://example.com/) [local](next.md) ![image](asset.png)"

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertTrue(output.htmlFragment.contains("https://example.com/"))
        XCTAssertTrue(output.htmlFragment.contains("rel=\"noopener noreferrer\""))
        XCTAssertTrue(output.htmlFragment.contains("mark-navigation://fast-path-session/open?source=next.md"))
        XCTAssertTrue(output.htmlFragment.contains("mark-resource://fast-path-session/open?source=asset.png"))
        XCTAssertEqual(output.resources.map(\.source), ["asset.png"])
        XCTAssertEqual(output.timing.htmlParsing, .zero)
        XCTAssertEqual(output.timing.htmlTransforming, .zero)
        XCTAssertEqual(output.timing.htmlCleaning, .zero)
        XCTAssertEqual(output.timing.htmlSerializing, .zero)
    }

    func testRemoteMarkdownImageIsBlockedOnFastPath() async throws {
        let output = try await GFMRenderEngine().render(
            source: "![tracking](https://tracker.invalid/pixel.png)",
            format: .markdown,
            context: context
        )

        XCTAssertFalse(output.htmlFragment.contains("tracker.invalid"))
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.warnings.contains { $0.message.contains("tracker.invalid") })
        XCTAssertEqual(output.timing.htmlParsing, .zero)
    }

    func testCompleteHTMLCommentsAreDroppedWithoutForcingWholeDocumentSanitization() async throws {
        let output = try await GFMRenderEngine().render(
            source: "# Heading\n\n<!-- build marker -->\n\nParagraph.",
            format: .markdown,
            context: context
        )

        XCTAssertFalse(output.htmlFragment.contains("build marker"))
        XCTAssertEqual(output.timing.htmlParsing, .zero)
        XCTAssertEqual(output.timing.htmlCleaning, .zero)
    }

    func testCommentShapedRawHTMLCannotSmuggleExecutableMarkupOntoFastPath() async throws {
        let source = "<!-- harmless --><script>alert(1)</script><!-- tail -->"

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertFalse(output.htmlFragment.lowercased().contains("<script"))
        XCTAssertFalse(output.htmlFragment.contains("alert(1)"))
        XCTAssertTrue(
            output.timing.htmlParsing != .zero || output.timing.htmlCleaning != .zero,
            "Meaningful raw HTML must retain the maintained sanitizer path."
        )
    }

    func testRawInlineHTMLAcrossMarkdownNodesRetainsWholeDocumentSanitization() async throws {
        let source = "<span onclick=\"alert(1)\">**safe**</span>"

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertTrue(output.htmlFragment.contains("<span>"))
        XCTAssertTrue(output.htmlFragment.contains("<strong>safe</strong>"))
        XCTAssertFalse(output.htmlFragment.contains("onclick"))
        XCTAssertTrue(output.timing.htmlParsing != .zero)
    }

    func testMeaningfulRawHTMLInsideFootnoteForcesWholeDocumentSanitization() async throws {
        let source = """
        Reference[^unsafe].

        [^unsafe]: <span onclick="alert(1)">safe footnote</span><script>attack()</script>
        """

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertTrue(output.htmlFragment.contains("safe footnote"))
        XCTAssertFalse(output.htmlFragment.contains("onclick"))
        XCTAssertFalse(output.htmlFragment.lowercased().contains("<script"))
        XCTAssertFalse(output.htmlFragment.contains("attack()"))
        XCTAssertTrue(output.timing.htmlParsing != .zero)
        XCTAssertTrue(output.timing.htmlCleaning != .zero)
    }
}
