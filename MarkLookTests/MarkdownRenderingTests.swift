import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    private let documentURL = URL(fileURLWithPath: "/tmp/markdown-rendering/document.md")

    func testSupportedGFMExtensionsAreParsedByDefault() async throws {
        let source = """
        | Name | State |
        | --- | --- |
        | GFM | ~~draft~~ |

        - [x] Parsed
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("<table>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<del>draft</del>"), output.htmlFragment)
        XCTAssertTrue(
            output.htmlFragment.contains("<input type=\"checkbox\" disabled checked"),
            output.htmlFragment
        )
    }

    func testLeadingYAMLFrontMatterIsExcludedFromRenderedMarkdown() async throws {
        let source = """
        ---
        layout: page
        title: Front Matter Title
        tags:
          - swift
          - markdown
        ---

        # Body Heading

        Body text.
        """

        let output = try await render(source)

        XCTAssertFalse(output.htmlFragment.contains("layout"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("Front Matter Title"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("<hr>"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("<h2"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(">Body Heading</h1>"), output.htmlFragment)
        XCTAssertEqual(output.title, "Body Heading")
    }

    func testFrontMatterCannotTriggerExtensionsResourcesOrSanitization() async throws {
        let source = """
        ---
        script: <script>alert(1)</script>
        image: "![metadata](metadata.png)"
        equation: $metadata$
        reference: [^metadata]
        ---
        Plain body.
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains(">Plain body.</p>"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("metadata"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("<script"), output.htmlFragment)
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.warnings.isEmpty)
        XCTAssertFalse(output.containsMath)
        XCTAssertEqual(output.timing.htmlParsing, .zero)
    }

    func testFrontMatterCanBeShownAsEscapedYAMLAboveTheDocument() async throws {
        let source = """
        ---
        danger: "</code></pre><script>alert(1)</script>"
        image: "![metadata](metadata.png)"
        equation: $metadata$
        reference: [^metadata]
        ---
        # Body Heading
        """

        let output = try await render(source, showsFrontMatter: true)

        XCTAssertTrue(
            output.htmlFragment.contains("<section class=\"front-matter\" aria-label=\"Front Matter\">")
        )
        XCTAssertTrue(output.htmlFragment.contains("<code class=\"language-yaml\">"))
        XCTAssertTrue(
            output.htmlFragment.contains(
                "danger: \"&lt;/code&gt;&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt;\""
            ),
            output.htmlFragment
        )
        XCTAssertTrue(output.htmlFragment.contains("![metadata](metadata.png)"))
        XCTAssertTrue(output.htmlFragment.contains("$metadata$"))
        XCTAssertTrue(output.htmlFragment.contains("[^metadata]"))
        XCTAssertFalse(output.htmlFragment.contains("<script"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("<img"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains(">Body Heading</h1>"), output.htmlFragment)
        XCTAssertEqual(output.title, "Body Heading")
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.warnings.isEmpty)
        XCTAssertFalse(output.containsMath)
        XCTAssertEqual(output.timing.htmlParsing, .zero)
    }

    func testShownFrontMatterSurvivesSanitizationRequiredByTheBody() async throws {
        let source = """
        ---
        title: Metadata
        ---
        <span onclick="alert(1)">Body</span>
        """

        let output = try await render(source, showsFrontMatter: true)

        XCTAssertTrue(output.htmlFragment.contains("aria-label=\"Front Matter\""), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("title: Metadata"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<span>Body</span>"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("onclick"), output.htmlFragment)
        XCTAssertNotEqual(output.timing.htmlParsing, .zero)
    }

    func testGFMLineBreakModeKeepsSoftBreakAndRendersExplicitHardBreak() async throws {
        let source = "soft first\nsoft second\n\nhard first  \nhard second"

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("soft first\nsoft second"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("soft first<br>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("hard first<br>\nhard second"), output.htmlFragment)
    }

    func testPreserveSingleNewlinesModeRendersSoftBreakAsLineBreak() async throws {
        let output = try await render(
            "first\nsecond",
            lineBreakMode: .preserveSingleNewlines
        )

        XCTAssertTrue(output.htmlFragment.contains("first<br>\nsecond"), output.htmlFragment)
    }

    func testPreserveSingleNewlinesDoesNotChangeParagraphsOrCodeBlocks() async throws {
        let source = "first\n\nsecond\n\n```text\ncode first\ncode second\n```"

        let output = try await render(
            source,
            lineBreakMode: .preserveSingleNewlines
        )

        XCTAssertFalse(output.htmlFragment.contains("first<br>"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("second<br>"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("code first\ncode second"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("code first<br>"), output.htmlFragment)
    }

    func testPreserveSingleNewlinesAppliesToFootnotesOnFastPath() async throws {
        let source = "Reference[^note].\n\n[^note]: Footnote first\n    Footnote second"

        let output = try await render(
            source,
            lineBreakMode: .preserveSingleNewlines
        )

        XCTAssertTrue(output.htmlFragment.contains("Footnote first<br>\nFootnote second"), output.htmlFragment)
        XCTAssertEqual(output.timing.htmlParsing, .zero)
    }

    func testPreserveSingleNewlinesAppliesToSanitizedMarkdownAndFootnotes() async throws {
        let source = """
        Main first
        Main second

        <span>safe</span>

        Reference[^note].

        [^note]: Footnote first
            Footnote second
        """

        let output = try await render(
            source,
            lineBreakMode: .preserveSingleNewlines
        )

        XCTAssertTrue(output.htmlFragment.contains("Main first<br"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Footnote first<br"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("<span>safe</span>"), output.htmlFragment)
        XCTAssertNotEqual(output.timing.htmlParsing, .zero)
    }

    func testExtensionsStayLiteralInsideLongFencedCodeBlock() async throws {
        let source = """
        ````text
        ```
        $not-math$ [^note]
        ````

        [^note]: Footnote
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("$not-math$ [^note]"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("marklook-math"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("footnote-ref"), output.htmlFragment)
    }

    func testExtensionsStayLiteralInsideMultilineCodeSpan() async throws {
        let source = """
        `code starts
        $not-math$ [^note]`

        [^note]: Footnote
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("$not-math$ [^note]"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("marklook-math"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.contains("footnote-ref"), output.htmlFragment)
    }

    func testCodeSpanCannotCrossFromATXHeadingIntoFollowingParagraph() async throws {
        let source = """
        # `heading
        Paragraph $x$ and [^note]`
        [^note]: Footnote body
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("marklook-math"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("footnote-ref"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Footnote body"), output.htmlFragment)
    }

    func testFootnoteDefinitionCannotClosePreviousParagraphCodeSpan() async throws {
        let source = """
        `literal
        [^note]: Footnote body`
        Reference [^note].
        """

        let output = try await render(source)

        XCTAssertTrue(output.htmlFragment.contains("footnote-ref"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("Footnote body"), output.htmlFragment)
    }

    func testOrderedMarkerAboveOneKeepsValidParagraphCodeSpan() async throws {
        let source = """
        Paragraph `code
        2. $not-math$`
        """

        let output = try await render(source)

        XCTAssertFalse(output.htmlFragment.contains("marklook-math"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("$not-math$"), output.htmlFragment)
    }

    func testRepeatedFootnoteReferenceIDsFollowSourceOrder() async throws {
        let source = "First[^note] then second[^note].\n\n[^note]: Footnote"

        for _ in 0..<32 {
            let output = try await render(source)
            let first = try XCTUnwrap(output.htmlFragment.range(of: "id=\"fnref-note\""))
            let second = try XCTUnwrap(output.htmlFragment.range(of: "id=\"fnref-note-2\""))
            XCTAssertLessThan(first.lowerBound, second.lowerBound, output.htmlFragment)
            XCTAssertTrue(
                output.htmlFragment.contains("class=\"footnote-backref\" href=\"#fnref-note\""),
                output.htmlFragment
            )
        }
    }

    func testDistinctFootnoteLabelsCannotProduceDuplicateDOMIDs() async throws {
        let source = "First[^a!] and second[^a?].\n\n[^a!]: One\n[^a?]: Two"

        let output = try await render(source)
        let footnoteIDs = try captures(
            pattern: "<li id=\"(fn-[^\"]+)\"",
            in: output.htmlFragment
        )
        let linkTargets = try captures(
            pattern: "href=\"#(fn-[^\"]+)\"",
            in: output.htmlFragment
        )

        XCTAssertEqual(footnoteIDs.count, 2, output.htmlFragment)
        XCTAssertEqual(Set(footnoteIDs).count, 2, output.htmlFragment)
        XCTAssertTrue(Set(footnoteIDs).isSubset(of: Set(linkTargets)), output.htmlFragment)
    }

    private func render(
        _ source: String,
        lineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks,
        showsFrontMatter: Bool = false
    ) async throws -> RenderOutput {
        try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: RenderContext(
                documentURL: documentURL,
                resourceAuthority: "markdown-rendering",
                sizeClass: .full,
                markdownLineBreakMode: lineBreakMode,
                showsFrontMatter: showsFrontMatter
            )
        )
    }

    private func captures(pattern: String, in source: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }
}
