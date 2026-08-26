import Foundation

/// Controls only how parsed `SoftBreak` nodes are displayed; it does not change the parser dialect.
enum MarkdownLineBreakMode: String, CaseIterable, Sendable {
    case gfmSoftBreaks = "gfm-soft-breaks"
    case preserveSingleNewlines = "preserve-single-newlines"
}

enum MarkdownRenderingPreferences {
    static let lineBreakModeKey = "MarkdownLineBreakMode.v1"
    static let defaultLineBreakMode = MarkdownLineBreakMode.gfmSoftBreaks

    static func lineBreakMode(storedValue: String) -> MarkdownLineBreakMode {
        MarkdownLineBreakMode(rawValue: storedValue) ?? defaultLineBreakMode
    }
}
