import Foundation
import Markdown

/// A GFM HTML formatter that escapes text and attributes before the sanitizer sees them.
/// Swift Markdown's formatter intentionally emits raw text, which is not appropriate for
/// untrusted viewer input (for example, `<script>` inside a code fence).
struct SecureHTMLFormatter: MarkupWalker {
    struct Output {
        let html: String
        let resources: Set<ResourceReference>
        let warnings: [RenderWarning]
    }

    private(set) var result = ""
    private(set) var resources = Set<ResourceReference>()
    private(set) var warnings: [RenderWarning] = []
    private var inTableHead = false
    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0
    private var anchorOccurrences: [String: Int] = [:]
    private var headingAnchorBaseCache: [String: String] = [:]
    private let context: RenderContext?
    private let lineBreakMode: MarkdownLineBreakMode
    private let source: MarkdownSourceText
    private let sanitizer = HTMLSanitizer()

    init(
        source: String,
        context: RenderContext? = nil,
        lineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks,
        estimatedSourceByteCount: Int = 0
    ) {
        self.context = context
        self.source = MarkdownSourceText(source)
        self.lineBreakMode = lineBreakMode
        if estimatedSourceByteCount > 0 {
            result.reserveCapacity(estimatedSourceByteCount.multipliedReportingOverflow(by: 2).partialValue)
        }
    }

    static func format(
        _ markup: Markup,
        source: String,
        lineBreakMode: MarkdownLineBreakMode = .gfmSoftBreaks,
        estimatedSourceByteCount: Int = 0
    ) -> String {
        var formatter = SecureHTMLFormatter(
            source: source,
            lineBreakMode: lineBreakMode,
            estimatedSourceByteCount: estimatedSourceByteCount
        )
        formatter.visit(markup)
        return formatter.result
    }

    static func format(
        _ markup: Markup,
        source: String,
        context: RenderContext,
        estimatedSourceByteCount: Int = 0
    ) -> Output {
        var formatter = SecureHTMLFormatter(
            source: source,
            context: context,
            lineBreakMode: context.markdownLineBreakMode,
            estimatedSourceByteCount: estimatedSourceByteCount
        )
        formatter.visit(markup)
        return Output(
            html: formatter.result,
            resources: formatter.resources,
            warnings: formatter.warnings
        )
    }

    mutating func defaultVisit(_ markup: Markup) {
        descendInto(markup)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let callout = ObsidianCallout(blockQuote, source: source) {
            renderCallout(callout, source: blockQuote)
            return
        }
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = normalizedLanguage(codeBlock.language)
        let languageAttribute = language.map { " class=\"language-\(HTMLEscaping.attribute($0))\"" } ?? ""
        result += "<pre><code\(languageAttribute)>\(HTMLEscaping.text(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let slug = uniqueAnchor(prefix: "heading", text: heading.plainText, preferReadable: true)
        result += "<h\(heading.level) id=\"\(HTMLEscaping.attribute(slug))\" data-marklook-anchor=\"\(HTMLEscaping.attribute(slug))\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if !Self.containsOnlyHTMLComments(html.rawHTML) {
            result += html.rawHTML
        }
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // Paragraphs inside list items already carry the stable scroll anchor required by the
        // restoration contract, so hashing the entire item a second time is redundant.
        result += "<li>"
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += "<input type=\"checkbox\" disabled\(checked) aria-label=\"Task\"> "
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let anchor = uniqueHashedAnchor(prefix: "paragraph", markup: paragraph)
        result += "<p data-marklook-anchor=\"\(anchor)\">"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = nil
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead><tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        result += "</tr></thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        currentTableColumn = 0
        result += "<tr>\n"
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        var attributes = ""
        if let alignments = tableColumnAlignments, currentTableColumn < alignments.count,
           let alignment = alignments[currentTableColumn]
        {
            attributes += " align=\"\(alignment)\""
        }
        currentTableColumn += 1
        if tableCell.rowspan > 1 { attributes += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { attributes += " colspan=\"\(tableCell.colspan)\"" }
        result += "<\(tag)\(attributes)>"
        descendInto(tableCell)
        result += "</\(tag)>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(HTMLEscaping.text(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        printInline(tag: "em", content: emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        printInline(tag: "strong", content: strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        printInline(tag: "del", content: strikethrough)
    }

    mutating func visitImage(_ image: Image) {
        let source: String
        if let rawSource = image.source, let context {
            if let rewritten = sanitizer.rewriteResource(
                rawSource,
                kind: .image,
                context: context,
                resources: &resources
            ) {
                source = " src=\"\(HTMLEscaping.attribute(rewritten))\" loading=\"eager\" decoding=\"async\""
            } else {
                source = ""
                if !rawSource.isEmpty {
                    warnings.append(.init(message: "Blocked non-local image: \(rawSource)"))
                }
            }
        } else {
            source = image.source.map { " src=\"\(HTMLEscaping.attribute($0))\"" } ?? ""
        }
        let title = image.title.map { " title=\"\(HTMLEscaping.attribute($0))\"" } ?? ""
        result += "<img\(source)\(title) alt=\"\(HTMLEscaping.attribute(image.plainText))\">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        if !Self.containsOnlyHTMLComments(inlineHTML.rawHTML) {
            result += inlineHTML.rawHTML
        }
    }

    mutating func visitLineBreak(_: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_: SoftBreak) {
        switch lineBreakMode {
        case .gfmSoftBreaks:
            result += "\n"
        case .preserveSingleNewlines:
            result += "<br>\n"
        }
    }

    mutating func visitLink(_ link: Link) {
        let destination: String
        if let rawDestination = link.destination, let context {
            if let rewritten = sanitizer.rewriteNavigation(rawDestination, context: context) {
                destination = " href=\"\(HTMLEscaping.attribute(rewritten))\" rel=\"noopener noreferrer\""
            } else {
                destination = ""
            }
        } else {
            destination = link.destination.map { " href=\"\(HTMLEscaping.attribute($0))\"" } ?? ""
        }
        let title = link.title.map { " title=\"\(HTMLEscaping.attribute($0))\"" } ?? ""
        result += "<a\(destination)\(title)>"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += HTMLEscaping.text(text.string)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination {
            result += "<code>\(HTMLEscaping.text(destination))</code>"
        }
    }

    private mutating func printInline(tag: String, content: Markup) {
        result += "<\(tag)>"
        descendInto(content)
        result += "</\(tag)>"
    }

    private mutating func renderCallout(_ callout: ObsidianCallout, source: BlockQuote) {
        let anchor = uniqueHashedAnchor(prefix: "callout", markup: source)
        let attributes = "class=\"callout\" data-callout=\"\(HTMLEscaping.attribute(callout.type))\" data-marklook-anchor=\"\(anchor)\""
        let rootTag: String
        let titleTag: String

        if let foldState = callout.foldState {
            rootTag = "details"
            titleTag = "summary"
            let open = foldState == .expanded ? " open" : ""
            result += "<details \(attributes)\(open)>\n"
        } else {
            rootTag = "div"
            titleTag = "div"
            result += "<div \(attributes) role=\"note\" aria-labelledby=\"\(anchor)-title\">\n"
        }

        let titleID = callout.foldState == nil ? " id=\"\(anchor)-title\"" : ""
        result += "<\(titleTag)\(titleID) class=\"callout-title\"><span class=\"callout-icon\" aria-hidden=\"true\"></span><span class=\"callout-title-inner\">"
        if callout.title.isEmpty {
            result += HTMLEscaping.text(callout.defaultTitle)
        } else {
            for inline in callout.title {
                visit(inline)
            }
        }
        result += "</span></\(titleTag)>\n"

        if callout.hasBody {
            result += "<div class=\"callout-content\">\n"
            if let leadingBodyParagraph = callout.leadingBodyParagraph {
                visit(leadingBodyParagraph)
            }
            for block in callout.remainingBody {
                visit(block)
            }
            result += "</div>\n"
        }

        result += "</\(rootTag)>\n"
    }

    private func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let language = raw.lowercased().prefix { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-" }
        return language.isEmpty ? nil : String(language)
    }

    private mutating func uniqueAnchor(prefix: String, text: String, preferReadable: Bool) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if preferReadable {
            if let cached = headingAnchorBaseCache[normalized] {
                base = cached
            } else {
                let slug = normalized
                    .lowercased()
                    .unicodeScalars
                    .reduce(into: "") { result, scalar in
                        if CharacterSet.alphanumerics.contains(scalar) {
                            result.unicodeScalars.append(scalar)
                        } else if scalar == " " || scalar == "-" || scalar == "_" {
                            if result.last != "-" { result.append("-") }
                        }
                    }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                base = slug.isEmpty ? "\(prefix)-\(shortHash(normalized))" : slug
                if headingAnchorBaseCache.count < 256 {
                    headingAnchorBaseCache[normalized] = base
                }
            }
        } else {
            base = "\(prefix)-\(shortHash(normalized))"
        }
        return uniqued(base)
    }

    private mutating func uniqueHashedAnchor(prefix: String, markup: Markup) -> String {
        let hash = stablePlainTextHash(in: markup)
        return uniqued("\(prefix)-\(hex(hash))")
    }

    private mutating func uniqued(_ base: String) -> String {
        let occurrence = anchorOccurrences[base, default: 0]
        anchorOccurrences[base] = occurrence + 1
        return occurrence == 0 ? base : "\(base)-\(occurrence + 1)"
    }

    private func shortHash(_ value: String) -> String {
        hex(stableHash(bytes: value.utf8))
    }

    private func stablePlainTextHash(in markup: Markup) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325

        func feed(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }

        func visit(_ node: Markup) {
            if let text = node as? Text {
                feed(text.string)
            } else if let code = node as? InlineCode {
                feed(code.code)
            } else if node is SoftBreak || node is LineBreak {
                feed("\n")
            } else if node.childCount == 0,
                      let convertible = node as? any PlainTextConvertibleMarkup
            {
                feed(convertible.plainText)
            } else {
                for child in node.children {
                    visit(child)
                }
            }
        }

        visit(markup)
        return hash
    }

    private func stableHash<Bytes: Sequence>(bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private func hex(_ value: UInt64) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            let shift = UInt64((15 - index) * 4)
            bytes[index] = digits[Int((value >> shift) & 0xF)]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Comments are omitted from the viewer DOM. The scanner accepts only a sequence of complete
    /// comments separated by whitespace; `<!-- safe --><script>...` therefore cannot enter the
    /// fast path by merely starting and ending like a comment.
    static func containsOnlyHTMLComments(_ rawHTML: String) -> Bool {
        var cursor = rawHTML.startIndex

        func skippingWhitespace(from start: String.Index) -> String.Index {
            var index = start
            while index < rawHTML.endIndex, rawHTML[index].isWhitespace {
                index = rawHTML.index(after: index)
            }
            return index
        }

        cursor = skippingWhitespace(from: cursor)
        var foundComment = false
        while cursor < rawHTML.endIndex {
            guard rawHTML[cursor...].hasPrefix("<!--") else { return false }
            let contentStart = rawHTML.index(cursor, offsetBy: 4)
            guard let close = rawHTML.range(
                of: "-->",
                range: contentStart ..< rawHTML.endIndex
            ) else { return false }
            foundComment = true
            cursor = skippingWhitespace(from: close.upperBound)
        }
        return foundComment
    }
}
