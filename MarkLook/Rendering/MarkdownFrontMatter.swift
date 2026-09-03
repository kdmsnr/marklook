import Foundation

/// Separates a leading YAML front matter block before the remaining source is parsed as Markdown.
///
/// This type only recognizes the document boundary. The metadata is intentionally not decoded:
/// visible mode presents the source as inert text so every valid YAML shape remains consistent.
struct MarkdownFrontMatter: Sendable {
    struct Extraction: Sendable, Equatable {
        let body: String
        /// The source between the delimiter lines. `nil` means no front matter was found, while
        /// an empty string represents an explicitly empty front matter block.
        let frontMatter: String?

        var found: Bool { frontMatter != nil }
    }

    func extract(from source: String) -> Extraction {
        let documentStart = startAfterByteOrderMark(in: source)
        guard let openingEnd = delimiterLineEnd(
            in: source,
            from: documentStart,
            markers: ["---"],
            requiresLineEnding: true
        ) else {
            return Extraction(body: source, frontMatter: nil)
        }

        let contentStart = source.index(after: openingEnd)
        var lineStart = contentStart
        while lineStart <= source.endIndex {
            if let closingEnd = delimiterLineEnd(
                in: source,
                from: lineStart,
                markers: ["---", "..."],
                requiresLineEnding: false
            ) {
                let bodyStart = closingEnd < source.endIndex
                    ? source.index(after: closingEnd)
                    : source.endIndex
                var contentEnd = lineStart
                if contentEnd > contentStart {
                    let precedingIndex = source.index(before: contentEnd)
                    if source[precedingIndex] == "\n" {
                        contentEnd = precedingIndex
                    }
                }
                return Extraction(
                    body: String(source[bodyStart...]),
                    frontMatter: String(source[contentStart..<contentEnd])
                )
            }

            guard let lineFeed = source[lineStart...].firstIndex(of: "\n") else {
                break
            }
            lineStart = source.index(after: lineFeed)
        }

        // An unmatched opening delimiter is ordinary Markdown. Failing open avoids hiding the
        // entire document when a thematic break happens to be its first line.
        return Extraction(body: source, frontMatter: nil)
    }

    private func startAfterByteOrderMark(in source: String) -> String.Index {
        guard source.first == "\u{FEFF}" else { return source.startIndex }
        return source.index(after: source.startIndex)
    }

    /// Returns the index of the line feed, or `source.endIndex` for an allowed final delimiter.
    private func delimiterLineEnd(
        in source: String,
        from start: String.Index,
        markers: [String],
        requiresLineEnding: Bool
    ) -> String.Index? {
        guard start < source.endIndex else { return nil }
        let lineFeed = source[start...].firstIndex(of: "\n")
        guard lineFeed != nil || !requiresLineEnding else { return nil }
        let end = lineFeed ?? source.endIndex
        let line = source[start..<end]

        guard markers.contains(where: { marker in
            guard line.hasPrefix(marker) else { return false }
            let suffix = line.dropFirst(marker.count)
            return suffix.allSatisfy { $0 == " " || $0 == "\t" }
        }) else {
            return nil
        }
        return end
    }
}
