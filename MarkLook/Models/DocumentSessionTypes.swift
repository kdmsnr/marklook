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
