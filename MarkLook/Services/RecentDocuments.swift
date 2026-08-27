import AppKit
import Observation

@MainActor
protocol RecentDocumentControlling: AnyObject {
    var recentDocumentURLs: [URL] { get }
    func noteNewRecentDocumentURL(_ url: URL)
    func clearRecentDocuments(_ sender: Any?)
}

extension NSDocumentController: RecentDocumentControlling {}

/// App-wide Open Recent list backed by both app preferences and macOS's shared list.
@MainActor
@Observable
final class RecentDocuments {
    static let shared = RecentDocuments()
    static let persistenceKey = "RecentDocuments.v1"
    static let defaultMaximumCount = 20

    private(set) var urls: [URL] = []

    @ObservationIgnored private var documentController: (any RecentDocumentControlling)?
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var clearWhenActivated = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let maximumCount: Int

    init(
        documentController: (any RecentDocumentControlling)? = nil,
        defaults: UserDefaults = .standard,
        storageKey: String = RecentDocuments.persistenceKey,
        maximumCount: Int = RecentDocuments.defaultMaximumCount
    ) {
        self.documentController = documentController
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumCount = max(1, maximumCount)
        urls = loadPersistedURLs()
        if documentController != nil {
            refresh()
        }
    }

    /// Connect after SwiftUI has finished constructing the app's scenes.
    func activate(documentController: any RecentDocumentControlling) {
        guard self.documentController == nil else {
            refresh()
            return
        }

        self.documentController = documentController
        if clearWhenActivated {
            documentController.clearRecentDocuments(nil)
            clearWhenActivated = false
        }
        let pendingMostRecentFirst = Array(pendingURLs.reversed())
        pendingURLs.removeAll()
        refresh(additionalURLs: pendingMostRecentFirst, repopulateSystemList: true)
    }

    func note(_ url: URL, replacing replacedURL: URL? = nil) {
        guard let standardizedURL = supportedFileURL(url) else { return }
        let replacedPath = replacedURL.flatMap(supportedFileURL)?.path
        let remainingURLs = urls.filter { $0.path != replacedPath }
        setURLsIfChanged(mergedURLs([standardizedURL] + remainingURLs))

        guard let documentController else {
            pendingURLs.removeAll(where: {
                $0.path == standardizedURL.path || $0.path == replacedPath
            })
            pendingURLs.append(standardizedURL)
            return
        }

        if let replacedPath, replacedPath != standardizedURL.path {
            // NSDocumentController cannot remove one item. Rebuild its list so a bookmark that
            // followed a moved file does not leave the obsolete path in Open Recent.
            documentController.clearRecentDocuments(nil)
            for recentURL in urls.reversed() {
                documentController.noteNewRecentDocumentURL(recentURL)
            }
            return
        }

        documentController.noteNewRecentDocumentURL(standardizedURL)
        refresh()
    }

    func clear() {
        pendingURLs.removeAll()
        defaults.removeObject(forKey: storageKey)
        guard let documentController else {
            clearWhenActivated = true
            urls = []
            return
        }
        documentController.clearRecentDocuments(nil)
        refresh()
    }

    private func refresh(
        additionalURLs: [URL] = [],
        repopulateSystemList: Bool = false
    ) {
        guard let documentController else {
            setURLsIfChanged(mergedURLs(additionalURLs + loadPersistedURLs()))
            return
        }

        setURLsIfChanged(mergedURLs(
            additionalURLs
                + documentController.recentDocumentURLs
                + loadPersistedURLs()
        ))

        if repopulateSystemList {
            // `noteNewRecentDocumentURL` inserts at the front, so replay oldest first.
            for url in urls.reversed() {
                documentController.noteNewRecentDocumentURL(url)
            }
        }
    }

    private func mergedURLs(_ candidates: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return candidates.compactMap { url in
            guard let standardizedURL = supportedFileURL(url),
                  seenPaths.insert(standardizedURL.path).inserted else {
                return nil
            }
            return standardizedURL
        }.prefix(maximumCount).map(\.self)
    }

    private func supportedFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let standardizedURL = URL(fileURLWithPath: url.path).standardizedFileURL
        guard (try? DocumentFormat(url: standardizedURL)) != nil else { return nil }
        return standardizedURL
    }

    private func persist() {
        defaults.set(urls.map(\.absoluteString), forKey: storageKey)
    }

    private func setURLsIfChanged(_ newURLs: [URL]) {
        guard urls != newURLs else { return }
        urls = newURLs
        persist()
    }

    private func loadPersistedURLs() -> [URL] {
        guard let values = defaults.array(forKey: storageKey) as? [String] else { return [] }
        return mergedURLs(values.compactMap(URL.init(string:)))
    }
}
