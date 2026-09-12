import CryptoKit
import Foundation

/// Saved history belongs to the document currently displayed, not the first file
/// opened in the window. It must never redirect a subsequent explicit file open.
struct DocumentNavigationState: Codable, Equatable {
    let currentURL: URL
    let backHistory: [URL]
    let forwardHistory: [URL]

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? PropertyListEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey(for: currentURL))
    }

    static func restore(
        for documentURL: URL,
        defaults: UserDefaults = .standard
    ) -> Self? {
        guard let requestedRoute = ViewerWindowRoute.viewing(documentURL),
              let data = defaults.data(forKey: storageKey(for: documentURL)),
              let saved = try? PropertyListDecoder().decode(Self.self, from: data),
              ViewerWindowRoute.viewing(saved.currentURL) == requestedRoute,
              let requestedURL = requestedRoute.documentURL else { return nil }

        // Older versions also stored the destination under the original file's key.
        // Reject that history, including a mismatched fragment, rather than navigating
        // away from the location the caller requested.
        return Self(
            currentURL: requestedURL,
            backHistory: saved.backHistory.compactMap { ViewerWindowRoute.viewing($0)?.documentURL },
            forwardHistory: saved.forwardHistory.compactMap { ViewerWindowRoute.viewing($0)?.documentURL }
        )
    }

    private static func storageKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "DocumentNavigation.\(digest)"
    }
}
