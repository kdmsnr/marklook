import Foundation

enum ViewerLayoutPreferences {
    static let contentWidthKey = "ViewerContentWidth.v1"
    static let usesFullWidthKey = "ViewerUsesFullWidth.v1"

    static let defaultContentWidth = 1_200.0
    static let minimumContentWidth = 480.0
    static let maximumContentWidth = 2_400.0

    static func normalizedContentWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultContentWidth }
        return min(max(value, minimumContentWidth), maximumContentWidth)
    }

    static func effectiveContentWidth(
        configuredWidth: Double,
        usesFullWidth: Bool
    ) -> Double? {
        usesFullWidth ? nil : normalizedContentWidth(configuredWidth)
    }
}
