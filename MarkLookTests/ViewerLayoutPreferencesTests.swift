import XCTest
@testable import MarkLook

final class ViewerLayoutPreferencesTests: XCTestCase {
    func testContentWidthIsClampedToSupportedRange() {
        XCTAssertEqual(
            ViewerLayoutPreferences.normalizedContentWidth(100),
            ViewerLayoutPreferences.minimumContentWidth
        )
        XCTAssertEqual(
            ViewerLayoutPreferences.normalizedContentWidth(9_000),
            ViewerLayoutPreferences.maximumContentWidth
        )
        XCTAssertEqual(ViewerLayoutPreferences.normalizedContentWidth(1_040), 1_040)
    }

    func testInvalidContentWidthUsesDefault() {
        XCTAssertEqual(
            ViewerLayoutPreferences.normalizedContentWidth(.infinity),
            ViewerLayoutPreferences.defaultContentWidth
        )
        XCTAssertEqual(
            ViewerLayoutPreferences.normalizedContentWidth(.nan),
            ViewerLayoutPreferences.defaultContentWidth
        )
    }

    func testFullWidthHasNoMaximumWhileConfiguredWidthIsNormalized() {
        XCTAssertNil(
            ViewerLayoutPreferences.effectiveContentWidth(
                configuredWidth: 800,
                usesFullWidth: true
            )
        )
        XCTAssertEqual(
            ViewerLayoutPreferences.effectiveContentWidth(
                configuredWidth: 100,
                usesFullWidth: false
            ),
            ViewerLayoutPreferences.minimumContentWidth
        )
    }
}
