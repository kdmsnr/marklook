import Foundation
import XCTest
@testable import MarkLook

final class CharacterDecoderTests: XCTestCase {
    private let decoder = CharacterDecoder()

    func testUTF8BOMTakesPriorityOverConflictingMetaCharset() throws {
        let body = #"<meta charset="shift_jis"><p>こんにちは</p>"#
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try XCTUnwrap(body.data(using: .utf8)))

        let result = try decoder.decode(data)

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.source, .byteOrderMark)
    }

    func testUTF16LittleEndianBOMIsDecodedStrictly() throws {
        let body = #"<meta charset="utf-8"><p>日本語 😀</p>"#
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(body.data(using: .utf16LittleEndian)))

        let result = try decoder.decode(data)

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf16LittleEndian)
        XCTAssertEqual(result.source, .byteOrderMark)
    }

    func testUTF16BigEndianBOMIsDecodedStrictly() throws {
        let body = "# heading\n本文"
        var data = Data([0xFE, 0xFF])
        data.append(try XCTUnwrap(body.data(using: .utf16BigEndian)))

        let result = try decoder.decode(data)

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf16BigEndian)
        XCTAssertEqual(result.source, .byteOrderMark)
    }

    func testHTMLMetaCharsetIsDetectedAutomatically() throws {
        let body = #"<meta charset="Shift_JIS"><p>日本語</p>"#
        let data = try XCTUnwrap(body.data(using: .shiftJIS))

        let result = try decoder.decode(data)

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .shiftJIS)
        XCTAssertEqual(result.source, .htmlMetaCharset)
    }

    func testHTTPContentTypeStyleMetaCharsetIsRecognized() throws {
        let body = #"<meta http-equiv="content-type" content="text/html; charset=euc-jp"><p>日本語</p>"#
        let data = try XCTUnwrap(body.data(using: .japaneseEUC))

        let result = try decoder.decode(data)

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .eucJP)
        XCTAssertEqual(result.source, .htmlMetaCharset)
    }

    func testStrictUTF8IsDetectedAutomatically() throws {
        let body = "plain ASCII is valid UTF-8"

        let result = try decoder.decode(try XCTUnwrap(body.data(using: .utf8)))

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.source, .strictUTF8)
    }

    func testShiftJISWithoutHTMLDeclarationIsRejected() throws {
        let body = "日本語の文書"
        let data = try XCTUnwrap(body.data(using: .shiftJIS))

        XCTAssertThrowsError(try decoder.decode(data, allowsHTMLMetaCharset: false)) { error in
            XCTAssertEqual(error as? CharacterDecodingError, .undecodable)
        }
    }

    func testEUCJPWithoutHTMLDeclarationIsRejected() throws {
        let body = "日本語の文書"
        let data = try XCTUnwrap(body.data(using: .japaneseEUC))

        XCTAssertThrowsError(try decoder.decode(data, allowsHTMLMetaCharset: false)) { error in
            XCTAssertEqual(error as? CharacterDecodingError, .undecodable)
        }
    }

    func testInvalidUTF8IsNotSilentlyRepaired() {
        let data = Data([0x66, 0x6F, 0x80, 0x6F])

        XCTAssertThrowsError(try decoder.decode(data, allowsHTMLMetaCharset: false)) { error in
            XCTAssertEqual(error as? CharacterDecodingError, .undecodable)
        }
    }

    func testUnpairedUTF16SurrogateIsRejected() {
        // UTF-16 LE BOM, followed by an unpaired high surrogate.
        let data = Data([0xFF, 0xFE, 0x00, 0xD8])

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(
                error as? CharacterDecodingError,
                .malformedData(.utf16LittleEndian)
            )
        }
    }

    func testUnsupportedDeclaredCharsetDoesNotFallThroughToUTF8() {
        let data = Data(#"<meta charset="iso-8859-1"><p>text</p>"#.utf8)

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(
                error as? CharacterDecodingError,
                .unsupportedDeclaredEncoding("iso-8859-1")
            )
        }
    }

    func testMetaCharsetInsideCommentIsIgnored() throws {
        let body = #"<!-- <meta charset="shift_jis"> --><p>UTF-8 日本語</p>"#

        let result = try decoder.decode(Data(body.utf8))

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.source, .strictUTF8)
    }

    func testCharsetTextInsideOrdinaryMetaAttributeIsNotADeclaration() throws {
        let body = #"<meta name="description" content="charset=iso-8859-1"><p>UTF-8 日本語</p>"#

        let result = try decoder.decode(Data(body.utf8))

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.source, .strictUTF8)
    }

    func testMetaShapedTextInsideScriptIsNotADeclaration() throws {
        let body = #"<script>const example = '<meta charset="iso-8859-1">';</script><p>UTF-8 日本語</p>"#

        let result = try decoder.decode(Data(body.utf8))

        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.encoding, .utf8)
        XCTAssertEqual(result.source, .strictUTF8)
    }

    func testNULHeavyInputIsRejectedAsLikelyBinary() {
        let data = Data(repeating: 0, count: 256)

        XCTAssertThrowsError(try decoder.decode(data, allowsHTMLMetaCharset: false)) { error in
            XCTAssertEqual(error as? CharacterDecodingError, .likelyBinary)
        }
    }
}
