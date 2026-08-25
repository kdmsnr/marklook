import SwiftUI
import WebKit

struct DocumentWebView: NSViewRepresentable {
    let store: WebViewStore

    func makeNSView(context _: Context) -> WKWebView {
        store.webView
    }

    func updateNSView(_: WKWebView, context _: Context) {
        // The session owns one long-lived WKWebView. Content updates are explicit DOM operations.
    }
}
