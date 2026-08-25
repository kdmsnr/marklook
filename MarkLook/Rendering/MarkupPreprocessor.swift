import Foundation

struct MarkupPreprocessor: Sendable {
    struct MathReplacement: Sendable {
        let token: String
        let source: String
        let display: Bool
    }

    struct Footnote: Sendable {
        let id: String
        let source: String
    }

    struct Result: Sendable {
        let source: String
        let math: [MathReplacement]
        let footnotes: [Footnote]
        let footnoteReferenceTokens: [String: String]
    }

    func process(_ input: String) -> Result {
        let markers = scanMarkers(in: input)

        // Most documents do not use MarkLook extensions. Scan the UTF-8 bytes once so this path
        // can return the original copy-on-write String without normalizing or allocating storage.
        guard markers.hasCarriageReturn || markers.hasExtension else {
            return Result(
                source: input,
                math: [],
                footnotes: [],
                footnoteReferenceTokens: [:]
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

        guard markers.hasExtension else {
            return Result(
                source: normalized,
                math: [],
                footnotes: [],
                footnoteReferenceTokens: [:]
            )
        }

        let prefix = "MARKLOOK_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_"
        let extracted = extractFootnotes(from: normalized)
        let footnoteIDs = Set(extracted.footnotes.map(\.id))

        var math: [MathReplacement] = []
        var referenceTokens: [String: String] = [:]
        var output: [String] = []
        var inFence = false
        var fenceMarker = ""
        var blockMathLines: [String]? = nil

        for line in extracted.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceStart(in: trimmed) {
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                } else if trimmed.hasPrefix(fenceMarker) {
                    inFence = false
                    fenceMarker = ""
                }
                output.append(line)
                continue
            }

            if inFence {
                output.append(line)
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
                referenceTokens: &referenceTokens
            ))
        }

        if let unterminated = blockMathLines {
            output.append("$$" + unterminated.joined(separator: "\n"))
        }

        return Result(
            source: output.joined(separator: "\n"),
            math: math,
            footnotes: extracted.footnotes,
            footnoteReferenceTokens: referenceTokens
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

    private func fenceStart(in trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private func processInline(
        _ line: String,
        prefix: String,
        math: inout [MathReplacement],
        footnoteIDs: Set<String>,
        referenceTokens: inout [String: String]
    ) -> String {
        var result = ""
        var index = line.startIndex
        var codeDelimiterLength: Int?

        while index < line.endIndex {
            if line[index] == "`" {
                let run = characterRun(in: line, from: index, character: "`")
                result += String(line[index ..< run.end])
                if let delimiter = codeDelimiterLength {
                    if run.count == delimiter { codeDelimiterLength = nil }
                } else {
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

            if line[index] == "[", let reference = footnoteReference(in: line, from: index), footnoteIDs.contains(reference.id) {
                let token = "\(prefix)FOOTNOTE_\(referenceTokens.count)_TOKEN"
                referenceTokens[token] = reference.id
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
        var inFence = false
        var fenceMarker = ""

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceStart(in: trimmed) {
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                } else if trimmed.hasPrefix(fenceMarker) {
                    inFence = false
                    fenceMarker = ""
                }
                output.append(line)
                index += 1
                continue
            }

            if !inFence, let definition = footnoteDefinition(line) {
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

            output.append(line)
            index += 1
        }
        return (output.joined(separator: "\n"), footnotes)
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
