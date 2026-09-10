import Foundation
import SwiftSoup
import UniformTypeIdentifiers
import XCTest
@testable import MarkLook

final class DelimitedTextTests: XCTestCase {
    private let parser = DelimitedTextParser()

    func testDocumentFormatsAndSystemTypes() throws {
        for (name, expected) in [("report.CSV", DocumentFormat.csv), ("report.TsV", .tsv)] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(try DocumentFormat(url: url), expected)
            XCTAssertNotNil(ViewerWindowRoute.viewing(url))
        }
        XCTAssertEqual(UTType.commaSeparatedText.identifier, "public.comma-separated-values-text")
        XCTAssertEqual(UTType.tabSeparatedText.identifier, "public.tab-separated-values-text")
    }

    func testCSVQuotesEmbeddedNewlinesAndJapanese() throws {
        let source = "\u{FEFF}名前,メモ,番号\r\n佐藤,\"カンマ,引用符\"\"と改行\r\n次の行\",001\r\n"
        let result = try parser.parse(source, delimiter: ",")
        XCTAssertEqual(result.rows, [
            ["名前", "メモ", "番号"],
            ["佐藤", "カンマ,引用符\"と改行\r\n次の行", "001"],
        ])
        XCTAssertFalse(result.isTruncated)
    }

    func testTSVOnlySplitsTabsOutsideQuotes() throws {
        let result = try parser.parse("name\tnotes\nA\t\"tab\there, comma\nand newline\"", delimiter: "\t")
        XCTAssertEqual(result.rows, [["name", "notes"], ["A", "tab\there, comma\nand newline"]])
    }

    func testEmptyFieldsBlankRecordsAndMixedLineEndings() throws {
        let result = try parser.parse("a,b,c\r1,,\r\n\n,2,3\n4,5,", delimiter: ",")
        XCTAssertEqual(result.rows, [["a", "b", "c"], ["1", "", ""], [""], ["", "2", "3"], ["4", "5", ""]])
        XCTAssertEqual(try parser.parse("", delimiter: ",").rows, [])
        XCTAssertEqual(try parser.parse("\u{FEFF}", delimiter: ",").rows, [])
        XCTAssertEqual(try parser.parse("\"\"", delimiter: ",").rows, [[""]])
        XCTAssertEqual(try parser.parse("a,b\n", delimiter: ",").rows, [["a", "b"]])
    }

    func testUnicodeCombiningScalarsAndWhitespaceArePreserved() throws {
        let result = try parser.parse("a,b\n \"literal,\u{0301}👩🏽‍💻 \n", delimiter: ",")
        XCTAssertEqual(result.rows, [["a", "b"], [" \"literal", "\u{0301}👩🏽‍💻 "]])
    }

    func testMalformedQuotesReportRecordNumber() {
        for source in ["a,b\n1,\"unclosed", "a,b\n1,\"closed\"extra"] {
            XCTAssertThrowsError(try parser.parse(source, delimiter: ",")) { error in
                XCTAssertTrue(error.localizedDescription.contains("record 2"), error.localizedDescription)
            }
        }
    }

    func testPreviewLimitsKeepOnlyCompleteRecords() throws {
        let source = "a,b\r\n1,2\r\n3,4\r\n"
        XCTAssertEqual(
            try parser.parse(source, delimiter: ",", maximumRows: 2),
            .init(rows: [["a", "b"], ["1", "2"]], isTruncated: true)
        )
        XCTAssertEqual(
            try parser.parse(source, delimiter: ",", maximumCells: 5),
            .init(rows: [["a", "b"], ["1", "2"]], isTruncated: true)
        )
        for ending in ["", "\n", "\r\n"] {
            let exact = try parser.parse("a,b\n1,2" + ending, delimiter: ",", maximumRows: 2, maximumCells: 4)
            XCTAssertEqual(exact.rows, [["a", "b"], ["1", "2"]])
            XCTAssertFalse(exact.isTruncated)
        }
        XCTAssertThrowsError(try parser.parse("a,b,c", delimiter: ",", maximumCells: 2))
    }

    func testRenderEscapesMarkupAndKeepsFormulasLiteral() async throws {
        let output = try await render("name,value\n\"<script>alert(1)</script>\",=1+1\n\"<img src='https://example.com/a'>\",&amp;")
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        XCTAssertTrue(try document.select("script, img, a, input").isEmpty())
        XCTAssertEqual(try document.select("tbody tr").count, 2)
        XCTAssertEqual(try document.select("td .delimited-cell").array().map { try $0.text() }, [
            "<script>alert(1)</script>", "=1+1", "<img src='https://example.com/a'>", "&amp;",
        ])
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertFalse(output.containsMath)
        XCTAssertEqual(try document.select(".delimited-viewport").attr("tabindex"), "0")
    }

    func testRaggedRowsRetainExtraColumnsAndEmptyHeaders() async throws {
        let output = try await render("name,\nA,2,extra\nB")
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        XCTAssertEqual(try document.select("thead th[scope=col]").count, 4)
        XCTAssertEqual(try document.select(".delimited-placeholder").array().map { try $0.text() }, ["Column 2", "Column 3"])
        XCTAssertEqual(try document.select("tbody tr").last()?.select("td[colspan]").attr("colspan"), "2")
        XCTAssertTrue(output.htmlFragment.contains("extra"))
    }

    func testEmptyFileAndHeaderOnlyFile() async throws {
        let empty = try await render("")
        XCTAssertTrue(empty.htmlFragment.contains("This file has no rows."))
        let header = try await render("a,b")
        let document = try SwiftSoup.parseBodyFragment(header.htmlFragment)
        XCTAssertEqual(try document.select("tbody tr").count, 0)
        XCTAssertTrue(header.htmlFragment.contains("0 rows · 2 columns"))
    }

    func testTSVRenderUsesSamePipeline() async throws {
        let output = try await render("name\tvalue\n日本語\t001", format: .tsv)
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        XCTAssertEqual(try document.select("td .delimited-cell").array().map { try $0.text() }, ["日本語", "001"])
    }

    func testLargeTableAdvertisesPreviewAndBoundsRenderedRows() async throws {
        let output = try await render("name,value\n" + String(repeating: "A,001\n", count: 10_001))
        XCTAssertEqual(output.warnings.map(\.id), ["delimited-preview-limit"])
        XCTAssertTrue(output.htmlFragment.contains("Preview · 10000 rows"))
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        XCTAssertEqual(try document.select("tbody tr").count, 10_000)
    }

    func testUTF16TSVDecodesBeforeParsing() throws {
        let source = "名前\t番号\r\n佐藤\t001\r\n"
        let data = Data([0xFF, 0xFE]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        let decoded = try CharacterDecoder().decode(data, allowsHTMLMetaCharset: false)
        XCTAssertEqual(try parser.parse(decoded.text, delimiter: "\t").rows, [["名前", "番号"], ["佐藤", "001"]])
    }

    func testRenderProvidesSortColumnsAndOriginalRowIndices() async throws {
        let output = try await render("<Name>,\nC,2,extra\nA,1")
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        let buttons = try document.select("thead button.delimited-sort").array()
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(try buttons.map { try $0.attr("data-marklook-column") }, ["-1", "0", "1", "2"])
        XCTAssertEqual(try buttons.first?.text(), "#")
        XCTAssertEqual(try buttons.first?.attr("aria-label"), "Row number")
        XCTAssertEqual(try buttons[1].text(), "<Name>")
        XCTAssertTrue(try buttons.allSatisfy { try $0.attr("type") == "button" })
        XCTAssertEqual(try document.select("thead th[aria-sort=none]").count, 4)
        XCTAssertEqual(try document.select("tbody tr").array().map { try $0.attr("data-marklook-row") }, ["0", "1"])
        XCTAssertEqual(try document.select("tbody th[scope=row]").array().map { try $0.text() }, ["1", "2"])
    }

    func testCSVIdentifierColumnHasItsOwnSortControl() async throws {
        let output = try await render("id,name\n10,C\n2,B\n1,A")
        let document = try SwiftSoup.parseBodyFragment(output.htmlFragment)
        let idButton = try document.select("button[data-marklook-column=0]")
        XCTAssertEqual(try idButton.text(), "id")
        XCTAssertEqual(try document.select("tbody td:first-of-type .delimited-cell").array().map { try $0.text() }, ["10", "2", "1"])
        XCTAssertEqual(try document.select("tbody th[scope=row]").array().map { try $0.text() }, ["1", "2", "3"])
    }

    private func render(_ source: String, format: DocumentFormat = .csv) async throws -> RenderOutput {
        try await GFMRenderEngine().render(
            source: source,
            format: format,
            context: RenderContext(
                documentURL: URL(fileURLWithPath: "/tmp/table.\(format.rawValue)"),
                resourceAuthority: "test",
                sizeClass: .full
            )
        )
    }
}
