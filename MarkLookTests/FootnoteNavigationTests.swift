import AppKit
import Foundation
import WebKit
import XCTest
@testable import MarkLook

@MainActor
final class FootnoteNavigationTests: XCTestCase {
    func testHTMLFootnoteLinksNavigateInsideShadowDOM() async throws {
        let filler = (1 ... 80)
            .map { "<p>HTML filler paragraph \($0).</p>" }
            .joined(separator: "\n")
        let source = """
        <p>本文<sup class="footnote-ref" id="fnref-注"><a href="#fn-注">注</a></sup></p>
        \(filler)
        <section class="footnotes">
          <ol>
            <li id="fn-注">HTML の脚注 <a class="footnote-backref" href="#fnref-注">↩</a></li>
          </ol>
        </section>
        """

        try await assertFootnoteRoundTrip(source: source, format: .html)
    }

    func testMarkdownFootnoteLinksNavigateInsideShadowDOM() async throws {
        let filler = (1 ... 80)
            .map { "Markdown filler paragraph \($0)." }
            .joined(separator: "\n\n")
        let source = """
        本文[^注].

        \(filler)

        [^注]: Markdown の脚注
        """

        try await assertFootnoteRoundTrip(source: source, format: .markdown)
    }

    private func assertFootnoteRoundTrip(
        source: String,
        format: DocumentFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let documentURL = URL(fileURLWithPath: "/tmp/footnote-navigation/document.\(format == .html ? "html" : "md")")
        let output = try await GFMRenderEngine().render(
            source: source,
            format: format,
            context: RenderContext(
                documentURL: documentURL,
                resourceAuthority: "footnote-navigation",
                sizeClass: .full
            )
        )
        let store = WebViewStore(
            documentURL: documentURL,
            scopes: [.file(documentURL)],
            resourceAuthority: "footnote-navigation"
        )
        store.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        try await install(output.htmlFragment, in: store.webView)

        let initialFootnote = try await anchorState(in: store.webView, id: "fn-注")
        XCTAssertGreaterThan(initialFootnote.top, 240, file: file, line: line)

        let footnote = try await click(
            ".footnote-ref a",
            targetID: "fn-注",
            in: store.webView
        )
        XCTAssertGreaterThan(footnote.scrollTop, 0, file: file, line: line)
        XCTAssertTrue(footnote.isVisible(inViewportHeight: 240), file: file, line: line)
        XCTAssertEqual(footnote.hash, "#fn-%E6%B3%A8", file: file, line: line)

        let reference = try await click(
            ".footnote-backref",
            targetID: "fnref-注",
            in: store.webView
        )
        XCTAssertTrue(reference.isVisible(inViewportHeight: 240), file: file, line: line)
        XCTAssertEqual(reference.hash, "#fnref-%E6%B3%A8", file: file, line: line)
    }

    private func install(_ html: String, in webView: WKWebView) async throws {
        for _ in 0 ..< 100 {
            do {
                let raw = try await webView.callAsyncJavaScript(
                    """
                    if (!globalThis.marklookRuntime) return false;
                    globalThis.marklookRuntime.navigateAnchor("__marklook_test_bootstrap__");
                    const host = document.getElementById("content-host");
                    host.shadowRoot.getElementById("document-content").innerHTML = html;
                    host.style.visibility = "visible";
                    return true;
                    """,
                    arguments: ["html": html],
                    contentWorld: WebViewStore.contentWorld
                )
                if raw as? Bool == true { return }
            } catch {
                // The shell and isolated runtime may still be loading.
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AnchorStateError.runtimeUnavailable
    }

    private func anchorState(in webView: WKWebView, id: String) async throws -> AnchorState {
        let raw = try await webView.callAsyncJavaScript(
            """
            const root = document.getElementById("content-host").shadowRoot;
            const target = root.getElementById(id);
            if (!target) throw new Error(`Missing anchor: ${id}`);
            const rect = target.getBoundingClientRect();
            const scrollElement = document.scrollingElement || document.documentElement;
            return {
              top: rect.top,
              bottom: rect.bottom,
              scrollTop: scrollElement.scrollTop,
              hash: location.hash,
            };
            """,
            arguments: ["id": id],
            contentWorld: WebViewStore.contentWorld
        )
        return try AnchorState(raw: raw)
    }

    private func click(
        _ selector: String,
        targetID: String,
        in webView: WKWebView
    ) async throws -> AnchorState {
        _ = try await webView.callAsyncJavaScript(
            """
            const root = document.getElementById("content-host").shadowRoot;
            const link = root.querySelector(selector);
            if (!link) throw new Error(`Missing link: ${selector}`);
            link.click();
            return true;
            """,
            arguments: ["selector": selector],
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(50))
        return try await anchorState(in: webView, id: targetID)
    }
}

private struct AnchorState {
    let top: Double
    let bottom: Double
    let scrollTop: Double
    let hash: String

    init(raw: Any?) throws {
        guard let dictionary = raw as? [String: Any],
              let top = dictionary["top"] as? Double,
              let bottom = dictionary["bottom"] as? Double,
              let scrollTop = dictionary["scrollTop"] as? Double,
              let hash = dictionary["hash"] as? String
        else {
            throw AnchorStateError.invalidJavaScriptResult
        }
        self.top = top
        self.bottom = bottom
        self.scrollTop = scrollTop
        self.hash = hash
    }

    func isVisible(inViewportHeight height: Double) -> Bool {
        bottom > 0 && top < height
    }
}

private enum AnchorStateError: Error {
    case invalidJavaScriptResult
    case runtimeUnavailable
}
