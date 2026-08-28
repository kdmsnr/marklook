import Foundation

struct CSSResourceRewriter: Sendable {
    private struct Replacement {
        let range: Range<String.Index>
        let value: String
    }

    private struct ParsedString {
        let rawValue: String
        let endIndex: String.Index
    }

    func rewrite(
        _ css: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> String {
        var output = css
        let removedDeclarations = [
            #"(?is)(^|[;{])\s*(?:-moz-binding|behavior|-webkit-user-modify|user-modify)\s*:[^;}]*(?=;|\}|\z)"#,
            #"(?is)(^|[;{])\s*[-a-z0-9_]+\s*:[^;{}]*\bexpression\s*\([^;{}]*(?=;|\}|\z)"#,
        ]
        for pattern in removedDeclarations {
            output = output.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }

        let replacements = resourceReplacements(
            in: output,
            stylesheetURL: stylesheetURL,
            resourceAuthority: resourceAuthority
        )
        for replacement in replacements.reversed() {
            output.replaceSubrange(replacement.range, with: replacement.value)
        }
        return output
    }

    private func resourceReplacements(
        in css: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> [Replacement] {
        var replacements: [Replacement] = []
        var index = css.startIndex

        while index < css.endIndex {
            if startsComment(at: index, in: css) {
                index = endOfComment(startingAt: index, in: css)
                continue
            }
            if css[index] == "\"" || css[index] == "'" {
                index = endOfString(startingAt: index, in: css)
                continue
            }
            if let replacement = urlReplacement(
                at: index,
                in: css,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            ) {
                replacements.append(replacement)
                index = replacement.range.upperBound
                continue
            }
            if let replacement = importReplacement(
                at: index,
                in: css,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            ) {
                replacements.append(replacement)
                index = replacement.range.upperBound
                continue
            }
            index = css.index(after: index)
        }

        return replacements
    }

    private func urlReplacement(
        at startIndex: String.Index,
        in css: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> Replacement? {
        guard isTokenStart(at: startIndex, in: css),
              let keywordEnd = endOfASCIIKeyword("url", at: startIndex, in: css),
              keywordEnd < css.endIndex,
              css[keywordEnd] == "("
        else { return nil }

        var cursor = css.index(after: keywordEnd)
        cursor = skippingWhitespace(from: cursor, in: css)

        let rawValue: String
        let allowsLineContinuation: Bool
        if cursor < css.endIndex, css[cursor] == "\"" || css[cursor] == "'" {
            guard let parsed = parseString(startingAt: cursor, in: css) else { return nil }
            rawValue = parsed.rawValue
            allowsLineContinuation = true
            cursor = skippingWhitespace(from: parsed.endIndex, in: css)
            guard cursor < css.endIndex, css[cursor] == ")" else { return nil }
        } else {
            let valueStart = cursor
            var isValidUnquotedValue = true
            while cursor < css.endIndex, css[cursor] != ")" {
                let character = css[cursor]
                if character == "\\" {
                    let next = css.index(after: cursor)
                    guard next < css.endIndex else { return nil }
                    if isNewline(css[next]) {
                        isValidUnquotedValue = false
                    }
                    cursor = indexAfterEscape(startingAt: cursor, in: css)
                    continue
                }
                if character == "\"" || character == "'" || character == "(" {
                    isValidUnquotedValue = false
                } else if isCSSWhitespace(character) {
                    let afterWhitespace = skippingWhitespace(from: cursor, in: css)
                    if afterWhitespace >= css.endIndex || css[afterWhitespace] != ")" {
                        isValidUnquotedValue = false
                    }
                }
                cursor = css.index(after: cursor)
            }
            guard cursor < css.endIndex else { return nil }
            rawValue = String(css[valueStart..<cursor]).trimmingCharacters(
                in: CharacterSet(charactersIn: " \t\n\r\u{000C}")
            )
            allowsLineContinuation = false
            if !isValidUnquotedValue {
                return Replacement(
                    range: startIndex..<css.index(after: cursor),
                    value: "url(\"\")"
                )
            }
        }

        let wholeRange = startIndex..<css.index(after: cursor)
        let decodedValue = decodeCSSEscapes(
            rawValue,
            allowsLineContinuation: allowsLineContinuation
        )
        let value = decodedValue.flatMap {
            localResourceURL(
                $0,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            )
        }.map { "url(\"\($0)\")" } ?? "url(\"\")"
        return Replacement(range: wholeRange, value: value)
    }

    private func importReplacement(
        at startIndex: String.Index,
        in css: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> Replacement? {
        guard css[startIndex] == "@",
              let keywordStart = css.index(startIndex, offsetBy: 1, limitedBy: css.endIndex),
              let keywordEnd = endOfASCIIKeyword("import", at: keywordStart, in: css),
              keywordEnd == css.endIndex || !isCSSNameCharacter(css[keywordEnd])
        else { return nil }

        var cursor = skippingWhitespace(from: keywordEnd, in: css)
        guard cursor < css.endIndex,
              css[cursor] == "\"" || css[cursor] == "'",
              let parsed = parseString(startingAt: cursor, in: css)
        else { return nil }

        let qualifierStart = parsed.endIndex
        cursor = parsed.endIndex
        var nestingDepth = 0
        while cursor < css.endIndex {
            if startsComment(at: cursor, in: css) {
                cursor = endOfComment(startingAt: cursor, in: css)
                continue
            }
            if css[cursor] == "\"" || css[cursor] == "'" {
                cursor = endOfString(startingAt: cursor, in: css)
                continue
            }
            switch css[cursor] {
            case "(", "[":
                nestingDepth += 1
            case ")", "]":
                nestingDepth = max(0, nestingDepth - 1)
            case ";" where nestingDepth == 0:
                let qualifier = String(css[qualifierStart..<cursor]).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let endIndex = css.index(after: cursor)
                return makeImportReplacement(
                    range: startIndex..<endIndex,
                    rawValue: parsed.rawValue,
                    qualifier: qualifier,
                    stylesheetURL: stylesheetURL,
                    resourceAuthority: resourceAuthority
                )
            case "{" where nestingDepth == 0, "}" where nestingDepth == 0:
                let qualifier = String(css[qualifierStart..<cursor]).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return makeImportReplacement(
                    range: startIndex..<cursor,
                    rawValue: parsed.rawValue,
                    qualifier: qualifier,
                    stylesheetURL: stylesheetURL,
                    resourceAuthority: resourceAuthority
                )
            default:
                break
            }
            cursor = css.index(after: cursor)
        }

        let qualifier = String(css[qualifierStart..<cursor]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return makeImportReplacement(
            range: startIndex..<cursor,
            rawValue: parsed.rawValue,
            qualifier: qualifier,
            stylesheetURL: stylesheetURL,
            resourceAuthority: resourceAuthority
        )
    }

    private func makeImportReplacement(
        range: Range<String.Index>,
        rawValue: String,
        qualifier: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> Replacement {
        let value = decodeCSSEscapes(rawValue, allowsLineContinuation: true).flatMap {
            localResourceURL(
                $0,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            )
        }.map {
            "@import url(\"\($0)\")\(qualifier.isEmpty ? "" : " \(qualifier)");"
        } ?? ""
        return Replacement(range: range, value: value)
    }

    private func parseString(startingAt quoteIndex: String.Index, in css: String) -> ParsedString? {
        let quote = css[quoteIndex]
        let valueStart = css.index(after: quoteIndex)
        var cursor = valueStart
        while cursor < css.endIndex {
            if css[cursor] == quote {
                return ParsedString(
                    rawValue: String(css[valueStart..<cursor]),
                    endIndex: css.index(after: cursor)
                )
            }
            if isNewline(css[cursor]) {
                return nil
            }
            if css[cursor] == "\\" {
                cursor = indexAfterEscape(startingAt: cursor, in: css)
            } else {
                cursor = css.index(after: cursor)
            }
        }
        return nil
    }

    private func endOfString(startingAt quoteIndex: String.Index, in css: String) -> String.Index {
        let quote = css[quoteIndex]
        var cursor = css.index(after: quoteIndex)
        while cursor < css.endIndex {
            if css[cursor] == quote {
                return css.index(after: cursor)
            }
            if isNewline(css[cursor]) {
                return css.index(after: cursor)
            }
            if css[cursor] == "\\" {
                cursor = indexAfterEscape(startingAt: cursor, in: css)
            } else {
                cursor = css.index(after: cursor)
            }
        }
        return css.endIndex
    }

    private func startsComment(at index: String.Index, in css: String) -> Bool {
        guard css[index] == "/" else { return false }
        let next = css.index(after: index)
        return next < css.endIndex && css[next] == "*"
    }

    private func endOfComment(startingAt startIndex: String.Index, in css: String) -> String.Index {
        var cursor = css.index(startIndex, offsetBy: 2)
        while cursor < css.endIndex {
            if css[cursor] == "*" {
                let next = css.index(after: cursor)
                if next < css.endIndex, css[next] == "/" {
                    return css.index(after: next)
                }
            }
            cursor = css.index(after: cursor)
        }
        return css.endIndex
    }

    private func indexAfterEscape(startingAt backslashIndex: String.Index, in css: String) -> String.Index {
        var cursor = css.index(after: backslashIndex)
        guard cursor < css.endIndex else { return css.endIndex }
        if css[cursor] == "\r" {
            cursor = css.index(after: cursor)
            if cursor < css.endIndex, css[cursor] == "\n" {
                cursor = css.index(after: cursor)
            }
            return cursor
        }

        var hexDigitCount = 0
        while cursor < css.endIndex,
              hexDigitCount < 6,
              isHexDigit(css[cursor])
        {
            hexDigitCount += 1
            cursor = css.index(after: cursor)
        }
        if hexDigitCount > 0 {
            if cursor < css.endIndex, isCSSWhitespace(css[cursor]) {
                cursor = css.index(after: cursor)
            }
            return cursor
        }
        return css.index(after: cursor)
    }

    private func skippingWhitespace(from startIndex: String.Index, in css: String) -> String.Index {
        var cursor = startIndex
        while cursor < css.endIndex, isCSSWhitespace(css[cursor]) {
            cursor = css.index(after: cursor)
        }
        return cursor
    }

    private func isTokenStart(at index: String.Index, in css: String) -> Bool {
        guard index > css.startIndex else { return true }
        let previous = css[css.index(before: index)]
        return previous != "\\" && !isCSSNameCharacter(previous)
    }

    private func endOfASCIIKeyword(
        _ keyword: String,
        at startIndex: String.Index,
        in css: String
    ) -> String.Index? {
        var cursor = startIndex
        for expectedCharacter in keyword {
            guard cursor < css.endIndex,
                  String(css[cursor]).lowercased() == String(expectedCharacter)
            else { return nil }
            cursor = css.index(after: cursor)
        }
        return cursor
    }

    private func isCSSNameCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2D, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A, 0x80...:
                true
            default:
                false
            }
        }
    }

    private func isCSSWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
            || character == "\r" || character == "\u{000C}"
    }

    private func isHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return isHexDigit(scalar)
    }

    private func isNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\u{000C}"
    }

    private func decodeCSSEscapes(
        _ value: String,
        allowsLineContinuation: Bool
    ) -> String? {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == "\\" else {
                result.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
                continue
            }

            index = scalars.index(after: index)
            guard index < scalars.endIndex else { return nil }
            if scalars[index] == "\n" || scalars[index] == "\r" || scalars[index] == "\u{000C}" {
                guard allowsLineContinuation else { return nil }
                if scalars[index] == "\r" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\n" {
                        index = next
                    }
                }
                index = scalars.index(after: index)
                continue
            }

            if isHexDigit(scalars[index]) {
                var value: UInt32 = 0
                var digitCount = 0
                while index < scalars.endIndex,
                      digitCount < 6,
                      let digit = hexValue(scalars[index])
                {
                    value = value * 16 + digit
                    digitCount += 1
                    index = scalars.index(after: index)
                }
                if index < scalars.endIndex, isCSSWhitespace(scalars[index]) {
                    if scalars[index] == "\r" {
                        let next = scalars.index(after: index)
                        if next < scalars.endIndex, scalars[next] == "\n" {
                            index = next
                        }
                    }
                    index = scalars.index(after: index)
                }
                if value == 0 || value > 0x10_FFFF || (0xD800...0xDFFF).contains(value) {
                    result.unicodeScalars.append("\u{FFFD}")
                } else if let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
                continue
            }

            result.unicodeScalars.append(scalars[index])
            index = scalars.index(after: index)
        }
        return result
    }

    private func isCSSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }

    private func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39:
            scalar.value - 0x30
        case 0x41...0x46:
            scalar.value - 0x41 + 10
        case 0x61...0x66:
            scalar.value - 0x61 + 10
        default:
            nil
        }
    }

    private func localResourceURL(
        _ raw: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> String? {
        if stylesheetURL.scheme?.lowercased() == "https" {
            return remoteResourceURL(
                raw,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            )
        }

        guard !raw.isEmpty,
              !raw.hasPrefix("//"),
              hasValidPercentEncoding(raw),
              let parsed = URLComponents(string: raw),
              parsed.scheme == nil || parsed.scheme?.lowercased() == "file",
              parsed.host == nil || parsed.host?.isEmpty == true
                || parsed.host?.lowercased() == "localhost",
              let decodedPath = parsed.percentEncodedPath.removingPercentEncoding,
              !decodedPath.isEmpty,
              !decodedPath.contains("\0")
        else { return nil }

        let absolutePath: String
        if decodedPath.hasPrefix("/") {
            absolutePath = decodedPath
        } else {
            let basePath = stylesheetURL.deletingLastPathComponent().path
            absolutePath = basePath == "/" ? "/" + decodedPath : basePath + "/" + decodedPath
        }
        // Keep symlinks and `..` in their original order. LocalPathValidator will resolve them
        // with realpath(3); lexical standardization here could change POSIX path semantics.
        let absolute = URL(fileURLWithPath: absolutePath)
        var components = URLComponents()
        components.scheme = "mark-resource"
        components.host = resourceAuthority
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "source", value: absolute.absoluteString)]
        return components.url?.absoluteString
    }

    private func remoteResourceURL(
        _ raw: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> String? {
        guard !raw.isEmpty, hasValidPercentEncoding(raw) else { return nil }
        if raw.hasPrefix("#") { return raw }
        guard let resolved = URL(string: raw, relativeTo: stylesheetURL)?.absoluteURL,
              resolved.scheme?.lowercased() == "https",
              resolved.host != nil,
              resolved.user == nil,
              resolved.password == nil,
              resolved.port == nil || resolved.port == 443,
              let rewritten = RemoteResourceURL.make(
                  sourceURL: resolved,
                  authority: resourceAuthority
              )
        else { return nil }
        return rewritten.absoluteString
    }

    private func hasValidPercentEncoding(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == "%" else {
                index = scalars.index(after: index)
                continue
            }
            let first = scalars.index(after: index)
            guard first < scalars.endIndex else { return false }
            let second = scalars.index(after: first)
            guard second < scalars.endIndex,
                  isHexDigit(scalars[first]),
                  isHexDigit(scalars[second]) else { return false }
            index = scalars.index(after: second)
        }
        return true
    }

    private func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            true
        default:
            false
        }
    }
}
