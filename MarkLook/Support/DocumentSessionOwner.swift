import Foundation

/// Lazily owns one session per viewer window, shared by its content and toolbar.
/// Creating the session in a SwiftUI view initializer would also create a WKWebView
/// for transient view values. Welcome windows do not need a session at all.
@MainActor
final class DocumentSessionOwner {
    private var storedSession: DocumentSession?

    func session(for documentURL: URL) -> DocumentSession {
        if let storedSession {
            return storedSession
        }
        let session = DocumentSession(documentURL: documentURL)
        storedSession = session
        return session
    }
}
