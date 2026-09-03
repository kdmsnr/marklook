import Foundation

struct MarkupPreprocessor: Sendable {
    private let frontMatter = MarkdownFrontMatter()

    struct MathReplacement: Sendable {
        let token: String
        let source: String
        let display: Bool
    }

    struct Footnote: Sendable {
        let id: String
        let source: String
    }

    struct FootnoteReference: Sendable {
        let token: String
        let id: String
    }

    struct Result: Sendable {
        let source: String
        let frontMatter: String?
        let math: [MathReplacement]
        let footnotes: [Footnote]
        let footnoteReferences: [FootnoteReference]
    }

    func process(_ input: String) -> Result {
        let markers = scanMarkers(in: input)
        let startsWithFrontMatter = input.hasPrefix("---") || input.hasPrefix("\u{FEFF}---")

        // Most documents use neither MarkLook extensions nor front matter. Scan the UTF-8 bytes
        // once so this path can return the original copy-on-write String without normalizing or
        // allocating storage.
        guard markers.hasCarriageReturn || markers.hasExtension || startsWithFrontMatter else {
            return Result(
                source: input,
                frontMatter: nil,
                math: [],
                footnotes: [],
                footnoteReferences: []
            )
        }

        let normalized: String
        if markers.hasCarriageReturn {
            normalized = input
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        } else {
            normalized = input
        }

        let frontMatterExtraction = startsWithFrontMatter
            ? frontMatter.extract(from: normalized)
            : .init(body: normalized, frontMatter: nil)
        let markdownSource = frontMatterExtraction.body
        let hasExtension = markers.hasExtension
            && (!frontMatterExtraction.found || scanMarkers(in: markdownSource).hasExtension)

        guard hasExtension else {
            return Result(
                source: markdownSource,
                frontMatter: frontMatterExtraction.frontMatter,
                math: [],
                footnotes: [],
                footnoteReferences: []
            )
        }

        let prefix = "MARKLOOK_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_"
        let extracted = extractFootnotes(from: markdownSource)
        let footnoteIDs = Set(extracted.footnotes.map(\.id))

        var math: [MathReplacement] = []
        var footnoteReferences: [FootnoteReference] = []
        var output: [String] = []
        var activeFence: MarkdownFence?
        var inlineCodeDelimiterLength: Int?
        var blockMathLines: [String]? = nil

        let lines = extracted.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let codeSpanPlan = codeSpanPlan(in: lines)
        for (lineNumber, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if codeSpanPlan.resetBeforeLines.contains(lineNumber) {
                inlineCodeDelimiterLength = nil
            }
            defer {
                if codeSpanPlan.resetAfterLines.contains(lineNumber) {
                    inlineCodeDelimiterLength = nil
                }
            }

            if let fence = activeFence {
                if isFenceClosing(line, for: fence) { activeFence = nil }
                output.append(line)
                continue
            }
            if let fence = fenceOpening(in: line) {
                activeFence = fence
                inlineCodeDelimiterLength = nil
                output.append(line)
                continue
            }
            if trimmed.isEmpty { inlineCodeDelimiterLength = nil }

            // A CommonMark code span may cross a soft line break. While one is open, let the
            // inline scanner consume the line before considering block-math markers.
            if inlineCodeDelimiterLength != nil {
                output.append(processInline(
                    line,
                    prefix: prefix,
                    math: &math,
                    footnoteIDs: footnoteIDs,
                    footnoteReferences: &footnoteReferences,
                    codeDelimiterLength: &inlineCodeDelimiterLength,
                    lineNumber: lineNumber,
                    codeSpanOpeners: codeSpanPlan.openers
                ))
                continue
            }

            if var collected = blockMathLines {
                if trimmed.hasSuffix("$$") {
                    let content = String(line.dropLast(2))
                    collected.append(content)
                    let token = "\(prefix)MATH_\(math.count)_TOKEN"
                    math.append(.init(token: token, source: collected.joined(separator: "\n"), display: true))
                    output.append(token)
                    blockMathLines = nil
                } else {
                    collected.append(line)
                    blockMathLines = collected
                }
                continue
            }

            if trimmed.hasPrefix("$$") {
                let afterOpen = String(trimmed.dropFirst(2))
                if afterOpen.hasSuffix("$$"), afterOpen.count >= 2 {
                    let body = String(afterOpen.dropLast(2))
                    let token = "\(prefix)MATH_\(math.count)_TOKEN"
                    math.append(.init(token: token, source: body, display: true))
                    output.append(token)
                } else {
                    blockMathLines = [afterOpen]
                }
                continue
            }

            output.append(processInline(
                line,
                prefix: prefix,
                math: &math,
                footnoteIDs: footnoteIDs,
                footnoteReferences: &footnoteReferences,
                codeDelimiterLength: &inlineCodeDelimiterLength,
                lineNumber: lineNumber,
                codeSpanOpeners: codeSpanPlan.openers
            ))
        }

        if let unterminated = blockMathLines {
            output.append("$$" + unterminated.joined(separator: "\n"))
        }

        return Result(
            source: output.joined(separator: "\n"),
            frontMatter: frontMatterExtraction.frontMatter,
            math: math,
            footnotes: extracted.footnotes,
            footnoteReferences: footnoteReferences
        )
    }

    private func scanMarkers(in input: String) -> (hasCarriageReturn: Bool, hasExtension: Bool) {
        var hasCarriageReturn = false
        var hasExtension = false
        var previousByteWasOpenBracket = false

        // All markers are ASCII. Their byte values cannot occur inside a multi-byte UTF-8 scalar,
        // so matching adjacent bytes is equivalent to matching these literal source characters.
        for byte in input.utf8 {
            if byte == 0x0D {
                hasCarriageReturn = true
            } else if byte == 0x24 || (previousByteWasOpenBracket && byte == 0x5E) {
                hasExtension = true
            }

            if hasCarriageReturn && hasExtension {
                break
            }
            previousByteWasOpenBracket = byte == 0x5B
        }

        return (hasCarriageReturn, hasExtension)
    }

    private func fenceOpening(in line: String) -> MarkdownFence? {
        guard let contentStart = fenceContentStart(in: line), contentStart < line.endIndex else {
            return nil
        }
        let marker = line[contentStart]
        guard marker == "`" || marker == "~" else { return nil }
        let run = characterRun(in: line, from: contentStart, character: marker)
        guard run.count >= 3 else { return nil }
        if marker == "`", line[run.end...].contains("`") { return nil }
        return MarkdownFence(marker: marker, length: run.count)
    }

    private func isFenceClosing(_ line: String, for fence: MarkdownFence) -> Bool {
        guard let contentStart = fenceContentStart(in: line), contentStart < line.endIndex,
              line[contentStart] == fence.marker else { return false }
        let run = characterRun(in: line, from: contentStart, character: fence.marker)
        guard run.count >= fence.length else { return false }
        return line[run.end...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func fenceContentStart(in line: String) -> String.Index? {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex, line[cursor] == " " {
            spaces += 1
            guard spaces <= 3 else { return nil }
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex, line[cursor] == "\t" { return nil }
        return cursor
    }

    private func processInline(
        _ line: String,
        prefix: String,
        math: inout [MathReplacement],
        footnoteIDs: Set<String>,
        footnoteReferences: inout [FootnoteReference],
        codeDelimiterLength: inout Int?,
        lineNumber: Int,
        codeSpanOpeners: Set<CodeDelimiterPosition>
    ) -> String {
        var result = ""
        var index = line.startIndex
        var runNumber = 0

        while index < line.endIndex {
            if line[index] == "`" {
                let run = characterRun(in: line, from: index, character: "`")
                result += String(line[index ..< run.end])
                let position = CodeDelimiterPosition(line: lineNumber, run: runNumber)
                runNumber += 1
                if let delimiter = codeDelimiterLength {
                    // Backslash escapes are not interpreted inside a CommonMark code span.
                    if run.count == delimiter { codeDelimiterLength = nil }
                } else if codeSpanOpeners.contains(position) {
                    codeDelimiterLength = run.count
                }
                index = run.end
                continue
            }

            guard codeDelimiterLength == nil else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            if line[index] == "[", !isEscaped(line, at: index),
               let reference = footnoteReference(in: line, from: index),
               footnoteIDs.contains(reference.id)
            {
                let token = "\(prefix)FOOTNOTE_\(footnoteReferences.count)_TOKEN"
                footnoteReferences.append(.init(token: token, id: reference.id))
                result += token
                index = reference.end
                continue
            }

            if line[index] == "$", !isEscaped(line, at: index), !line[index...].hasPrefix("$$") {
                let contentStart = line.index(after: index)
                if let close = closingDollar(in: line, from: contentStart) {
                    let body = String(line[contentStart ..< close])
                    if !body.isEmpty,
                       body.first?.isWhitespace != true,
                       body.last?.isWhitespace != true
                    {
                        let token = "\(prefix)MATH_\(math.count)_TOKEN"
                        math.append(.init(token: token, source: body, display: false))
                        result += token
                        index = line.index(after: close)
                        continue
                    }
                }
            }

            result.append(line[index])
            index = line.index(after: index)
        }
        return result
    }

    private func closingDollar(in line: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < line.endIndex {
            if line[index] == "$", !isEscaped(line, at: index) {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] != "$" { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func isEscaped(_ string: String, at index: String.Index) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > string.startIndex {
            let previous = string.index(before: cursor)
            guard string[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }

    private func characterRun(
        in string: String,
        from start: String.Index,
        character: Character
    ) -> (count: Int, end: String.Index) {
        var index = start
        var count = 0
        while index < string.endIndex, string[index] == character {
            count += 1
            index = string.index(after: index)
        }
        return (count, index)
    }

    private func footnoteReference(in line: String, from start: String.Index) -> (id: String, end: String.Index)? {
        let markerEnd = line.index(start, offsetBy: 2, limitedBy: line.endIndex)
        guard let markerEnd, line[start ..< markerEnd] == "[^" else { return nil }
        guard let close = line[markerEnd...].firstIndex(of: "]") else { return nil }
        let id = String(line[markerEnd ..< close])
        guard !id.isEmpty else { return nil }
        return (id, line.index(after: close))
    }

    private func extractFootnotes(from source: String) -> (source: String, footnotes: [Footnote]) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var footnotes: [Footnote] = []
        var index = 0
        var activeFence: MarkdownFence?
        var inlineCodeDelimiterLength: Int?
        let codeSpanPlan = codeSpanPlan(in: lines)

        while index < lines.count {
            let lineNumber = index
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if codeSpanPlan.resetBeforeLines.contains(lineNumber) {
                inlineCodeDelimiterLength = nil
            }
            defer {
                if codeSpanPlan.resetAfterLines.contains(lineNumber) {
                    inlineCodeDelimiterLength = nil
                }
            }
            if let fence = activeFence {
                if isFenceClosing(line, for: fence) { activeFence = nil }
                output.append(line)
                index += 1
                continue
            }
            if let fence = fenceOpening(in: line) {
                activeFence = fence
                inlineCodeDelimiterLength = nil
                output.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty { inlineCodeDelimiterLength = nil }
            let startsInsideCodeSpan = inlineCodeDelimiterLength != nil
            if !startsInsideCodeSpan, let definition = footnoteDefinition(line) {
                inlineCodeDelimiterLength = nil
                var body = [definition.body]
                index += 1
                while index < lines.count {
                    let continuation = lines[index]
                    if continuation.hasPrefix("    ") || continuation.hasPrefix("\t") {
                        body.append(continuation.trimmingCharacters(in: .whitespaces))
                        index += 1
                    } else {
                        break
                    }
                }
                footnotes.append(.init(id: definition.id, source: body.joined(separator: "\n")))
                continue
            }

            updateInlineCodeDelimiter(
                in: line,
                lineNumber: lineNumber,
                openers: codeSpanPlan.openers,
                delimiterLength: &inlineCodeDelimiterLength
            )
            output.append(line)
            index += 1
        }
        return (output.joined(separator: "\n"), footnotes)
    }

    private func updateInlineCodeDelimiter(
        in line: String,
        lineNumber: Int,
        openers: Set<CodeDelimiterPosition>,
        delimiterLength: inout Int?
    ) {
        var cursor = line.startIndex
        var runNumber = 0
        while cursor < line.endIndex {
            guard line[cursor] == "`" else {
                cursor = line.index(after: cursor)
                continue
            }
            let run = characterRun(in: line, from: cursor, character: "`")
            let position = CodeDelimiterPosition(line: lineNumber, run: runNumber)
            runNumber += 1
            if let activeDelimiter = delimiterLength {
                if run.count == activeDelimiter { delimiterLength = nil }
            } else if openers.contains(position) {
                delimiterLength = run.count
            }
            cursor = run.end
        }
    }

    /// CommonMark treats a backtick string as an opener only when a later string of exactly the
    /// same length can close it in the same inline block. Precomputing those openers prevents an
    /// unmatched literal backtick from suppressing extensions on every following source line.
    private func codeSpanPlan(in lines: [String]) -> CodeSpanPlan {
        var openers = Set<CodeDelimiterPosition>()
        var resetBeforeLines = Set<Int>()
        var resetAfterLines = Set<Int>()
        var segment: [CodeDelimiterRun] = []
        var segmentHasLines = false
        var activeFence: MarkdownFence?
        var activeQuoteDepth: Int?
        var activeList = false

        func finishSegment() {
            if !segment.isEmpty {
                var remaining: [Int: Int] = [:]
                for run in segment { remaining[run.length, default: 0] += 1 }

                var activeLength: Int?
                for run in segment {
                    remaining[run.length, default: 0] -= 1
                    if let activeDelimiter = activeLength {
                        if run.length == activeDelimiter { activeLength = nil }
                    } else if !run.isEscaped,
                              remaining[run.length, default: 0] > 0
                    {
                        openers.insert(run.position)
                        activeLength = run.length
                    }
                }
            }
            segment.removeAll(keepingCapacity: true)
            segmentHasLines = false
        }

        func appendRuns(in line: String, lineNumber: Int) {
            segmentHasLines = true
            var cursor = line.startIndex
            var runNumber = 0
            while cursor < line.endIndex {
                guard line[cursor] == "`" else {
                    cursor = line.index(after: cursor)
                    continue
                }
                let run = characterRun(in: line, from: cursor, character: "`")
                segment.append(.init(
                    position: .init(line: lineNumber, run: runNumber),
                    length: run.count,
                    isEscaped: isEscaped(line, at: cursor)
                ))
                runNumber += 1
                cursor = run.end
            }
        }

        func isolateLine(_ line: String, lineNumber: Int, scansInlineContent: Bool) {
            finishSegment()
            resetBeforeLines.insert(lineNumber)
            if scansInlineContent { appendRuns(in: line, lineNumber: lineNumber) }
            finishSegment()
            resetAfterLines.insert(lineNumber)
        }

        for (lineNumber, line) in lines.enumerated() {
            if let fence = activeFence {
                resetBeforeLines.insert(lineNumber)
                resetAfterLines.insert(lineNumber)
                if isFenceClosing(line, for: fence) {
                    activeFence = nil
                    activeQuoteDepth = nil
                    activeList = false
                }
                continue
            }
            if let fence = fenceOpening(in: line) {
                finishSegment()
                resetBeforeLines.insert(lineNumber)
                resetAfterLines.insert(lineNumber)
                activeFence = fence
                activeQuoteDepth = nil
                activeList = false
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finishSegment()
                resetBeforeLines.insert(lineNumber)
                resetAfterLines.insert(lineNumber)
                activeQuoteDepth = nil
                activeList = false
                continue
            }
            if footnoteDefinition(line) != nil {
                isolateLine(line, lineNumber: lineNumber, scansInlineContent: false)
                activeQuoteDepth = nil
                activeList = false
                continue
            }

            let structure = markdownBlockStructure(in: line)
            if let quoteDepth = structure.explicitQuoteDepth {
                if quoteDepth != activeQuoteDepth {
                    finishSegment()
                    resetBeforeLines.insert(lineNumber)
                    activeList = false
                }
                activeQuoteDepth = quoteDepth
            }

            let startsListItem = structure.listMarker.map {
                !segmentHasLines || activeList || $0.canInterruptParagraph
            } ?? false
            if startsListItem {
                finishSegment()
                resetBeforeLines.insert(lineNumber)
                if structure.explicitQuoteDepth == nil { activeQuoteDepth = nil }
                activeList = true
            }

            let contentStart = startsListItem
                ? structure.contentStart
                : structure.contentStartBeforeListMarker
            let content = line[contentStart...]
            if isATXHeading(content) {
                isolateLine(line, lineNumber: lineNumber, scansInlineContent: true)
                activeQuoteDepth = nil
                if structure.listMarker == nil { activeList = false }
                continue
            }
            if isThematicBreak(content) || isSetextUnderline(content) {
                isolateLine(line, lineNumber: lineNumber, scansInlineContent: false)
                activeQuoteDepth = nil
                if structure.listMarker == nil { activeList = false }
                continue
            }
            if structure.isIndentedCodeCandidate, !segmentHasLines {
                isolateLine(line, lineNumber: lineNumber, scansInlineContent: false)
                activeQuoteDepth = nil
                activeList = false
                continue
            }

            appendRuns(in: line, lineNumber: lineNumber)
        }
        finishSegment()
        return CodeSpanPlan(
            openers: openers,
            resetBeforeLines: resetBeforeLines,
            resetAfterLines: resetAfterLines
        )
    }

    private func markdownBlockStructure(in line: String) -> MarkdownBlockStructure {
        var cursor = line.startIndex
        let initialIndent = leadingIndent(in: line, from: cursor, limit: 4)
        let isIndentedCodeCandidate = initialIndent.width >= 4 || initialIndent.sawTab
        cursor = initialIndent.width <= 3 && !initialIndent.sawTab ? initialIndent.end : line.startIndex

        var quoteDepth = 0
        while cursor < line.endIndex, line[cursor] == ">" {
            quoteDepth += 1
            cursor = line.index(after: cursor)
            if cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                cursor = line.index(after: cursor)
            }

            let beforeNestedIndent = cursor
            let nestedIndent = leadingIndent(in: line, from: cursor, limit: 3)
            if !nestedIndent.sawTab,
               nestedIndent.width <= 3,
               nestedIndent.end < line.endIndex,
               line[nestedIndent.end] == ">"
            {
                cursor = nestedIndent.end
            } else {
                cursor = beforeNestedIndent
                break
            }
        }

        let listIndent = leadingIndent(in: line, from: cursor, limit: 3)
        if !listIndent.sawTab, listIndent.width <= 3 { cursor = listIndent.end }
        let contentStartBeforeListMarker = cursor
        let listMarker = listMarker(in: line, at: cursor)
        if let listMarker {
            cursor = listMarker.end
            if cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                cursor = line.index(after: cursor)
            }
        }

        return MarkdownBlockStructure(
            contentStart: cursor,
            contentStartBeforeListMarker: contentStartBeforeListMarker,
            explicitQuoteDepth: quoteDepth == 0 ? nil : quoteDepth,
            listMarker: listMarker,
            isIndentedCodeCandidate: isIndentedCodeCandidate && quoteDepth == 0 && listMarker == nil
        )
    }

    private func leadingIndent(
        in line: String,
        from start: String.Index,
        limit: Int
    ) -> (end: String.Index, width: Int, sawTab: Bool) {
        var cursor = start
        var width = 0
        while cursor < line.endIndex, width <= limit {
            if line[cursor] == " " {
                width += 1
                cursor = line.index(after: cursor)
            } else if line[cursor] == "\t" {
                return (line.index(after: cursor), limit + 1, true)
            } else {
                break
            }
        }
        return (cursor, width, false)
    }

    private func listMarker(in line: String, at start: String.Index) -> MarkdownListMarker? {
        guard start < line.endIndex else { return nil }
        if line[start] == "-" || line[start] == "+" || line[start] == "*" {
            let end = line.index(after: start)
            guard end == line.endIndex || line[end] == " " || line[end] == "\t" else {
                return nil
            }
            return .init(
                end: end,
                canInterruptParagraph: hasNonblankListContent(in: line, after: end)
            )
        }

        var cursor = start
        var digitCount = 0
        while cursor < line.endIndex,
              digitCount < 9,
              isASCIIListDigit(line[cursor])
        {
            digitCount += 1
            cursor = line.index(after: cursor)
        }
        guard digitCount > 0,
              cursor < line.endIndex,
              line[cursor] == "." || line[cursor] == ")"
        else { return nil }
        let end = line.index(after: cursor)
        guard end == line.endIndex || line[end] == " " || line[end] == "\t" else { return nil }
        let startNumber = Int(line[start ..< cursor])
        return .init(
            end: end,
            canInterruptParagraph: startNumber == 1
                && hasNonblankListContent(in: line, after: end)
        )
    }

    private func hasNonblankListContent(in line: String, after markerEnd: String.Index) -> Bool {
        var cursor = markerEnd
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex
    }

    private func isASCIIListDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return (0x30...0x39).contains(scalar.value)
    }

    private func isATXHeading(_ content: Substring) -> Bool {
        var cursor = content.startIndex
        var indent = 0
        while cursor < content.endIndex, content[cursor] == " ", indent < 4 {
            indent += 1
            cursor = content.index(after: cursor)
        }
        guard indent <= 3 else { return false }
        var markerCount = 0
        while cursor < content.endIndex, content[cursor] == "#", markerCount < 7 {
            markerCount += 1
            cursor = content.index(after: cursor)
        }
        guard (1...6).contains(markerCount) else { return false }
        return cursor == content.endIndex || content[cursor] == " " || content[cursor] == "\t"
    }

    private func isSetextUnderline(_ content: Substring) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "=" || marker == "-" else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private func isThematicBreak(_ content: Substring) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "*" || marker == "-" || marker == "_" else {
            return false
        }
        var markerCount = 0
        for character in trimmed {
            if character == marker {
                markerCount += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return markerCount >= 3
    }

    private func footnoteDefinition(_ line: String) -> (id: String, body: String)? {
        guard line.hasPrefix("[^") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let after = line.index(after: close)
        guard after < line.endIndex, line[after] == ":" else { return nil }
        let idStart = line.index(line.startIndex, offsetBy: 2)
        let id = String(line[idStart ..< close])
        guard !id.isEmpty else { return nil }
        let bodyStart = line.index(after: after)
        return (id, String(line[bodyStart...]).trimmingCharacters(in: .whitespaces))
    }
}

private struct MarkdownFence {
    let marker: Character
    let length: Int
}

private struct CodeDelimiterPosition: Hashable {
    let line: Int
    let run: Int
}

private struct CodeDelimiterRun {
    let position: CodeDelimiterPosition
    let length: Int
    let isEscaped: Bool
}

private struct CodeSpanPlan {
    let openers: Set<CodeDelimiterPosition>
    let resetBeforeLines: Set<Int>
    let resetAfterLines: Set<Int>
}

private struct MarkdownBlockStructure {
    let contentStart: String.Index
    let contentStartBeforeListMarker: String.Index
    let explicitQuoteDepth: Int?
    let listMarker: MarkdownListMarker?
    let isIndentedCodeCandidate: Bool
}

private struct MarkdownListMarker {
    let end: String.Index
    let canInterruptParagraph: Bool
}
