import XCTest
@testable import MarkLook

final class MarkupPreprocessorTests: XCTestCase {
    private let preprocessor = MarkupPreprocessor()

    func testFeaturelessMarkdownIsPreservedExactly() {
        let source = "# Heading\n\nParagraph with `code` and [a link](next.md).\n\n"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertTrue(result.math.isEmpty)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferenceTokens.isEmpty)
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
        XCTAssertTrue(result.footnoteReferenceTokens.isEmpty)
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
        XCTAssertEqual(result.footnoteReferenceTokens.values.sorted(), ["注"])
    }

    func testMultibyteScalarBetweenBracketAndCaretIsNotAFootnoteMarker() {
        let source = "本文 [é^note] と [🙂^note] は脚注ではない"

        let result = preprocessor.process(source)

        XCTAssertEqual(result.source, source)
        XCTAssertTrue(result.footnotes.isEmpty)
        XCTAssertTrue(result.footnoteReferenceTokens.isEmpty)
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
        XCTAssertEqual(result.footnoteReferenceTokens.values.sorted(), ["note"])
    }
}
