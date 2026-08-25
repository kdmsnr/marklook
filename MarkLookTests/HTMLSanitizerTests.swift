import Foundation
import XCTest
@testable import MarkLook

final class HTMLSanitizerTests: XCTestCase {
    private let sanitizer = HTMLSanitizer()
    private let documentURL = URL(fileURLWithPath: "/tmp/MarkLook Tests/document.html")

    private var context: RenderContext {
        RenderContext(
            documentURL: documentURL,
            resourceAuthority: "document-session",
            sizeClass: .full
        )
    }

    func testExecutableAndNavigatingHTMLIsRemoved() throws {
        let source = """
        <html><head>
          <base href="https://attacker.invalid/">
          <meta http-equiv="refresh" content="0; url=https://attacker.invalid/">
          <script>alert(1)</script>
        </head><body>
          <iframe src="https://attacker.invalid/"></iframe>
          <object data="file:///tmp/secret"></object>
          <embed src="file:///tmp/secret">
          <form action="https://attacker.invalid/"><p>kept text</p><button>Send</button></form>
          <textarea>editable</textarea><select><option>choice</option></select>
          <p onclick="alert(1)" onmouseover="alert(2)">safe text</p>
        </body></html>
        """

        let result = try sanitizer.sanitize(source, context: context)
        let output = result.fragment.lowercased()

        for forbidden in [
            "<script", "<iframe", "<object", "<embed", "<base", "http-equiv",
            "<form", "<button", "<textarea", "<select", "<option", "onclick", "onmouseover",
        ] {
            XCTAssertFalse(output.contains(forbidden), "Unexpected output token: \(forbidden)")
        }
        XCTAssertTrue(output.contains("kept text"))
        XCTAssertTrue(output.contains("safe text"))
    }

    func testOnlyStaticDisabledCheckboxInputsSurvive() throws {
        let source = """
        <input type="text" value="editable">
        <input type="submit">
        <input type="checkbox" checked onclick="alert(1)">
        """

        let result = try sanitizer.sanitize(source, context: context)
        let output = result.fragment.lowercased()

        XCTAssertFalse(output.contains("type=\"text\""))
        XCTAssertFalse(output.contains("type=\"submit\""))
        XCTAssertFalse(output.contains("onclick"))
        XCTAssertTrue(output.contains("type=\"checkbox\""))
        XCTAssertTrue(output.contains("checked"))
        XCTAssertTrue(output.contains("disabled"))
    }

    func testNavigationURLsAreRestrictedAndRewritten() throws {
        let source = """
        <a id="web" href="https://example.com/page">web</a>
        <a id="local" href="chapter.md#part">local</a>
        <a id="fragment" href="#section">fragment</a>
        <a id="script" href="java&#x73;cript:alert(1)">script</a>
        <a id="data" href="data:text/html,unsafe">data</a>
        """

        let result = try sanitizer.sanitize(source, context: context)
        let output = result.fragment

        XCTAssertTrue(output.contains("https://example.com/page"))
        XCTAssertTrue(output.contains("rel=\"noopener noreferrer\""))
        XCTAssertTrue(
            output.contains("mark-navigation://document-session/open?source=chapter.md%23part"),
            output
        )
        XCTAssertTrue(output.contains("href=\"#section\""))
        XCTAssertFalse(output.lowercased().contains("javascript:"))
        XCTAssertFalse(output.lowercased().contains("data:text"))
        XCTAssertTrue(output.contains(">script</a>"))
        XCTAssertTrue(output.contains(">data</a>"))
    }

    func testOnlyLocalRenderableResourcesAreCollectedAndRewritten() throws {
        let source = """
        <img src="images/photo.png" srcset="images/2x.png 2x">
        <img src="https://tracker.invalid/pixel.png">
        <img src="data:image/png;base64,AAAA">
        <link rel="icon" href="icon.png">
        <link rel="stylesheet" href="styles/site.css">
        <video poster="poster.jpg"><source src="movie.mp4"></video>
        """

        let result = try sanitizer.sanitize(source, context: context)
        let sources = Set(result.resources.map(\.source))
        let output = result.fragment.lowercased()

        XCTAssertEqual(
            sources,
            ["images/photo.png", "styles/site.css", "poster.jpg", "movie.mp4"]
        )
        XCTAssertEqual(result.resources.count, 4)
        XCTAssertFalse(output.contains("https://tracker.invalid"))
        XCTAssertFalse(output.contains("data:image"))
        XCTAssertFalse(output.contains("srcset"))
        XCTAssertFalse(output.contains("rel=\"icon\""))
        XCTAssertTrue(output.contains("mark-resource://document-session/open?source="))
        XCTAssertTrue(result.warnings.contains { $0.message.contains("tracker.invalid") })
        XCTAssertTrue(result.warnings.contains { $0.message.contains("data:image") })
    }

    func testEveryAllowedSubresourceElementRejectsRemoteURLs() throws {
        let source = """
        <link rel="stylesheet" href="https://attacker.invalid/site.css">
        <img src="https://attacker.invalid/image.png"
             srcset="https://attacker.invalid/image-2x.png 2x">
        <audio src="https://attacker.invalid/audio.mp3"></audio>
        <video src="https://attacker.invalid/video.mp4"
               poster="https://attacker.invalid/poster.jpg">
          <source src="https://attacker.invalid/video.webm" type="video/webm">
        </video>
        """

        let result = try sanitizer.sanitize(source, context: context)
        let output = result.fragment.lowercased()

        XCTAssertFalse(output.contains("attacker.invalid"), output)
        XCTAssertFalse(output.contains("srcset"), output)
        XCTAssertTrue(result.resources.isEmpty)
        XCTAssertEqual(
            result.warnings.filter { $0.message.contains("attacker.invalid") }.count,
            6
        )
    }

    func testCSSDropsActiveFeaturesAndRemoteURLsButKeepsLocalURLs() throws {
        let source = """
        <style>
          @import "https://attacker.invalid/a.css";
          p { background: url(https://attacker.invalid/a.png); behavior: url(evil.htc); }
          div { background-image: url('images/background.png'); width: expression(alert(1)); }
        </style>
        <p style="background:url(//attacker.invalid/b.png); -moz-binding:url(evil.xml)">text</p>
        """

        let result = try sanitizer.sanitize(source, context: context)
        let output = result.fragment.lowercased()

        XCTAssertFalse(output.contains("@import"))
        XCTAssertFalse(output.contains("attacker.invalid"), output)
        XCTAssertFalse(output.contains("expression"), output)
        XCTAssertFalse(output.contains("behavior:"), output)
        XCTAssertFalse(output.contains("-moz-binding"), output)
        XCTAssertTrue(output.contains("mark-resource://document-session/open?source=images/background.png"))
        XCTAssertEqual(result.resources.map(\.source), ["images/background.png"])
    }

    func testPercentEncodedFilenameIsResolvedWithoutTreatingDecodedHashAsFragment() throws {
        let source = #"<img src="images/asset%23one.png?cache=1#preview">"#

        let result = try sanitizer.sanitize(source, context: context)
        let resource = try XCTUnwrap(result.resources.first)

        XCTAssertEqual(resource.source, "images/asset%23one.png?cache=1#preview")
        XCTAssertEqual(
            resource.resolvedURL?.path,
            "/tmp/MarkLook Tests/images/asset#one.png"
        )
    }

    func testMalformedPercentEncodingDoesNotProduceAPermissionCandidate() throws {
        let source = #"<img src="images/bad%2Gname.png">"#

        let result = try sanitizer.sanitize(source, context: context)
        let resource = try XCTUnwrap(result.resources.first)

        XCTAssertNil(resource.resolvedURL)
    }
}
