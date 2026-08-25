import Foundation

enum HTMLEscaping {
    static func text(_ value: String) -> String {
        escape(value, includesQuotes: false)
    }

    static func attribute(_ value: String) -> String {
        escape(value, includesQuotes: true)
    }

    /// A single scalar pass avoids creating three to five complete intermediate strings. Most
    /// Markdown text contains no escapable scalar, in which case the original String storage is
    /// returned without allocation.
    private static func escape(_ value: String, includesQuotes: Bool) -> String {
        let scalars = value.unicodeScalars
        var segmentStart = value.startIndex
        var output = ""
        var didEscape = false

        for index in scalars.indices {
            let replacement: StaticString?
            switch scalars[index].value {
            case 0x26: replacement = "&amp;"
            case 0x3C: replacement = "&lt;"
            case 0x3E: replacement = "&gt;"
            case 0x22 where includesQuotes: replacement = "&quot;"
            case 0x27 where includesQuotes: replacement = "&#39;"
            default: replacement = nil
            }

            guard let replacement else { continue }
            if !didEscape {
                output.reserveCapacity(value.utf8.count + 16)
                didEscape = true
            }
            output.append(contentsOf: value[segmentStart ..< index])
            output.append(contentsOf: replacement.description)
            segmentStart = scalars.index(after: index)
        }

        guard didEscape else { return value }
        output.append(contentsOf: value[segmentStart ..< value.endIndex])
        return output
    }
}
