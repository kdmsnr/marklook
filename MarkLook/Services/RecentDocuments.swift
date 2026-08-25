import AppKit
import Observation

/// App-wide projection of macOS's persisted Open Recent list.
@MainActor
@Observable
final class RecentDocuments {
    static let shared = RecentDocuments()

    private(set) var urls: [URL] = []

    @ObservationIgnored private var documentController: NSDocumentController?
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var clearWhenActivated = false

    init(documentController: NSDocumentController? = nil) {
        self.documentController = documentController
        if documentController != nil {
            refresh()
        }
    }

    /// Connect only after SwiftUI finishes installing its PlatformDocumentController.
    /// Accessing NSDocumentController.shared while Scene formulas are being built can create the
    /// default controller before DocumentGroup registers its private subclass.
    func activate(documentController: NSDocumentController) {
        guard self.documentController == nil else {
            refresh()
            return
        }

        self.documentController = documentController
        if clearWhenActivated {
            documentController.clearRecentDocuments(nil)
            clearWhenActivated = false
        }
        for url in pendingURLs {
            documentController.noteNewRecentDocumentURL(url)
        }
        pendingURLs.removeAll()
        refresh()
    }

    func note(_ url: URL) {
        guard (try? DocumentFormat(url: url)) != nil else { return }
        let standardizedURL = url.standardizedFileURL
        guard let documentController else {
            if !pendingURLs.contains(where: { $0.path == standardizedURL.path }) {
                pendingURLs.append(standardizedURL)
            }
            return
        }
        documentController.noteNewRecentDocumentURL(standardizedURL)
        refresh()
    }

    func clear() {
        pendingURLs.removeAll()
        guard let documentController else {
            clearWhenActivated = true
            urls = []
            return
        }
        documentController.clearRecentDocuments(nil)
        refresh()
    }

    private func refresh() {
        guard let documentController else {
            urls = []
            return
        }
        var seenPaths = Set<String>()
        urls = documentController.recentDocumentURLs.compactMap { url in
            let standardizedURL = url.standardizedFileURL
            guard (try? DocumentFormat(url: standardizedURL)) != nil,
                  seenPaths.insert(standardizedURL.path).inserted else {
                return nil
            }
            return standardizedURL
        }
    }
}
