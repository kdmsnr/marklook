import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class SecureRenderingTests: XCTestCase {
    private let documentURL = URL(fileURLWithPath: "/tmp/render/document.md")

    private var context: RenderContext {
        RenderContext(
            documentURL: documentURL,
            resourceAuthority: "render-session",
            sizeClass: .full
        )
    }

    func testCodeFenceContentIsTextNotExecutableMarkup() async throws {
        let source = """
        ```html
        <script>globalThis.compromised = true</script>
        <img src=x onerror=alert(1)>
        ```
        """

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertFalse(output.htmlFragment.lowercased().contains("<script"), output.htmlFragment)
        XCTAssertFalse(output.htmlFragment.lowercased().contains("<img"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("&lt;script&gt;"))
        XCTAssertTrue(output.htmlFragment.contains("class=\"language-html\""))
        XCTAssertTrue(output.resources.isEmpty)
    }

    func testMarkdownRawHTMLStillPassesThroughSanitizer() async throws {
        let source = """
        # Safe heading

        <script>alert(1)</script>
        <iframe src="https://attacker.invalid"></iframe>
        <img src="local.png" onerror="alert(2)">
        """

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )
        let lowercased = output.htmlFragment.lowercased()

        XCTAssertFalse(lowercased.contains("<script"))
        XCTAssertFalse(lowercased.contains("<iframe"))
        XCTAssertFalse(lowercased.contains("onerror"))
        XCTAssertTrue(lowercased.contains("mark-resource://render-session/open?source=local.png"))
        XCTAssertEqual(output.resources.map(\.source), ["local.png"])
        XCTAssertEqual(output.title, "Safe heading")
    }

    func testMarkdownLinksCannotIntroduceJavaScriptURL() async throws {
        let source = "[unsafe](javascript:alert%281%29) [web](https://example.com/) [local](next.md)"

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )
        let lowercased = output.htmlFragment.lowercased()

        XCTAssertFalse(lowercased.contains("javascript:"))
        XCTAssertTrue(lowercased.contains("https://example.com/"))
        XCTAssertTrue(lowercased.contains("mark-navigation://render-session/open?source=next.md"))
    }

    func testMathSourceIsEscapedBeforeAppManagedKaTeXProcessing() async throws {
        let source = #"$<img src=x onerror=alert(1)>$"#

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .markdown,
            context: context
        )

        XCTAssertTrue(output.containsMath)
        XCTAssertFalse(output.htmlFragment.lowercased().contains("<img"), output.htmlFragment)
        XCTAssertTrue(output.htmlFragment.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertTrue(output.htmlFragment.contains("data-marklook-math=\"true\""))
    }

    func testHTMLDocumentsAreRenderedOnlyAsSanitizedStaticDOM() async throws {
        let source = """
        <!doctype html><html><head><title>Static title</title></head><body>
        <h1>Hello</h1><script>fetch('https://attacker.invalid')</script>
        <form action="https://attacker.invalid"><p>form text</p></form>
        </body></html>
        """

        let output = try await GFMRenderEngine().render(
            source: source,
            format: .html,
            context: context
        )
        let lowercased = output.htmlFragment.lowercased()

        XCTAssertEqual(output.title, "Static title")
        XCTAssertFalse(lowercased.contains("<script"))
        XCTAssertFalse(lowercased.contains("fetch("))
        XCTAssertFalse(lowercased.contains("<form"))
        XCTAssertTrue(lowercased.contains("form text"))
        XCTAssertFalse(output.containsMath)
    }
}
