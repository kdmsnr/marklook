import XCTest
@testable import MarkLook

final class HTMLEscapingTests: XCTestCase {
    func testTextWithoutReservedScalarsIsUnchanged() {
        XCTAssertEqual(HTMLEscaping.text("日本語 and plain text"), "日本語 and plain text")
    }

    func testTextEscapesMarkupScalarsInOnePass() {
        XCTAssertEqual(
            HTMLEscaping.text("<tag>Tom & Jerry</tag>"),
            "&lt;tag&gt;Tom &amp; Jerry&lt;/tag&gt;"
        )
    }

    func testAttributeAlsoEscapesBothQuoteStyles() {
        XCTAssertEqual(
            HTMLEscaping.attribute("\"one\" & 'two' <three>"),
            "&quot;one&quot; &amp; &#39;two&#39; &lt;three&gt;"
        )
    }
}
