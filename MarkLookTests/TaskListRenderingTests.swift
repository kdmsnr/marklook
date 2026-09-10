import AppKit
import WebKit
import XCTest
@testable import MarkLook

@MainActor
final class TaskListRenderingTests: XCTestCase {
    func testTasksWithoutAnOpeningParagraphKeepTheirCheckbox() async throws {
        for source in ["- [ ] ", "- [x] ", "- [ ] \n\n  > Details"] {
            let output = try await GFMRenderEngine().render(
                source: source,
                format: .markdown,
                context: RenderContext(
                    documentURL: URL(fileURLWithPath: "/tmp/task-list-rendering/document.md"),
                    resourceAuthority: "task-list-rendering",
                    sizeClass: .full
                )
            )
            XCTAssertEqual(output.htmlFragment.components(separatedBy: "<input ").count - 1, 1, output.htmlFragment)
        }
    }

    func testTaskCheckboxesShareTheFirstTextLine() async throws {
        let documentURL = URL(fileURLWithPath: "/tmp/task-list-rendering/document.md")
        let store = WebViewStore(
            documentURL: documentURL,
            scopes: [.file(documentURL)],
            resourceAuthority: "task-list-rendering"
        )
        store.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        let cssURL = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Web/Viewer.css"))
        let css = try String(contentsOf: cssURL, encoding: .utf8)
        try await waitForRuntime(in: store.webView)

        let source = """
        - [ ] AAA
        - [x] BBB

        - [ ] **CCC**

          Another paragraph.

          - [X] Child
          - Ordinary child

        - Ordinary item

        1. [ ] Numbered
        """

        for lineBreakMode in [MarkdownLineBreakMode.gfmSoftBreaks, .preserveSingleNewlines] {
            // Exercise both the typed Markdown path and the raw HTML sanitizer path.
            for suffix in ["", "\n\n<span>Raw HTML</span>"] {
                let output = try await GFMRenderEngine().render(
                    source: source + suffix,
                    format: .markdown,
                    context: RenderContext(
                        documentURL: documentURL,
                        resourceAuthority: "task-list-rendering",
                        sizeClass: .full,
                        markdownLineBreakMode: lineBreakMode
                    )
                )
                let raw = try await store.webView.callAsyncJavaScript(
                    """
                    const host = document.getElementById("content-host");
                    const root = host.shadowRoot;
                    root.querySelector("style").textContent = css;
                    const content = root.getElementById("document-content");
                    content.innerHTML = html;
                    host.style.visibility = "visible";
                    return Array.from(content.querySelectorAll('input[type="checkbox"]'), input => {
                      const paragraph = input.closest("li").querySelector("p");
                      const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
                      let text;
                      while ((text = walker.nextNode()) && !text.textContent.trim()) {}
                      const range = document.createRange();
                      const start = text.textContent.search(/\\S/);
                      range.setStart(text, start);
                      range.setEnd(text, start + 1);
                      const textRect = range.getBoundingClientRect();
                      const checkboxRect = input.getBoundingClientRect();
                      return {
                        sameLine: checkboxRect.top < textRect.bottom && textRect.top < checkboxRect.bottom,
                        checked: input.checked,
                        disabled: input.disabled,
                        anchored: paragraph.hasAttribute("data-marklook-anchor"),
                      };
                    });
                    """,
                    arguments: ["css": css, "html": output.htmlFragment],
                    contentWorld: WebViewStore.contentWorld
                )
                let checkboxes = try XCTUnwrap(raw as? [[String: Any]])
                XCTAssertEqual(checkboxes.count, 5, output.htmlFragment)
                XCTAssertEqual(checkboxes.compactMap { $0["checked"] as? Bool }, [false, true, false, true, false])
                for checkbox in checkboxes {
                    XCTAssertEqual(checkbox["sameLine"] as? Bool, true, output.htmlFragment)
                    XCTAssertEqual(checkbox["disabled"] as? Bool, true)
                    XCTAssertEqual(checkbox["anchored"] as? Bool, true)
                }
            }
        }
    }

    private func waitForRuntime(in webView: WKWebView) async throws {
        for _ in 0 ..< 100 {
            let ready = try? await webView.callAsyncJavaScript(
                """
                if (!globalThis.marklookRuntime) return false;
                globalThis.marklookRuntime.navigateAnchor("__marklook_test_bootstrap__");
                return true;
                """,
                contentWorld: WebViewStore.contentWorld
            )
            if ready as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Viewer runtime did not load")
        throw URLError(.timedOut)
    }
}
