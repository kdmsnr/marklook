import XCTest
@testable import MarkLook

final class MarkdownRenderingPreferencesTests: XCTestCase {
    func testGFMIsTheDefaultLineBreakMode() {
        XCTAssertEqual(MarkdownRenderingPreferences.defaultLineBreakMode, .gfmSoftBreaks)
        XCTAssertEqual(
            MarkdownRenderingPreferences.lineBreakMode(storedValue: "unknown"),
            .gfmSoftBreaks
        )
    }

    func testStoredLineBreakModeIsRestored() {
        XCTAssertEqual(
            MarkdownRenderingPreferences.lineBreakMode(
                storedValue: MarkdownLineBreakMode.preserveSingleNewlines.rawValue
            ),
            .preserveSingleNewlines
        )
    }
}
