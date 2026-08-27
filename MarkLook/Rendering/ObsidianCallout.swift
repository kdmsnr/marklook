import Foundation
import Markdown

/// A parsed Obsidian-style callout stored inside a Markdown block quote.
///
/// Callouts are recognized structurally after Markdown parsing so their title and body continue
/// to use the regular secure formatter. Malformed markers remain ordinary block quotes.
struct ObsidianCallout {
    enum FoldState {
        case expanded
        case collapsed
    }

    let type: String
    let foldState: FoldState?
    let title: [Markup]
    let defaultTitle: String
    let leadingBodyParagraph: Paragraph?
    let remainingBody: [Markup]

    var hasBody: Bool {
        leadingBodyParagraph != nil || !remainingBody.isEmpty
    }

    init?(_ blockQuote: BlockQuote, source: MarkdownSourceText) {
        let blocks = Array(blockQuote.children)
        guard let firstParagraph = blocks.first as? Paragraph else { return nil }

        var inlines = Array(firstParagraph.children)
        guard let firstText = inlines.first as? Text,
              firstText.string.hasPrefix("[!"),
              let markerLocation = firstText.range?.lowerBound,
              let marker = source.calloutMarker(at: markerLocation),
              firstText.string.hasPrefix(marker.decodedPrefix)
        else { return nil }

        let decodedRemainder = firstText.string.dropFirst(marker.decodedPrefix.count)
        let titleStart = decodedRemainder.firstIndex { character in
            character != " " && character != "\t"
        } ?? decodedRemainder.endIndex
        let remainder = String(decodedRemainder[titleStart...])

        if remainder.isEmpty {
            inlines.removeFirst()
        } else {
            inlines[0] = Text(remainder)
        }

        let separatorIndex = inlines.firstIndex { $0 is SoftBreak || $0 is LineBreak }
        let titleEnd = separatorIndex ?? inlines.endIndex
        let title = Array(inlines[..<titleEnd])

        // A break nested inside emphasis, a link, or multiline code does not appear as a direct
        // paragraph child. Conservatively leave such input as a block quote instead of allowing
        // content from the next source line to be swallowed into the title.
        if separatorIndex == nil,
           title.contains(where: { ($0.range?.upperBound.line ?? markerLocation.line) > markerLocation.line })
        {
            return nil
        }

        let bodyInlines: [Markup]
        if let separatorIndex {
            bodyInlines = Array(inlines[inlines.index(after: separatorIndex)...])
        } else {
            bodyInlines = []
        }

        let leadingBodyParagraph: Paragraph?
        if bodyInlines.isEmpty {
            leadingBodyParagraph = nil
        } else {
            leadingBodyParagraph = firstParagraph.withUncheckedChildren(bodyInlines) as? Paragraph
        }

        type = marker.type
        foldState = marker.foldState
        self.title = title
        defaultTitle = marker.type
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        self.leadingBodyParagraph = leadingBodyParagraph
        remainingBody = Array(blocks.dropFirst())
    }
}

fileprivate struct ObsidianCalloutMarker {
    let type: String
    let foldState: ObsidianCallout.FoldState?
    let decodedPrefix: String
}

/// Preserves the exact parsed Markdown source so AST text decoding cannot turn an escaped or
/// entity-encoded marker into a callout. Source columns from swift-markdown are 1-based UTF-8.
final class MarkdownSourceText {
    private let source: String
    private var lines: [Substring]?

    init(_ source: String) {
        self.source = source
    }

    fileprivate func calloutMarker(at location: SourceLocation) -> ObsidianCalloutMarker? {
        // Most Markdown has no callouts. Build the line index only after the AST has produced a
        // marker candidate, keeping the normal rendering path allocation-light.
        if lines == nil {
            lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        }
        guard location.line > 0,
              let lines,
              location.line <= lines.count,
              location.column > 0
        else { return nil }

        let line = lines[location.line - 1]
        let byteOffset = location.column - 1
        guard byteOffset < line.utf8.count else { return nil }

        let bytes = Array(line.utf8.dropFirst(byteOffset))
        guard bytes.count >= 4, bytes[0] == 91, bytes[1] == 33 else { return nil }

        var cursor = 2
        while cursor < bytes.count, Self.isIdentifierByte(bytes[cursor]) {
            cursor += 1
        }
        let typeLength = cursor - 2
        guard (1...64).contains(typeLength), cursor < bytes.count, bytes[cursor] == 93 else {
            return nil
        }

        let rawType = String(decoding: bytes[2..<cursor], as: UTF8.self)
        cursor += 1

        let foldState: ObsidianCallout.FoldState?
        if cursor < bytes.count, bytes[cursor] == 43 {
            foldState = .expanded
            cursor += 1
        } else if cursor < bytes.count, bytes[cursor] == 45 {
            foldState = .collapsed
            cursor += 1
        } else {
            foldState = nil
        }

        return ObsidianCalloutMarker(
            type: rawType.lowercased(),
            foldState: foldState,
            decodedPrefix: String(decoding: bytes[..<cursor], as: UTF8.self)
        )
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 45, 95:
            true
        default:
            false
        }
    }
}
