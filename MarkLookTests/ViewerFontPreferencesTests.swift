import XCTest
@testable import MarkLook

final class ViewerFontPreferencesTests: XCTestCase {
    func testSystemFontIsTheDefault() {
        XCTAssertEqual(ViewerFontPreferences.defaultFontFamily, .system)
        XCTAssertEqual(
            ViewerFontPreferences.fontFamily(storedValue: "unknown"),
            .system
        )
    }

    func testStoredFontFamiliesAreRestored() {
        for fontFamily in ViewerFontFamily.allCases {
            XCTAssertEqual(
                ViewerFontPreferences.fontFamily(storedValue: fontFamily.rawValue),
                fontFamily
            )
        }
    }
}
