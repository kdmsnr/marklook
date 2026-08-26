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
}
