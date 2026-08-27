import Foundation

/// The value presented by one native viewer window or tab.
enum ViewerWindowRoute: Hashable, Codable {
    static let sceneID = "viewer"

    case welcome(UUID)
    case document(URL)

    static func viewing(_ url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let normalizedURL = normalizedDocumentURL(url, preservingFragment: true)
        guard (try? DocumentFormat(url: normalizedURL)) != nil else { return nil }
        return .document(normalizedURL)
    }

    var documentURL: URL? {
        guard case let .document(url) = self else { return nil }
        return url
    }

    var windowTitle: String {
        switch self {
        case .welcome:
            "MarkLook"
        case let .document(url):
            url.lastPathComponent
        }
    }

    var normalizedIdentity: Self {
        switch self {
        case .welcome:
            self
        case let .document(url):
            .document(Self.normalizedDocumentURL(url, preservingFragment: false))
        }
    }

    static func fileAccessURL(_ url: URL) -> URL {
        normalizedDocumentURL(url, preservingFragment: false)
    }

    private static func normalizedDocumentURL(
        _ url: URL,
        preservingFragment: Bool
    ) -> URL {
        let fragment = preservingFragment ? url.fragment : nil
        let localURL = URL(fileURLWithPath: url.path).standardizedFileURL
        guard var components = URLComponents(
            url: localURL,
            resolvingAgainstBaseURL: false
        ) else { return localURL }
        components.query = nil
        components.fragment = fragment
        return components.url ?? localURL
    }
}
