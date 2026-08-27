import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class CalloutRenderingTests: XCTestCase {
    private let documentURL = URL(fileURLWithPath: "/tmp/callout-rendering/document.md")

    func testBasicCalloutUsesDefaultTitleAndFastPath() async throws {
        let output = try await render("> [!note]\n> Body text")

        XCTAssertTrue(output.htmlFragment.contains("<div class=\"callout\" data-callout=\"note\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("role=\"note\" aria-labelledby=\"callout-"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("-title\" class=\"callout-title\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<span class=\"callout-title-inner\">Note</span>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<div class=\"callout-content\">"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Body text"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("[!note]"), output.htmlFragment)
        XCTAssertEqual(output.timing.htmlParsing, .zero)
    }

    func testCustomTitleKeepsInlineMarkdownAndRewritesLinks() async throws {
        let output = try await render("> [!tip] **Read** [next](next.md)\n> Details")

        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"tip\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<strong>Read</strong>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("mark-navigation://callout-rendering/open?source=next.md"), output.htmlFragment)
    }

    func testFoldableCalloutsUseNativeDetailsState() async throws {
        let expanded = try await render("> [!faq]+ Expanded\n> Answer")
        let collapsed = try await render("> [!warning]- Collapsed\n> Warning")
        let staticCallout = try await render("> [!info] Static\n> Information")

        XCTAssertTrue(expanded.htmlFragment.contains("<details class=\"callout\" data-callout=\"faq\""), expanded.htmlFragment)
        XCTAssertTrue(expanded.htmlFragment.contains(" open>"), expanded.htmlFragment)
        XCTAssertTrue(expanded.htmlFragment.contains("<summary class=\"callout-title\">"), expanded.htmlFragment)
        XCTAssertTrue(collapsed.htmlFragment.contains("<details class=\"callout\" data-callout=\"warning\""), collapsed.htmlFragment)
        XCTAssertFalse(collapsed.htmlFragment.contains(" open>"), collapsed.htmlFragment)
        XCTAssertFalse(staticCallout.htmlFragment.contains("<details"), staticCallout.htmlFragment)
    }

    func testMarkerLineBreakIsConsumedBeforeApplyingUserLineBreakPreference() async throws {
        let source = "> [!note] Title\n> First line\n> Second line"

        let gfm = try await render(source)
        let preservingNewlines = try await render(
            source,
            lineBreakMode: .preserveSingleNewlines
        )

        XCTAssertFalse(gfm.htmlFragment.contains("Title<br>"), gfm.htmlFragment)
        XCTAssertFalse(preservingNewlines.htmlFragment.contains("Title<br>"), preservingNewlines.htmlFragment)
        XCTAssertTrue(
            preservingNewlines.htmlFragment.contains("First line<br>\nSecond line"),
            preservingNewlines.htmlFragment
        )
    }

    func testHardBreakAfterMarkerAndBlockBodyAreSupported() async throws {
        let source = """
        > [!example] Blocks\u{20}\u{20}
        > Intro
        >
        > - One
        > - Two
        >
        > ```swift
        > let value = 1
        > ```
        """

        let output = try await render(source)

        XCTAssertFalse(output.htmlFragment.contains("Blocks<br>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<ul>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("class=\"language-swift\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("let value = 1"), output.htmlFragment)
    }

    func testNestedAndTitleOnlyCalloutsAreSupported() async throws {
        let source = """
        > [!note] Outer
        > > [!success] Inner
        > > Nested body

        > [!todo]
        """

        let output = try await render(source)

        XCTAssertEqual(output.htmlFragment.components(separatedBy: "class=\"callout\"").count - 1, 3, output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"success\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<span class=\"callout-title-inner\">Todo</span>"), output.htmlFragment)
    }

    func testTypesAreCaseInsensitiveAndUnknownTypesFallBackToBaseStyling() async throws {
        let output = try await render("> [!WARNING] Case\n\n> [!custom-type]")

        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"warning\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"custom-type\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<span class=\"callout-title-inner\">Custom Type</span>"), output.htmlFragment)
    }

    func testTitlesDoNotRequireWhitespaceAfterTheMarker() async throws {
        let output = try await render("> [!note]Title without separator\n> Body")

        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"note\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(">Title without separator</span>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Body"), output.htmlFragment)
    }

    func testEscapedAndEncodedFoldCharactersRemainPartOfStaticTitles() async throws {
        let source = #"""
        > [!note]\+ Literal plus

        > [!tip]&#45; Entity minus
        """#

        let output = try await render(source)

        XCTAssertEqual(output.htmlFragment.components(separatedBy: "class=\"callout\"").count - 1, 2, output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("<details"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(">+ Literal plus</span>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(">- Entity minus</span>"), output.htmlFragment)
    }

    func testMultilineInlineContainersCannotSwallowCalloutBodyIntoTitle() async throws {
        let source = """
        > [!note] *Title
        > Body*

        > [!tip] `Code
        > Body`
        """

        let output = try await render(source)

        XCTAssertEqual(output.htmlFragment.components(separatedBy: "<blockquote>").count - 1, 2, output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("class=\"callout\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Body"), output.htmlFragment)
    }

    func testMalformedMarkersAndCodeFencesRemainOrdinaryMarkdown() async throws {
        let source = """
        > Prefix [!tip] Mid-line marker

        > [!note\" onmouseover=\"alert] Invalid type

        ```markdown
        > [!danger] Not a callout
        ```
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("<blockquote>"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("class=\"callout\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("&gt; [!danger] Not a callout"), output.htmlFragment)
    }

    func testCalloutsSurviveMathAndFootnotePreprocessing() async throws {
        let source = """
        > [!info] Formula $x$
        > Main body

        Reference[^note].

        [^note]: > [!tip] Footnote callout
            > Footnote body
        """

        let output = try await render(source)

        XCTAssertEqual(output.htmlFragment.components(separatedBy: "class=\"callout\"").count - 1, 2, output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"info\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("data-marklook-math=\"true\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"tip\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Footnote body"), output.htmlFragment)
    }

    func testEscapedAndEntityEncodedMarkersRemainOrdinaryBlockQuotes() async throws {
        let source = #"""
        > \[!note] Escaped bracket

        > [\!tip] Escaped bang

        > &#91;!warning] Encoded bracket

        > [!danger\] Escaped close

        > [!n&#111;te] Encoded type
        """#

        let output = try await render(source)

        XCTAssertEqual(output.htmlFragment.components(separatedBy: "<blockquote>").count - 1, 5, output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("class=\"callout\""), output.htmlFragment)
    }

    func testFullSanitizationPreservesCalloutMetadataAndBlocksInjection() async throws {
        let source = """
        > [!danger]+ **Unsafe?**
        > Safe body

        > [!note] Static callout
        > Static body

        <img src="local.png" onerror="alert(1)">
        <script>alert(2)</script>
        """

        let output = try await render(source)
        let lowercased = output.htmlFragment.lowercased()

        XCTAssertNotEqual(output.timing.htmlParsing, .zero)
        XCTAssertTrue(output.htmlFragment.contains("data-callout=\"danger\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<details"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(" open"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<div class=\"callout\" data-callout=\"note\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("role=\"note\""), output.htmlFragment)
        XCTAssertFalse(lowercased.contains("onerror"), output.htmlFragment)
        XCTAssertFalse(lowercased.contains("<script"), output.htmlFragment)
    }

    private func render(
        _ source: String,
        lineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks
    ) async throws -> RenderOutput {
        try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: RenderContext(
                documentURL: documentURL,
                resourceAuthority: "callout-rendering",
                sizeClass: .full,
                markdownLineBreakMode: lineBreakMode
            )
        )
    }
}
