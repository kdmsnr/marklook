import Foundation
import SwiftSoup

struct SanitizedHTML: Sendable {
    let fragment: String
    let title: String?
    let resources: Set<ResourceReference>
    let warnings: [RenderWarning]
    let timing: HTMLSanitizerTiming
}

struct HTMLSanitizerTiming: Sendable, Equatable {
    let parsing: Duration
    let transforming: Duration
    let cleaning: Duration
    let serializing: Duration
}

/// Parses untrusted HTML as a static document, rewrites every permitted URL onto the
/// app-owned resource/navigation schemes, and finally applies SwiftSoup's maintained
/// allow-list cleaner. No document script is passed to WebKit.
struct HTMLSanitizer: Sendable {
    private let resourceScheme = "mark-resource"
    private let remoteResourceScheme = RemoteResourceURL.scheme
    private let navigationScheme = "mark-navigation"

    func sanitize(_ input: String, context: RenderContext) throws -> SanitizedHTML {
        let clock = ContinuousClock()
        // URL resolution is intentionally performed below using the explicit document context.
        // Giving an untrusted DOM a base URL causes some sanitizer implementations to turn
        // `#fragment` into an absolute file URL before protocol validation.
        let parsingStartedAt = clock.now
        let document = try SwiftSoup.parse(input, "")
        let parsing = parsingStartedAt.duration(to: clock.now)

        let transformingStartedAt = clock.now
        let title = try document.title().nilIfEmpty
        var resources = Set<ResourceReference>()
        var warnings: [RenderWarning] = []

        try document.select("script, iframe, object, embed, base, meta[http-equiv=refresh]").remove()
        try document.select("form").forEach { try $0.unwrap() }
        try document.select("button, textarea, select, option").remove()

        for element in try document.select("style") {
            let cleaned = sanitizeCSS(
                element.data(),
                isStyleSheet: true,
                context: context,
                resources: &resources,
                warnings: &warnings
            )
            try element.html(HTMLEscaping.text(cleaned))
        }

        for element in try document.select("[style]") {
            let cleaned = sanitizeCSS(
                try element.attr("style"),
                isStyleSheet: false,
                context: context,
                resources: &resources,
                warnings: &warnings
            )
            if cleaned.isEmpty {
                try element.removeAttr("style")
            } else {
                try element.attr("style", cleaned)
            }
        }

        try rewriteLinks(in: document, context: context, resources: &resources, warnings: &warnings)

        // Move the limited, sanitized stylesheet subset into the fragment so it is scoped by
        // the viewer's ShadowRoot rather than mutating the host page.
        if let head = document.head(), let body = document.body() {
            // `prependChild` inserts at index zero. Walk the source nodes backwards so their
            // cascade order remains identical after moving them into the body.
            for style in Array(try head.select("style, link[rel=stylesheet]")).reversed() {
                try body.prependChild(style)
            }
        }
        let transforming = transformingStartedAt.duration(to: clock.now)

        let cleaningStartedAt = clock.now
        let whitelist = try makeWhitelist()
        let cleaner = Cleaner(headWhitelist: nil, bodyWhitelist: whitelist)
        let cleaned = try cleaner.clean(document)
        try enforceStaticInputs(in: cleaned)
        let cleaning = cleaningStartedAt.duration(to: clock.now)

        let serializingStartedAt = clock.now
        let fragment = try cleaned.body()?.html() ?? ""
        let serializing = serializingStartedAt.duration(to: clock.now)

        return SanitizedHTML(
            fragment: fragment,
            title: title,
            resources: resources,
            warnings: warnings,
            timing: HTMLSanitizerTiming(
                parsing: parsing,
                transforming: transforming,
                cleaning: cleaning,
                serializing: serializing
            )
        )
    }

    private func makeWhitelist() throws -> Whitelist {
        let whitelist = Whitelist.none()
        try whitelist.addTags(
            "a", "abbr", "article", "aside", "b", "blockquote", "br", "caption", "cite",
            "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt",
            "em", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
            "header", "hr", "i", "img", "input", "kbd", "li", "link", "main", "mark", "nav",
            "ol", "p", "pre", "q", "s", "samp", "section", "small", "span", "strike", "strong",
            "style", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead",
            "time", "tr", "u", "ul", "var", "video", "audio", "source"
        )
        try whitelist.addAttributes(":all", "class", "id", "lang", "dir", "title", "style", "role")
        try whitelist.addAttributes(
            ":all",
            "aria-label", "aria-labelledby", "aria-describedby", "aria-hidden",
            "data-marklook-anchor", "data-marklook-math", "data-display"
        )
        try whitelist.addAttributes("a", "href", "rel")
        try whitelist.addAttributes("blockquote", "cite")
        try whitelist.addAttributes("div", "data-callout")
        try whitelist.addAttributes("details", "data-callout", "open")
        try whitelist.addAttributes("img", "src", "alt", "width", "height", "loading", "decoding")
        try whitelist.addAttributes("link", "rel", "href", "media")
        try whitelist.addAttributes("input", "type", "checked", "disabled")
        try whitelist.addAttributes("ol", "start", "reversed", "type")
        try whitelist.addAttributes("col", "span", "width")
        try whitelist.addAttributes("colgroup", "span", "width")
        try whitelist.addAttributes("td", "colspan", "rowspan", "headers", "align")
        try whitelist.addAttributes("th", "colspan", "rowspan", "headers", "scope", "align")
        try whitelist.addAttributes("audio", "src", "controls", "preload")
        try whitelist.addAttributes("video", "src", "poster", "controls", "preload", "width", "height")
        try whitelist.addAttributes("source", "src", "type", "media")
        try whitelist.addProtocols("a", "href", "http", "https", "#", navigationScheme)
        try whitelist.addProtocols("blockquote", "cite", "http", "https")
        try whitelist.addProtocols("img", "src", resourceScheme, remoteResourceScheme)
        try whitelist.addProtocols("link", "href", resourceScheme, remoteResourceScheme)
        try whitelist.addProtocols("audio", "src", resourceScheme, remoteResourceScheme)
        try whitelist.addProtocols("video", "src", resourceScheme, remoteResourceScheme)
        try whitelist.addProtocols("video", "poster", resourceScheme, remoteResourceScheme)
        try whitelist.addProtocols("source", "src", resourceScheme, remoteResourceScheme)
        whitelist.preserveRelativeLinks(true)
        return whitelist
    }

    private func rewriteLinks(
        in document: SwiftSoup.Document,
        context: RenderContext,
        resources: inout Set<ResourceReference>,
        warnings: inout [RenderWarning]
    ) throws {
        // Discard non-stylesheet links before collecting resource references. This prevents
        // icons, preload hints, and other non-rendered links from triggering access prompts.
        for link in try document.select("link") {
            let relationship = try link.attr("rel")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard relationship == "stylesheet" else {
                try link.remove()
                continue
            }
        }

        for anchor in try document.select("a[href]") {
            let raw = try anchor.attr("href")
            if let rewritten = rewriteNavigation(raw, context: context) {
                try anchor.attr("href", rewritten)
                try anchor.attr("rel", "noopener noreferrer")
            } else {
                try anchor.removeAttr("href")
            }
        }

        try rewriteResourceAttribute(
            selector: "img[src]", attribute: "src", kind: .image,
            document: document, context: context, resources: &resources, warnings: &warnings
        )
        try rewriteResourceAttribute(
            selector: "link[href]", attribute: "href", kind: .stylesheet,
            document: document, context: context, resources: &resources, warnings: &warnings
        )
        try rewriteResourceAttribute(
            selector: "audio[src], video[src], source[src]", attribute: "src", kind: .media,
            document: document, context: context, resources: &resources, warnings: &warnings
        )
        try rewriteResourceAttribute(
            selector: "video[poster]", attribute: "poster", kind: .image,
            document: document, context: context, resources: &resources, warnings: &warnings
        )

        try document.select("[srcset]").forEach { try $0.removeAttr("srcset") }
    }

    private func rewriteResourceAttribute(
        selector: String,
        attribute: String,
        kind: ResourceKind,
        document: SwiftSoup.Document,
        context: RenderContext,
        resources: inout Set<ResourceReference>,
        warnings: inout [RenderWarning]
    ) throws {
        for element in try document.select(selector) {
            let raw = try element.attr(attribute)
            guard let rewritten = rewriteResource(raw, kind: kind, context: context, resources: &resources) else {
                try element.removeAttr(attribute)
                if !raw.isEmpty {
                    warnings.append(.init(message: "Blocked non-local \(kind.rawValue): \(raw)"))
                }
                continue
            }
            try element.attr(attribute, rewritten)
            if element.tagName() == "img" {
                try element.attr("loading", "eager")
                try element.attr("decoding", "async")
            }
        }
    }

    /// Shared with `SecureHTMLFormatter` so Markdown generated solely from typed AST nodes can
    /// validate destinations before emitting attributes, without reparsing the whole document.
    func rewriteNavigation(_ raw: String, context: RenderContext) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("#") { return value }
        if let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return parsed.absoluteString }
            if scheme != "file" { return nil }
        }
        return ownedSchemeURL(scheme: navigationScheme, authority: context.resourceAuthority, source: value)
    }

    /// Shared with `SecureHTMLFormatter`; callers must keep the returned reference set alongside
    /// the rewritten URL so sandbox permission checks and dependency watching remain identical.
    func rewriteResource(
        _ raw: String,
        kind: ResourceKind,
        context: RenderContext,
        resources: inout Set<ResourceReference>
    ) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let schemeRelativeRemoteURL = value.hasPrefix("//")
            ? URL(string: "https:\(value)")
            : nil
        let parsedURL = URL(string: value)
        let explicitRemoteURL = parsedURL.flatMap { parsed -> URL? in
            guard let scheme = parsed.scheme?.lowercased(), scheme != "file" else { return nil }
            return parsed
        }
        if let remoteURL = schemeRelativeRemoteURL ?? explicitRemoteURL {
            guard context.remoteContentPolicy.allows(remoteURL),
                  let rewritten = RemoteResourceURL.make(
                      sourceURL: remoteURL,
                      authority: context.resourceAuthority
                  )
            else { return nil }
            resources.insert(.init(source: remoteURL.absoluteString, resolvedURL: nil, kind: kind))
            return rewritten.absoluteString
        }
        let resolved = resolveLocal(value, relativeTo: context.documentURL)
        guard let rewritten = ownedSchemeURL(
            scheme: resourceScheme,
            authority: context.resourceAuthority,
            source: value
        ) else { return nil }
        resources.insert(.init(source: value, resolvedURL: resolved, kind: kind))
        return rewritten
    }

    private func ownedSchemeURL(scheme: String, authority: String, source: String) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = authority
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "source", value: source)]
        return components.url?.absoluteString
    }

    private func resolveLocal(_ source: String, relativeTo documentURL: URL) -> URL? {
        guard hasValidPercentEncoding(source),
              let components = URLComponents(string: source),
              components.scheme == nil || components.scheme?.lowercased() == "file",
              components.host == nil || components.host?.isEmpty == true
                || components.host?.lowercased() == "localhost",
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              !decodedPath.isEmpty,
              !decodedPath.contains("\0")
        else { return nil }

        let unresolvedPath: String
        if decodedPath.hasPrefix("/") {
            unresolvedPath = decodedPath
        } else {
            let basePath = documentURL.deletingLastPathComponent().path
            unresolvedPath = basePath == "/" ? "/" + decodedPath : basePath + "/" + decodedPath
        }
        return URL(fileURLWithPath: unresolvedPath).resolvingSymlinksInPath().standardizedFileURL
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
                  scalars[first].isHTMLPercentHexDigit,
                  scalars[second].isHTMLPercentHexDigit else { return false }
            index = scalars.index(after: second)
        }
        return true
    }

    private func sanitizeCSS(
        _ css: String,
        isStyleSheet: Bool,
        context: RenderContext,
        resources: inout Set<ResourceReference>,
        warnings: inout [RenderWarning]
    ) -> String {
        var output = isStyleSheet ? removingCSSImportRules(from: css) : css
        let removedDeclarations = [
            "(?is)(^|[;{])\\s*(?:-moz-binding|behavior|-webkit-user-modify|user-modify)\\s*:[^;}]*(?=;|\\}|\\z)",
            "(?is)(^|[;{])\\s*[-a-z0-9_]+\\s*:[^;{}]*\\bexpression\\s*\\([^;{}]*(?=;|\\}|\\z)",
        ]
        for pattern in removedDeclarations {
            output = output.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }

        for match in cssURLMatches(in: output).reversed() {
            let raw = decodeCSSEscapes(match.value)
            let replacement: String
            if let url = rewriteResource(raw, kind: .image, context: context, resources: &resources) {
                replacement = "url(\"\(url)\")"
            } else {
                replacement = "url(\"\")"
                warnings.append(.init(message: "Blocked non-local CSS resource: \(raw)"))
            }
            output.replaceSubrange(match.range, with: replacement)
        }
        return output
    }

    /// Removes actual CSS `@import` at-rules without interpreting matching prose inside comments
    /// or strings. The prelude may contain quoted strings, comments, and nested functions such as
    /// `supports(...)`; only a top-level semicolon (or the end of an invalid rule) terminates it.
    private func removingCSSImportRules(from css: String) -> String {
        var ranges: [Range<String.Index>] = []
        var cursor = css.startIndex
        var braceDepth = 0
        var parenthesisDepth = 0
        var bracketDepth = 0
        var isAtRuleStart = true

        while cursor < css.endIndex {
            if isAtRuleStart,
               braceDepth == 0,
               parenthesisDepth == 0,
               bracketDepth == 0
            {
                let remaining = css[cursor...]
                if remaining.hasPrefix("<!--") {
                    cursor = css.index(cursor, offsetBy: 4)
                    continue
                }
                if remaining.hasPrefix("-->") {
                    cursor = css.index(cursor, offsetBy: 3)
                    continue
                }
            }
            if css[cursor] == "/",
               let next = css.index(cursor, offsetBy: 1, limitedBy: css.endIndex),
               next < css.endIndex,
               css[next] == "*"
            {
                cursor = endOfCSSComment(in: css, after: css.index(after: next))
                continue
            }
            if css[cursor] == "\"" || css[cursor] == "'" {
                if braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0 {
                    isAtRuleStart = false
                }
                cursor = endOfCSSString(in: css, startingAt: cursor)
                continue
            }
            if css[cursor] == "\\" {
                if braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0 {
                    isAtRuleStart = false
                }
                cursor = indexAfterCSSIdentifierEscape(in: css, at: cursor)
                continue
            }

            switch css[cursor] {
            case "{":
                braceDepth += 1
                isAtRuleStart = false
            case "}":
                braceDepth = max(0, braceDepth - 1)
                if braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0 {
                    isAtRuleStart = true
                }
            case "(":
                if braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0 {
                    isAtRuleStart = false
                }
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                if braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0 {
                    isAtRuleStart = false
                }
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case ";" where braceDepth == 0 && parenthesisDepth == 0 && bracketDepth == 0:
                isAtRuleStart = true
            case "@" where isAtRuleStart
                && braceDepth == 0
                && parenthesisDepth == 0
                && bracketDepth == 0:
                if let keywordEnd = cssImportKeywordEnd(in: css, at: cursor) {
                    let ruleEnd = cssImportRuleEnd(in: css, after: keywordEnd)
                    ranges.append(cursor ..< ruleEnd)
                    cursor = ruleEnd
                    continue
                }
                isAtRuleStart = false
            default:
                if braceDepth == 0,
                   parenthesisDepth == 0,
                   bracketDepth == 0,
                   !css[cursor].isWhitespace
                {
                    isAtRuleStart = false
                }
                break
            }

            cursor = css.index(after: cursor)
        }

        var output = css
        for range in ranges.reversed() {
            output.removeSubrange(range)
        }
        return output
    }

    private func cssImportKeywordEnd(
        in css: String,
        at atSign: String.Index
    ) -> String.Index? {
        var cursor = css.index(after: atSign)
        let nameStart = cursor
        while cursor < css.endIndex {
            if css[cursor] == "\\" {
                cursor = indexAfterCSSIdentifierEscape(in: css, at: cursor)
            } else if isCSSIdentifierCharacter(css[cursor]) {
                cursor = css.index(after: cursor)
            } else {
                break
            }
        }
        guard cursor > nameStart else { return nil }
        let rawName = String(css[nameStart ..< cursor])
        return decodeCSSEscapes(rawName).lowercased() == "import" ? cursor : nil
    }

    private func cssImportRuleEnd(
        in css: String,
        after keywordEnd: String.Index
    ) -> String.Index {
        var cursor = keywordEnd
        var nestingDepth = 0

        while cursor < css.endIndex {
            if css[cursor] == "/",
               let next = css.index(cursor, offsetBy: 1, limitedBy: css.endIndex),
               next < css.endIndex,
               css[next] == "*"
            {
                cursor = endOfCSSComment(in: css, after: css.index(after: next))
                continue
            }
            if css[cursor] == "\"" || css[cursor] == "'" {
                cursor = endOfCSSString(in: css, startingAt: cursor)
                continue
            }
            if css[cursor] == "\\" {
                cursor = indexAfterCSSIdentifierEscape(in: css, at: cursor)
                continue
            }

            switch css[cursor] {
            case "(", "[":
                nestingDepth += 1
            case ")", "]":
                nestingDepth = max(0, nestingDepth - 1)
            case ";" where nestingDepth == 0:
                return css.index(after: cursor)
            case "{", "}":
                if nestingDepth == 0 { return cursor }
            default:
                break
            }
            cursor = css.index(after: cursor)
        }
        return css.endIndex
    }

    private func indexAfterCSSIdentifierEscape(
        in css: String,
        at backslash: String.Index
    ) -> String.Index {
        var cursor = css.index(after: backslash)
        guard cursor < css.endIndex else { return css.endIndex }

        var hexDigitCount = 0
        while cursor < css.endIndex,
              hexDigitCount < 6,
              css[cursor].unicodeScalars.count == 1,
              css[cursor].unicodeScalars.first?.isHTMLPercentHexDigit == true
        {
            hexDigitCount += 1
            cursor = css.index(after: cursor)
        }
        if hexDigitCount > 0 {
            if cursor < css.endIndex,
               css[cursor].unicodeScalars.count == 1,
               css[cursor].unicodeScalars.first?.isCSSWhitespace == true
            {
                cursor = css.index(after: cursor)
            }
            return cursor
        }
        return css.index(after: cursor)
    }

    /// Finds actual CSS `url()` tokens while leaving comments and quoted string contents alone.
    /// This is intentionally a small lexical scanner rather than a declaration parser: callers
    /// still preserve the document's CSS, but resource-looking prose must not create dependencies.
    private func cssURLMatches(in css: String) -> [CSSURLMatch] {
        var matches: [CSSURLMatch] = []
        var cursor = css.startIndex

        while cursor < css.endIndex {
            if css[cursor] == "/",
               let next = css.index(cursor, offsetBy: 1, limitedBy: css.endIndex),
               next < css.endIndex,
               css[next] == "*"
            {
                cursor = endOfCSSComment(in: css, after: css.index(after: next))
                continue
            }

            if css[cursor] == "\"" || css[cursor] == "'" {
                cursor = endOfCSSString(in: css, startingAt: cursor)
                continue
            }

            guard isCSSURLFunction(in: css, at: cursor) else {
                cursor = css.index(after: cursor)
                continue
            }

            let functionStart = cursor
            var position = css.index(cursor, offsetBy: 3)
            while position < css.endIndex, css[position].isWhitespace {
                position = css.index(after: position)
            }
            guard position < css.endIndex, css[position] == "(" else {
                cursor = css.index(after: cursor)
                continue
            }

            position = css.index(after: position)
            while position < css.endIndex, css[position].isWhitespace {
                position = css.index(after: position)
            }

            let valueStart: String.Index
            let valueEnd: String.Index
            let closingParenthesis: String.Index
            if position < css.endIndex, (css[position] == "\"" || css[position] == "'") {
                let quote = css[position]
                valueStart = css.index(after: position)
                var valueCursor = valueStart
                var foundQuote: String.Index?
                while valueCursor < css.endIndex {
                    if css[valueCursor] == "\\" {
                        valueCursor = indexAfterCSSEscape(in: css, at: valueCursor)
                    } else if css[valueCursor] == quote {
                        foundQuote = valueCursor
                        break
                    } else {
                        valueCursor = css.index(after: valueCursor)
                    }
                }
                guard let quoteEnd = foundQuote else {
                    cursor = css.index(after: cursor)
                    continue
                }
                valueEnd = quoteEnd
                var afterQuote = css.index(after: quoteEnd)
                while afterQuote < css.endIndex, css[afterQuote].isWhitespace {
                    afterQuote = css.index(after: afterQuote)
                }
                guard afterQuote < css.endIndex, css[afterQuote] == ")" else {
                    cursor = css.index(after: cursor)
                    continue
                }
                closingParenthesis = afterQuote
            } else {
                valueStart = position
                var valueCursor = position
                var foundParenthesis: String.Index?
                while valueCursor < css.endIndex {
                    if css[valueCursor] == "\\" {
                        valueCursor = indexAfterCSSEscape(in: css, at: valueCursor)
                    } else if css[valueCursor] == ")" {
                        foundParenthesis = valueCursor
                        break
                    } else if css[valueCursor] == "\"" || css[valueCursor] == "'" {
                        break
                    } else {
                        valueCursor = css.index(after: valueCursor)
                    }
                }
                guard let parenthesis = foundParenthesis else {
                    cursor = css.index(after: cursor)
                    continue
                }
                var trimmedEnd = parenthesis
                while trimmedEnd > valueStart {
                    let previous = css.index(before: trimmedEnd)
                    guard css[previous].isWhitespace else { break }
                    trimmedEnd = previous
                }
                valueEnd = trimmedEnd
                closingParenthesis = parenthesis
            }

            let matchEnd = css.index(after: closingParenthesis)
            matches.append(.init(
                range: functionStart ..< matchEnd,
                value: String(css[valueStart ..< valueEnd])
            ))
            cursor = matchEnd
        }
        return matches
    }

    private func isCSSURLFunction(in css: String, at start: String.Index) -> Bool {
        if start > css.startIndex,
           isCSSIdentifierCharacter(css[css.index(before: start)])
        {
            return false
        }
        guard let end = css.index(start, offsetBy: 3, limitedBy: css.endIndex),
              String(css[start ..< end]).lowercased() == "url"
        else { return false }
        return end == css.endIndex || !isCSSIdentifierCharacter(css[end])
    }

    private func isCSSIdentifierCharacter(_ character: Character) -> Bool {
        character == "-" || character == "_" || character == "\\"
            || character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private func endOfCSSComment(in css: String, after start: String.Index) -> String.Index {
        var cursor = start
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

    private func endOfCSSString(in css: String, startingAt quoteStart: String.Index) -> String.Index {
        let quote = css[quoteStart]
        var cursor = css.index(after: quoteStart)
        while cursor < css.endIndex {
            if css[cursor] == "\\" {
                cursor = indexAfterCSSEscape(in: css, at: cursor)
            } else if css[cursor] == quote {
                return css.index(after: cursor)
            } else {
                cursor = css.index(after: cursor)
            }
        }
        return css.endIndex
    }

    private func indexAfterCSSEscape(in css: String, at backslash: String.Index) -> String.Index {
        let escaped = css.index(after: backslash)
        guard escaped < css.endIndex else { return css.endIndex }
        return css.index(after: escaped)
    }

    private func decodeCSSEscapes(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var output = ""
        output.reserveCapacity(value.utf8.count)
        var index = scalars.startIndex

        while index < scalars.endIndex {
            guard scalars[index].value == 0x5C else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            let escapedIndex = index + 1
            guard escapedIndex < scalars.endIndex else {
                output.append("\\")
                break
            }
            let escaped = scalars[escapedIndex]
            if escaped.value == 0x0A || escaped.value == 0x0C {
                index += 2
                continue
            }
            if escaped.value == 0x0D {
                index += escapedIndex + 1 < scalars.endIndex
                    && scalars[escapedIndex + 1].value == 0x0A ? 3 : 2
                continue
            }

            guard escaped.isHTMLPercentHexDigit else {
                output.unicodeScalars.append(escaped)
                index += 2
                continue
            }

            var hexEnd = escapedIndex
            while hexEnd < scalars.endIndex,
                  hexEnd - escapedIndex < 6,
                  scalars[hexEnd].isHTMLPercentHexDigit
            {
                hexEnd += 1
            }
            let hex = String(String.UnicodeScalarView(scalars[escapedIndex ..< hexEnd]))
            let value = UInt32(hex, radix: 16) ?? 0
            if value == 0 || value > 0x10_FFFF || (0xD800...0xDFFF).contains(value) {
                output.unicodeScalars.append("\u{FFFD}")
            } else if let scalar = Unicode.Scalar(value) {
                output.unicodeScalars.append(scalar)
            }
            if hexEnd < scalars.endIndex, scalars[hexEnd].isCSSWhitespace {
                hexEnd += 1
            }
            index = hexEnd
        }
        return output
    }

    private func enforceStaticInputs(in document: SwiftSoup.Document) throws {
        for input in try document.select("input") {
            guard (try input.attr("type")).lowercased() == "checkbox" else {
                try input.remove()
                continue
            }
            try input.attr("disabled", "")
        }
    }
}

private struct CSSURLMatch {
    let range: Range<String.Index>
    let value: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Unicode.Scalar {
    var isHTMLPercentHexDigit: Bool {
        switch value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            true
        default:
            false
        }
    }

    var isCSSWhitespace: Bool {
        switch value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            true
        default:
            false
        }
    }
}
