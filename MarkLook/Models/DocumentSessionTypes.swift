import Foundation

enum ViewerPhase: Sendable, Equatable {
    case loading
    case ready
    case failedInitially
}

enum ViewerIssueKind: Sendable, Equatable {
    case reload
    case permission
    case moved
    case encoding
    case rendering
}

struct ViewerIssue: Identifiable, Sendable, Equatable {
    let id = UUID()
    let kind: ViewerIssueKind
    let title: String
    let message: String
}

struct OpenDocumentRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    let url: URL
}

struct PreparedDocument: Sendable {
    let renderOutput: RenderOutput
    let decodeDuration: Duration
    let renderDuration: Duration
}

enum DocumentUpdatePolicy {
    static func preservesScroll(displayedURL: URL?, currentURL: URL) -> Bool {
        guard let displayedURL,
              let displayedRoute = ViewerWindowRoute.viewing(displayedURL),
              let currentRoute = ViewerWindowRoute.viewing(currentURL) else {
            return false
        }
        return displayedRoute == currentRoute
    }

    static func explicitAnchor(
        for currentURL: URL,
        preservingScroll: Bool
    ) -> String? {
        preservingScroll ? nil : currentURL.fragment
    }

    static func issueAfterUnchangedReload(
        currentIssue: ViewerIssue?,
        monitoringIssue: ViewerIssue?
    ) -> ViewerIssue? {
        switch currentIssue?.kind {
        case .moved, .reload, nil:
            return monitoringIssue
        case .permission, .encoding, .rendering:
            return currentIssue
        }
    }
}
