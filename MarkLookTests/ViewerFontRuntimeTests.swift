import AppKit
import WebKit
import XCTest
@testable import MarkLook

@MainActor
final class ViewerFontRuntimeTests: XCTestCase {
    func testFontSelectionUpdatesAnOpenDocumentAndKeepsCodeMonospaced() async throws {
        let store = try await renderedStore()
        let initial = try await fontState(in: store.webView)

        store.setFontFamily(.hiraginoMincho)
        let mincho = try await waitForFontFamily(.hiraginoMincho, in: store.webView)
        XCTAssertTrue(mincho.documentFontFamily.contains("Hiragino Mincho ProN"))
        XCTAssertEqual(mincho.codeFontFamily, initial.codeFontFamily)

        store.setFontFamily(.hiraginoSans)
        let sans = try await waitForFontFamily(.hiraginoSans, in: store.webView)
        XCTAssertTrue(sans.documentFontFamily.contains("Hiragino Sans"))
        XCTAssertEqual(sans.codeFontFamily, initial.codeFontFamily)
    }

    func testOlderFontRevisionCannotOverwriteANewerSelection() async throws {
        let store = try await renderedStore()
        let raw = try await store.webView.callAsyncJavaScript(
            """
            await globalThis.marklookRuntime.setFontFamily(newer, 2);
            await globalThis.marklookRuntime.setFontFamily(older, 1);
            const content = document.getElementById("content-host")
              .shadowRoot.getElementById("document-content");
            return content.getAttribute("data-marklook-font-family");
            """,
            arguments: [
                "newer": ViewerFontFamily.hiraginoMincho.rawValue,
                "older": ViewerFontFamily.hiraginoSans.rawValue,
            ],
            contentWorld: WebViewStore.contentWorld
        )

        XCTAssertEqual(raw as? String, ViewerFontFamily.hiraginoMincho.rawValue)
    }

    private func renderedStore() async throws -> WebViewStore {
        let documentURL = URL(fileURLWithPath: "/tmp/viewer-font-runtime/document.md")
        let store = WebViewStore(
            documentURL: documentURL,
            scopes: [.file(documentURL)],
            resourceAuthority: "viewer-font-runtime"
        )
        store.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let baseCSSURL = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("Web/Viewer.css")
        )
        let baseCSS = try String(contentsOf: baseCSSURL, encoding: .utf8)
        try await install(baseCSS: baseCSS, in: store.webView)
        return store
    }

    private func install(baseCSS: String, in webView: WKWebView) async throws {
        for _ in 0 ..< 100 {
            do {
                let raw = try await webView.callAsyncJavaScript(
                    """
                    if (!globalThis.marklookRuntime) return false;
                    globalThis.marklookRuntime.navigateAnchor("__marklook_test_bootstrap__");
                    const host = document.getElementById("content-host");
                    const root = host.shadowRoot;
                    root.querySelector("style").textContent = baseCSS;
                    root.getElementById("document-content").innerHTML =
                      "<p>本文と <code>let value = 42</code></p>";
                    host.style.visibility = "visible";
                    return true;
                    """,
                    arguments: ["baseCSS": baseCSS],
                    contentWorld: WebViewStore.contentWorld
                )
                if raw as? Bool == true {
                    try await Task.sleep(for: .milliseconds(20))
                    return
                }
            } catch {
                // The shell and isolated runtime may still be loading.
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ViewerFontRuntimeTestError.runtimeUnavailable
    }

    private func waitForFontFamily(
        _ fontFamily: ViewerFontFamily,
        in webView: WKWebView
    ) async throws -> FontState {
        for _ in 0 ..< 100 {
            let state = try await fontState(in: webView)
            if state.identifier == fontFamily.rawValue {
                return state
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ViewerFontRuntimeTestError.updateTimedOut
    }

    private func fontState(in webView: WKWebView) async throws -> FontState {
        let raw = try await webView.callAsyncJavaScript(
            """
            const content = document.getElementById("content-host")
              .shadowRoot.getElementById("document-content");
            const code = content.querySelector("code");
            return {
              identifier: content.getAttribute("data-marklook-font-family"),
              documentFontFamily: getComputedStyle(content).fontFamily,
              codeFontFamily: getComputedStyle(code).fontFamily,
            };
            """,
            contentWorld: WebViewStore.contentWorld
        )
        return try FontState(raw: raw)
    }
}

private struct FontState {
    let identifier: String
    let documentFontFamily: String
    let codeFontFamily: String

    init(raw: Any?) throws {
        guard let dictionary = raw as? [String: Any],
              let identifier = dictionary["identifier"] as? String,
              let documentFontFamily = dictionary["documentFontFamily"] as? String,
              let codeFontFamily = dictionary["codeFontFamily"] as? String
        else {
            throw ViewerFontRuntimeTestError.invalidJavaScriptResult
        }
        self.identifier = identifier
        self.documentFontFamily = documentFontFamily
        self.codeFontFamily = codeFontFamily
    }
}

private enum ViewerFontRuntimeTestError: Error {
    case invalidJavaScriptResult
    case runtimeUnavailable
    case updateTimedOut
}
