import Foundation
import XCTest
@testable import MarkLook

final class CSSResourceRewriterTests: XCTestCase {
    private let rewriter = CSSResourceRewriter()
    private let stylesheetURL = URL(fileURLWithPath: "/tmp/MarkLook CSS/styles/theme.css")
    private let authority = "document-session"

    func testLocalURLsAreRebasedOntoOwnedResourceScheme() throws {
        let css = """
        .hero { background-image: url('../images/hero%20image.png?cache=1#preview'); }
        @font-face { src: url(../fonts/Local.woff2) format('woff2'); }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        )
        let resourceURLs = try extractedResourceURLs(from: output)

        XCTAssertEqual(resourceURLs.count, 2)
        XCTAssertTrue(resourceURLs.allSatisfy { $0.host == authority && $0.path == "/open" })
        let sources = try Set(resourceURLs.map { try sourceQueryItem(from: $0) })
        XCTAssertEqual(
            sources,
            [
                "file:///tmp/MarkLook%20CSS/styles/../images/hero%20image.png",
                "file:///tmp/MarkLook%20CSS/styles/../fonts/Local.woff2",
            ]
        )
    }

    func testRemoteDataAndJavaScriptURLsAreNeutralized() {
        let css = """
        a { background: url(https://attacker.invalid/a.png); }
        b { background: url(//attacker.invalid/b.png); }
        c { background: url(data:image/png;base64,AAAA); }
        d { background: url(javascript:alert(1)); }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        ).lowercased()

        XCTAssertFalse(output.contains("attacker.invalid"))
        XCTAssertFalse(output.contains("data:image"))
        XCTAssertFalse(output.contains("javascript:"))
        XCTAssertFalse(output.contains("mark-resource://"))
    }

    func testQuotedLocalImportWithMediaQualifierIsRewritten() throws {
        let css = """
        @import "print.css" print;
        @import 'https://attacker.invalid/remote.css' screen;
        body { color: black; }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        )

        XCTAssertFalse(output.contains("attacker.invalid"))
        XCTAssertTrue(output.contains(") print;"))
        let resourceURL = try XCTUnwrap(extractedResourceURLs(from: output).first)
        XCTAssertEqual(try sourceQueryItem(from: resourceURL), "file:///tmp/MarkLook%20CSS/styles/print.css")
    }

    func testMalformedPercentEncodingAndRemoteFileHostAreNeutralized() {
        let css = """
        a { background: url(bad%2Gname.png); }
        b { background: url(file://remote-host/share/image.png); }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        )

        XCTAssertFalse(output.contains("mark-resource://"))
        XCTAssertFalse(output.contains("remote-host"))
        XCTAssertFalse(output.contains("bad%2Gname"))
    }

    func testLegacyExecutableAndEditableCSSDeclarationsAreRemovedEntirely() {
        let css = """
        p { width: expression(alert(1)); color: red; }
        div { behavior: url(evil.htc); background: white; }
        span { -moz-binding: url(evil.xml); -webkit-user-modify: read-write; }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        ).lowercased()

        XCTAssertFalse(output.contains("expression"), output)
        XCTAssertFalse(output.contains("behavior"), output)
        XCTAssertFalse(output.contains("-moz-binding"), output)
        XCTAssertFalse(output.contains("user-modify"), output)
        XCTAssertFalse(output.contains("evil.htc"), output)
        XCTAssertFalse(output.contains("evil.xml"), output)
        XCTAssertTrue(output.contains("color: red"))
        XCTAssertTrue(output.contains("background: white"))
    }

    func testURLAndImportTextInsideCommentsAndStringsIsPreserved() throws {
        let css = """
        /* background: url(../outside/comment.png); */
        /* @import "comment.css"; */
        .label::before { content: "url(literal.png)"; }
        .label::after { content: '@import "literal.css";'; }
        .hero { background: url(real.png); }
        """

        let output = rewriter.rewrite(
            css,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        )

        XCTAssertTrue(output.contains("/* background: url(../outside/comment.png); */"), output)
        XCTAssertTrue(output.contains("/* @import \"comment.css\"; */"), output)
        XCTAssertTrue(output.contains("content: \"url(literal.png)\""), output)
        XCTAssertTrue(output.contains("content: '@import \"literal.css\";'"), output)
        let resourceURLs = try extractedResourceURLs(from: output)
        XCTAssertEqual(resourceURLs.count, 1)
        let resourceURL = try XCTUnwrap(resourceURLs.first)
        XCTAssertEqual(
            try sourceQueryItem(from: resourceURL),
            "file:///tmp/MarkLook%20CSS/styles/real.png"
        )
    }

    func testUnquotedEscapedSpaceResolvesToFileContainingSpace() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stylesDirectory = temporaryDirectory.appendingPathComponent("styles", isDirectory: true)
        let imageURL = stylesDirectory.appendingPathComponent("hero image.png")
        try FileManager.default.createDirectory(
            at: stylesDirectory,
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let output = rewriter.rewrite(
            #".hero { background-image: url(hero\ image.png); }"#,
            stylesheetURL: stylesDirectory.appendingPathComponent("theme.css"),
            resourceAuthority: authority
        )

        let resourceURLs = try extractedResourceURLs(from: output)
        XCTAssertEqual(resourceURLs.count, 1)
        let resourceURL = try XCTUnwrap(resourceURLs.first)
        let source = try sourceQueryItem(from: resourceURL)
        let resolvedFileURL = try XCTUnwrap(URL(string: source))
        XCTAssertEqual(resolvedFileURL.path, imageURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedFileURL.path))
    }

    func testHexadecimalCSSEscapeIsDecodedBeforeURLResolution() throws {
        let output = rewriter.rewrite(
            #".hero { background-image: url(hero\20 image.png); }"#,
            stylesheetURL: stylesheetURL,
            resourceAuthority: authority
        )

        let resourceURLs = try extractedResourceURLs(from: output)
        XCTAssertEqual(resourceURLs.count, 1)
        let resourceURL = try XCTUnwrap(resourceURLs.first)
        XCTAssertEqual(
            try sourceQueryItem(from: resourceURL),
            "file:///tmp/MarkLook%20CSS/styles/hero%20image.png"
        )
    }

    private func extractedResourceURLs(from css: String) throws -> [URL] {
        let expression = try NSRegularExpression(pattern: #"mark-resource://[^\"')\s]+"#)
        let range = NSRange(css.startIndex..<css.endIndex, in: css)
        return expression.matches(in: css, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: css) else { return nil }
            return URL(string: String(css[swiftRange]))
        }
    }

    private func sourceQueryItem(from url: URL) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems?.first { $0.name == "source" }?.value)
    }
}
