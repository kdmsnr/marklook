import Foundation

struct CSSResourceRewriter: Sendable {
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

        guard let urlExpression = try? NSRegularExpression(
            pattern: #"(?is)url\(\s*(['\"]?)(.*?)\1\s*\)"#
        ) else { return output }
        let range = NSRange(output.startIndex..., in: output)
        for match in urlExpression.matches(in: output, range: range).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 2), in: output)
            else { continue }
            let raw = String(output[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = localResourceURL(
                raw,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            ).map { "url(\"\($0)\")" } ?? "url(\"\")"
            output.replaceSubrange(whole, with: replacement)
        }

        guard let importExpression = try? NSRegularExpression(
            pattern: #"(?is)@import\s+(['\"])(.*?)\1\s*([^;{}]*)(?:;|$)"#
        ) else { return output }
        let importRange = NSRange(output.startIndex..., in: output)
        for match in importExpression.matches(in: output, range: importRange).reversed() {
            guard let whole = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 2), in: output)
            else { continue }
            let raw = String(output[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let qualifier: String
            if match.numberOfRanges > 3,
               let qualifierRange = Range(match.range(at: 3), in: output)
            {
                qualifier = String(output[qualifierRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                qualifier = ""
            }
            let replacement = localResourceURL(
                raw,
                stylesheetURL: stylesheetURL,
                resourceAuthority: resourceAuthority
            ).map { "@import url(\"\($0)\")\(qualifier.isEmpty ? "" : " \(qualifier)");" } ?? ""
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    private func localResourceURL(
        _ raw: String,
        stylesheetURL: URL,
        resourceAuthority: String
    ) -> String? {
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
