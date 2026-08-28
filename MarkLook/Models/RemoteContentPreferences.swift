import Foundation

enum RemoteContentPreferences {
    static let allowedHostsKey = "RemoteContentAllowedHosts.v1"
    static let defaultStoredValue = ""

    static func allowedHosts(storedValue: String) -> Set<String> {
        Set(
            storedValue
                .split(whereSeparator: { $0.isNewline || $0 == "," })
                .compactMap { normalizedHost(String($0)) }
        )
    }

    static func storedValue(for allowedHosts: Set<String>) -> String {
        Set(allowedHosts.compactMap(normalizedHost))
            .sorted()
            .joined(separator: "\n")
    }

    static func normalizedHost(_ candidate: String) -> String? {
        var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty,
              !value.contains("*"),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: ":/?#@\\")) == nil,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard let encodedHost = components.url?.host?.lowercased(),
              !encodedHost.isEmpty,
              encodedHost.utf8.count <= 253
        else { return nil }

        let labels = encodedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              !labels.contains(where: { $0.isEmpty || $0.utf8.count > 63 }),
              labels.allSatisfy(isValidDNSLabel),
              encodedHost != "localhost",
              !encodedHost.hasSuffix(".localhost"),
              !encodedHost.hasSuffix(".local"),
              !encodedHost.hasSuffix(".home.arpa"),
              !looksLikeIPv4Address(labels)
        else { return nil }

        return encodedHost
    }

    private static func isValidDNSLabel(_ label: Substring) -> Bool {
        guard let first = label.utf8.first,
              let last = label.utf8.last,
              isASCIILetterOrDigit(first),
              isASCIILetterOrDigit(last)
        else { return false }

        return label.utf8.allSatisfy { byte in
            isASCIILetterOrDigit(byte) || byte == 45
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 48 ... 57, 97 ... 122:
            true
        default:
            false
        }
    }

    private static func looksLikeIPv4Address(_ labels: [Substring]) -> Bool {
        guard labels.count <= 4 else { return false }
        return labels.allSatisfy { label in
            if label.lowercased().hasPrefix("0x") {
                let digits = label.dropFirst(2)
                return !digits.isEmpty && digits.utf8.allSatisfy { byte in
                    switch byte {
                    case 48 ... 57, 65 ... 70, 97 ... 102:
                        true
                    default:
                        false
                    }
                }
            }
            return label.utf8.allSatisfy { 48 ... 57 ~= $0 }
        }
    }
}

struct RemoteContentPolicy: Sendable, Equatable {
    let allowedHosts: Set<String>

    init(allowedHosts: Set<String> = []) {
        self.allowedHosts = Set(allowedHosts.compactMap(RemoteContentPreferences.normalizedHost))
    }

    init(storedValue: String) {
        self.init(allowedHosts: RemoteContentPreferences.allowedHosts(storedValue: storedValue))
    }

    func allows(_ url: URL) -> Bool {
        guard let host = Self.eligibleHost(for: url) else { return false }
        return allowedHosts.contains(host)
    }

    fileprivate static func eligibleHost(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host
        else { return nil }
        return RemoteContentPreferences.normalizedHost(host)
    }
}

enum RemoteResourceURL {
    static let scheme = "mark-remote-resource"
    private static let path = "/open"

    static func make(sourceURL: URL, authority: String) -> URL? {
        guard RemoteContentPolicy.eligibleHost(for: sourceURL) != nil,
              isValidAuthority(authority)
        else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = authority.lowercased()
        components.path = path
        components.queryItems = [URLQueryItem(name: "source", value: sourceURL.absoluteString)]
        return components.url
    }

    static func sourceURL(from resourceURL: URL, expectedAuthority: String) -> URL? {
        guard resourceURL.scheme?.lowercased() == scheme,
              resourceURL.host?.lowercased() == expectedAuthority.lowercased(),
              resourceURL.user == nil,
              resourceURL.password == nil,
              resourceURL.port == nil,
              resourceURL.path == path,
              resourceURL.fragment == nil,
              let components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false)
        else { return nil }

        let queryItems = components.queryItems ?? []
        let sourceItems = queryItems.filter { $0.name == "source" }
        let revisionItems = queryItems.filter { $0.name == "revision" }
        guard sourceItems.count == 1,
              let source = sourceItems[0].value,
              !source.isEmpty,
              revisionItems.count <= 1,
              queryItems.count == sourceItems.count + revisionItems.count,
              let sourceURL = URL(string: source),
              RemoteContentPolicy.eligibleHost(for: sourceURL) != nil
        else { return nil }
        return sourceURL
    }

    private static func isValidAuthority(_ authority: String) -> Bool {
        !authority.isEmpty && authority.utf8.allSatisfy { byte in
            switch byte {
            case 45, 48 ... 57, 65 ... 90, 97 ... 122:
                true
            default:
                false
            }
        }
    }
}
