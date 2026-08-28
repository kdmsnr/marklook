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
        lineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks
    ) async throws -> RenderOutput {
        try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: RenderContext(
                documentURL: documentURL,
                resourceAuthority: "markdown-rendering",
                sizeClass: .full,
                markdownLineBreakMode: lineBreakMode
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
