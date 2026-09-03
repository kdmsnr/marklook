import XCTest
@testable import MarkLook

final class MarkupPreprocessorTests: XCTestCase {
    private let preprocessor = MarkupPreprocessor()

    func testFeaturelessMarkdownIsPreservedExactly() {
        let source = "# Heading\n\nParagraph with `code` and [a link](next.md).\n\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertNil(result.frontMatter)
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testFeaturelessMarkdownStillNormalizesCarriageReturns() {
        let result = preprocessor.process("first\r\nsecond\rthird")

        XCTAssertEqual(result.source, "first\nsecond\nthird")
    }

    func testFeaturelessNonASCIIMarkdownIsPreservedExactly() {
        let source = "# 見出し 👩🏽‍💻\n\ncafé と日本語、全角＄、全角［＾をそのまま表示。\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testLeadingYAMLFrontMatterIsRemovedBeforeMarkdownParsing() {
        let source = "---\nlayout: page\ntitle: Document title\ntags:\n  - swift\n---\n\n# Body\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, "\n# Body\n")
        XCTAssertEqual(
            result.frontMatter,
            "layout: page\ntitle: Document title\ntags:\n  - swift"
        )
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testFrontMatterSupportsCRLFAndYAMLDocumentEndMarker() {
        let source = "---\r\ntitle: Document title\r\n...\r\nBody\r\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, "Body\n")
        XCTAssertEqual(result.frontMatter, "title: Document title")
    }

    func testEmptyFrontMatterAndWhitespaceAfterDelimitersAreSupported() {
        let cases: [(source: String, body: String, frontMatter: String)] = [
            ("---\n---\nBody", "Body", ""),
            ("\u{FEFF}--- \t\ntitle: Ignored\n...\t\nBody", "Body", "title: Ignored"),
            ("---\n---", "", ""),
        ]

        for testCase in cases {
            let result = preprocessor.process(testCase.source)
            XCTAssertEqual(result.source, testCase.body)
            XCTAssertEqual(result.frontMatter, testCase.frontMatter)
        }
    }

    func testFrontMatterExtensionsAreIgnoredButBodyExtensionsStillWork() {
        let source = """
        ---
        equation: $metadata$
        reference: [^hidden]
        [^hidden]: Hidden metadata note
        ---
        Body $visible$[^shown].

        [^shown]: Shown body note
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.math.map(\.source), ["visible"])
        XCTAssertEqual(result.footnotes.map(\.id), ["shown"])
        XCTAssertEqual(result.footnotes.map(\.source), ["Shown body note"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["shown"])
        XCTAssertNotNil(result.frontMatter)
        XCTAssertFalse(result.source.contains("metadata"), result.source)
        XCTAssertFalse(result.source.contains("hidden"), result.source)
    }

    func testIndentedDelimiterInsideFrontMatterDoesNotCloseIt() {
        let source = "---\ndescription: |\n  ---\n  retained as YAML\n---\nBody"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, "Body")
    }

    func testUnterminatedFrontMatterCandidateRemainsMarkdown() {
        let source = "---\ntitle: Not front matter\n# Body"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertNil(result.frontMatter)
    }

    func testFrontMatterSyntaxAwayFromDocumentStartRemainsMarkdown() {
        let source = "# Start\n\n---\ntitle: Ordinary Markdown\n---\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertNil(result.frontMatter)
    }

    func testSimilarOpeningDelimiterRemainsMarkdown() {
        let cases = [
            "----\ntitle: Four dashes\n---",
            " ---\ntitle: Indented\n---",
        ]

        for source in cases {
            XCTAssertEqual(preprocessor.process(source).source, source)
        }
    }

    func testASCIIMathMarkerAfterMultibyteTextIsDetected() {
        let result = preprocessor.process("日本語と絵文字🧮の後に $α + β$ を表示")

        XCTAssertEqual(result.math.map(\.source), ["α + β"])
        XCTAssertEqual(result.math.map(\.display), [false])
        XCTAssertFalse(result.source.contains("$α + β$"))
    }

    func testASCIIFootnoteMarkerAfterMultibyteTextIsDetected() {
        let source = "本文🙂[^注]\n\n[^注]: 日本語の脚注"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.footnotes.map(\.id), ["注"])
        XCTAssertEqual(result.footnotes.map(\.source), ["日本語の脚注"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["注"])
    }

    func testMultibyteScalarBetweenBracketAndCaretIsNotAFootnoteMarker() {
        let source = "本文 [é^note] と [🙂^note] は脚注ではない"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testCarriageReturnsAndExtensionsAreDetectedInSameUTF8Scan() {
        let result = preprocessor.process("前置き\r\n数式 $x$\r後続")

        XCTAssertFalse(result.source.contains("\r"))
        XCTAssertEqual(result.math.map(\.source), ["x"])
    }

    func testMathAndFootnotesAreExtractedOutsideCodeFences() throws {
        let source = """
        Inline $x + y$ and a reference[^note].

        $$
        z = 2
        $$

        ```text
        $not-math$ [^note]
        ```

        [^note]: Footnote body
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.math.map(\.source), ["x + y", "\nz = 2\n"])
        XCTAssertEqual(result.math.map(\.display), [false, true])
        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertEqual(result.footnotes.map(\.source), ["Footnote body"])
        XCTAssertTrue(result.source.contains("$not-math$ [^note]"))
        XCTAssertFalse(result.source.contains("Inline $x + y$"))
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["note"])
    }

    func testShorterFenceInsideLongFenceDoesNotExposeExtensions() {
        let source = """
        ````text
        ```
        $not-math$ [^note]
        [^note]: not a definition
        ````
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testExtensionsInsideMultilineCodeSpanRemainLiteral() {
        let source = """
        `code starts
        $not-math$ [^note]`

        [^note]: Real footnote
        """

        let result = preprocessor.process(source)

        XCTAssertTrue(result.source.contains("$not-math$ [^note]"), result.source)
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertTrue(result.footnoteReferences.isEmpty)
    }

    func testUnmatchedBacktickRunDoesNotSuppressExtensionsOnFollowingLines() {
        let source = """
        `unclosed literal
        Inline $x$ and [^note].
        [^note]: Footnote body
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.math.map(\.source), ["x"])
        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertEqual(result.footnotes.map(\.source), ["Footnote body"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["note"])
        XCTAssertTrue(result.source.hasPrefix("`unclosed literal\n"), result.source)
    }

    func testDifferentLengthBacktickRunDoesNotCloseOrValidateAnOpener() {
        let source = """
        `unclosed literal
        ``also literal`` Inline $x$ and [^note].
        [^note]: Footnote body
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.math.map(\.source), ["x"])
        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["note"])
    }

    func testCodeSpansDoNotCrossRepresentativeCommonMarkBlockBoundaries() {
        let cases = [
            ("ATX heading", "# `heading\nParagraph $x$`"),
            ("setext heading", "Heading `\n---\nParagraph $x$`"),
            ("thematic break", "`paragraph\n***\nParagraph $x$`"),
            ("list item", "- `first item\n- Second item $x$`"),
            ("block quote", "`paragraph\n> Quote $x$`"),
        ]

        for (boundary, source) in cases {
            let result = preprocessor.process(source)

            XCTAssertEqual(result.math.map(\.source), ["x"], boundary)
        }
    }

    func testValidMultilineCodeSpansRemainInsideListAndBlockQuoteParagraphs() {
        let cases = [
            "- `code starts\n  $not-math$ ends`",
            "> `code starts\n> $not-math$ ends`",
        ]

        for source in cases {
            let result = preprocessor.process(source)

            XCTAssertTrue(result.math.isEmpty, source)
            XCTAssertTrue(result.source.contains("$not-math$"), result.source)
        }
    }

    func testATXHeadingBacktickCannotHideFollowingParagraphExtensions() {
        let source = """
        # `heading
        Paragraph $x$ and [^note]`
        [^note]: Footnote body
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.math.map(\.source), ["x"])
        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["note"])
    }

    func testFootnoteDefinitionSeparatesCodeDelimiterSegments() {
        let source = """
        `literal
        [^note]: Footnote body`
        Reference [^note].
        """

        let result = preprocessor.process(source)

        XCTAssertEqual(result.footnotes.map(\.id), ["note"])
        XCTAssertEqual(result.footnotes.map(\.source), ["Footnote body`"])
        XCTAssertEqual(result.footnoteReferences.map(\.id), ["note"])
        XCTAssertTrue(result.source.contains("Reference"), result.source)
    }

    func testOrderedMarkerAboveOneCannotInterruptOrdinaryParagraphCodeSpan() {
        let source = """
        Paragraph `code
        2. $not-math$`
        """

        let result = preprocessor.process(source)

        XCTAssertTrue(result.math.isEmpty, result.source)
        XCTAssertTrue(result.source.contains("$not-math$"), result.source)
    }

    func testOrderedListItemAndOneMarkerStillSeparateCodeDelimiterSegments() {
        let cases = [
            "Paragraph `code\n1. $x$`",
            "1. `first item\n2. $x$`",
        ]

        for source in cases {
            let result = preprocessor.process(source)

            XCTAssertEqual(result.math.map(\.source), ["x"], source)
        }
    }

    func testBlankAndNonASCIIListMarkersCannotInterruptOrdinaryParagraph() {
        let cases = [
            "Paragraph `code\n1.\ncontinued $not-math$`",
            "Paragraph `code\n*\ncontinued $not-math$`",
            "Paragraph `code\n١. $not-math$`",
        ]

        for source in cases {
            let result = preprocessor.process(source)

            XCTAssertTrue(result.math.isEmpty, source)
            XCTAssertTrue(result.source.contains("$not-math$"), result.source)
        }
    }
}
