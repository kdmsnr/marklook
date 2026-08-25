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

/// Parses untrusted HTML as a static document, rewrites every local URL onto the
/// app-owned resource/navigation schemes, and finally applies SwiftSoup's maintained
/// allow-list cleaner. No document script is passed to WebKit.
struct HTMLSanitizer: Sendable {
    private let resourceScheme = "mark-resource"
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
                context: context,
                resources: &resources,
                warnings: &warnings
            )
            try element.html(HTMLEscaping.text(cleaned))
        }

        for element in try document.select("[style]") {
            let cleaned = sanitizeCSS(
                try element.attr("style"),
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
            for style in try head.select("style, link[rel=stylesheet]") {
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
        try whitelist.addProtocols("img", "src", resourceScheme)
        try whitelist.addProtocols("link", "href", resourceScheme)
        try whitelist.addProtocols("audio", "src", resourceScheme)
        try whitelist.addProtocols("video", "src", resourceScheme)
        try whitelist.addProtocols("video", "poster", resourceScheme)
        try whitelist.addProtocols("source", "src", resourceScheme)
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
        guard !value.isEmpty, !value.hasPrefix("//") else { return nil }
        if let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased(), scheme != "file" {
            return nil
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
        context: RenderContext,
        resources: inout Set<ResourceReference>,
        warnings: inout [RenderWarning]
    ) -> String {
        var output = css
        let removedRules = [
            "(?is)@import\\s+url\\([^;]+;?",
            "(?is)@import\\s+['\"][^;]+;?",
        ]
        for pattern in removedRules {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let removedDeclarations = [
            "(?is)(^|[;{])\\s*(?:-moz-binding|behavior|-webkit-user-modify|user-modify)\\s*:[^;}]*(?=;|\\}|\\z)",
            "(?is)(^|[;{])\\s*[-a-z0-9_]+\\s*:[^;{}]*\\bexpression\\s*\\([^;{}]*(?=;|\\}|\\z)",
        ]
        for pattern in removedDeclarations {
            output = output.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)url\(\s*(['\"]?)(.*?)\1\s*\)"#
        ) else { return output }
        let range = NSRange(output.startIndex..., in: output)
        for match in regex.matches(in: output, range: range).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 2), in: output)
            else { continue }
            let raw = String(output[valueRange])
            let replacement: String
            if let url = rewriteResource(raw, kind: .image, context: context, resources: &resources) {
                replacement = "url(\"\(url)\")"
            } else {
                replacement = "url(\"\")"
                warnings.append(.init(message: "Blocked non-local CSS resource: \(raw)"))
            }
            output.replaceSubrange(whole, with: replacement)
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
}
