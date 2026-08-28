import Foundation
import XCTest
@testable import MarkLook

@MainActor
final class RemoteContentRenderingTests: XCTestCase {
    private let allowedHost = "cdn.example.invalid"
    private let documentURL = URL(fileURLWithPath: "/tmp/remote-content/document.html")

    private var allowedContext: RenderContext {
        RenderContext(
            documentURL: documentURL,
            resourceAuthority: "remote-content-session",
            sizeClass: .full,
            remoteContentPolicy: RemoteContentPolicy(allowedHosts: [allowedHost])
        )
    }

    func testAllowedHTMLSubresourcesAreRewrittenOntoOwnedRemoteScheme() throws {
        let sources: [(source: String, kind: ResourceKind)] = [
            ("https://\(allowedHost)/image.png", .image),
            ("https://\(allowedHost)/theme.css", .stylesheet),
            ("https://\(allowedHost)/audio.mp3", .media),
            ("https://\(allowedHost)/video.mp4", .media),
            ("https://\(allowedHost)/poster.jpg", .image),
            ("https://\(allowedHost)/background.png", .image),
        ]
        let input = """
        <html>
          <head>
            <link rel="stylesheet" href="https://\(allowedHost)/theme.css">
          </head>
          <body>
            <img src="https://\(allowedHost)/image.png" alt="remote image">
            <audio src="https://\(allowedHost)/audio.mp3" controls></audio>
            <video src="https://\(allowedHost)/video.mp4"
                   poster="https://\(allowedHost)/poster.jpg" controls></video>
            <div style="background-image: url('https://\(allowedHost)/background.png')">content</div>
          </body>
        </html>
        """

        let output = try HTMLSanitizer().sanitize(input, context: allowedContext)
        let resourcesBySource = Dictionary(
            uniqueKeysWithValues: output.resources.map { ($0.source, $0) }
        )

        XCTAssertTrue(output.warnings.isEmpty, output.warnings.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(Set(resourcesBySource.keys), Set(sources.map(\.source)))
        XCTAssertEqual(remoteSchemeOccurrenceCount(in: output.fragment), sources.count, output.fragment)
        for expected in sources {
            XCTAssertEqual(resourcesBySource[expected.source]?.kind, expected.kind)
        }
    }

    func testAllowedMarkdownImageUsesRemoteSchemeOnFastPath() async throws {
        let source = "https://\(allowedHost)/markdown.png"

        let output = try await GFMRenderEngine().render(
            source: "![remote image](\(source))",
            format: .markdown,
            context: allowedContext
        )

        XCTAssertEqual(remoteSchemeOccurrenceCount(in: output.htmlFragment), 1, output.htmlFragment)
        XCTAssertEqual(output.resources.map(\.source), [source])
        XCTAssertEqual(output.resources.first?.kind, .image)
        XCTAssertTrue(output.warnings.isEmpty, output.warnings.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(output.timing.htmlParsing, .zero)
        XCTAssertEqual(output.timing.htmlCleaning, .zero)
    }

    func testDefaultPolicyBlocksRemoteContent() throws {
        let source = "https://\(allowedHost)/blocked-by-default.png"
        let context = RenderContext(
            documentURL: documentURL,
            resourceAuthority: "default-deny-session",
            sizeClass: .full
        )

        let output = try HTMLSanitizer().sanitize(
            "<img src=\"\(source)\" alt=\"blocked\">",
            context: context
        )

        XCTAssertFalse(output.fragment.contains(source), output.fragment)
        XCTAssertEqual(remoteSchemeOccurrenceCount(in: output.fragment), 0, output.fragment)
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.warnings.contains { $0.message.contains(source) })
    }

    func testUnallowedHTTPAndLookalikeHostsAreBlocked() throws {
        let blockedSources = [
            "https://other.example.invalid/unallowed.png",
            "http://\(allowedHost)/insecure.png",
            "https://\(allowedHost).attacker.invalid/lookalike.png",
        ]
        let input = blockedSources
            .map { "<img src=\"\($0)\" alt=\"blocked\">" }
            .joined(separator: "\n")

        let output = try HTMLSanitizer().sanitize(input, context: allowedContext)

        XCTAssertEqual(remoteSchemeOccurrenceCount(in: output.fragment), 0, output.fragment)
        XCTAssertTrue(output.resources.isEmpty)
        for source in blockedSources {
            XCTAssertFalse(output.fragment.contains(source), output.fragment)
            XCTAssertTrue(
                output.warnings.contains { $0.message.contains(source) },
                "Missing warning for \(source)"
            )
        }
    }

    func testAllowedSchemeRelativeResourceIsNormalizedToHTTPS() throws {
        let source = "//\(allowedHost)/scheme-relative.png"
        let absoluteSource = "https:\(source)"

        let output = try HTMLSanitizer().sanitize(
            "<img src=\"\(source)\" alt=\"remote\">",
            context: allowedContext
        )

        XCTAssertEqual(remoteSchemeOccurrenceCount(in: output.fragment), 1, output.fragment)
        XCTAssertEqual(output.resources.map(\.source), [absoluteSource])
        XCTAssertTrue(output.warnings.isEmpty, output.warnings.map(\.message).joined(separator: "\n"))
    }

    func testExecutableElementsAreRemovedEvenWhenTheirHostIsAllowed() throws {
        let input = """
        <p>safe content</p>
        <script src="https://\(allowedHost)/script.js">globalThis.compromised = true</script>
        <iframe src="https://\(allowedHost)/frame.html"></iframe>
        """

        let output = try HTMLSanitizer().sanitize(input, context: allowedContext)
        let lowercase = output.fragment.lowercased()

        XCTAssertTrue(lowercase.contains("safe content"), output.fragment)
        XCTAssertFalse(lowercase.contains("<script"), output.fragment)
        XCTAssertFalse(lowercase.contains("<iframe"), output.fragment)
        XCTAssertFalse(lowercase.contains("compromised"), output.fragment)
        XCTAssertFalse(output.fragment.contains(allowedHost), output.fragment)
        XCTAssertTrue(output.resources.isEmpty)
    }

    func testContentSecurityPolicyExposesRemoteSchemeOnlyToPassiveSubresources() {
        let policy = WebViewStore.contentSecurityPolicy
        let directives = policy.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let directiveSet = Set(directives)
        let remoteSource = "\(RemoteResourceURL.scheme):"

        XCTAssertTrue(directiveSet.contains("img-src mark-resource: \(remoteSource)"))
        XCTAssertTrue(
            directiveSet.contains("style-src 'unsafe-inline' mark-resource: \(remoteSource)")
        )
        XCTAssertTrue(directiveSet.contains("font-src mark-resource: \(remoteSource)"))
        XCTAssertTrue(directiveSet.contains("media-src mark-resource: \(remoteSource)"))

        let directivesUsingRemoteScheme = directives.filter { directive in
            directive.split(whereSeparator: { $0.isWhitespace }).dropFirst()
                .contains(Substring(remoteSource))
        }
        let directiveNames = Set(directivesUsingRemoteScheme.compactMap { directive in
            directive.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        })
        XCTAssertEqual(directiveNames, ["img-src", "style-src", "font-src", "media-src"])

        XCTAssertFalse(policy.contains("http:"), policy)
        XCTAssertFalse(policy.contains("https:"), policy)
        XCTAssertTrue(directiveSet.contains("connect-src 'none'"))
        XCTAssertTrue(directiveSet.contains("script-src 'none'"))
        XCTAssertTrue(directiveSet.contains("frame-src 'none'"))
    }

    private func remoteSchemeOccurrenceCount(in html: String) -> Int {
        html.components(separatedBy: "\(RemoteResourceURL.scheme)://").count - 1
    }
}
