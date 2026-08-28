import Foundation

enum ViewerFontFamily: String, CaseIterable, Sendable {
    case system
    case hiraginoSans = "hiragino-sans"
    case hiraginoMincho = "hiragino-mincho"

    var displayName: String {
        switch self {
        case .system:
            "System"
        case .hiraginoSans:
            "Hiragino Sans"
        case .hiraginoMincho:
            "Hiragino Mincho"
        }
    }
}

enum ViewerFontPreferences {
    static let fontFamilyKey = "ViewerFontFamily.v1"
    static let defaultFontFamily = ViewerFontFamily.system

    static func fontFamily(storedValue: String) -> ViewerFontFamily {
        ViewerFontFamily(rawValue: storedValue) ?? defaultFontFamily
    }
}
