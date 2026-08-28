import Foundation
import XCTest
@testable import MarkLook

final class RemoteResourceSchemeHandlerTests: XCTestCase {
    private let authority = "remote-test-session"
    private let allowedHost = "static.example.com"

    func testRequestParsingRequiresOwnedGETAndCurrentlyAllowedSource() throws {
        let loader = makeLoader()
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/assets/image.png?version=1"))
        let resourceURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: authority)
        )

        XCTAssertEqual(
            try loader.sourceURL(for: URLRequest(url: resourceURL)),
            sourceURL
        )

        var revisionComponents = try XCTUnwrap(
            URLComponents(url: resourceURL, resolvingAgainstBaseURL: false)
        )
        revisionComponents.queryItems?.append(.init(name: "revision", value: "7"))
        XCTAssertEqual(
            try loader.sourceURL(
                for: URLRequest(url: try XCTUnwrap(revisionComponents.url))
            ),
            sourceURL
        )

        var post = URLRequest(url: resourceURL)
        post.httpMethod = "POST"
        assertThrows(.invalidRequest) {
            _ = try loader.sourceURL(for: post)
        }

        let wrongAuthorityURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: "another-session")
        )
        assertThrows(.invalidRequest) {
            _ = try loader.sourceURL(for: URLRequest(url: wrongAuthorityURL))
        }

        let unlistedURL = try XCTUnwrap(URL(string: "https://cdn.example.com/image.png"))
        let unlistedResourceURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: unlistedURL, authority: authority)
        )
        assertThrows(.disallowedURL) {
            _ = try loader.sourceURL(for: URLRequest(url: unlistedResourceURL))
        }
    }

    func testPolicyUpdateIsAuthoritativeForExistingResourceURLs() throws {
        let loader = makeLoader()
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/image.png"))
        let resourceURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: authority)
        )
        let request = URLRequest(url: resourceURL)

        XCTAssertNoThrow(try loader.sourceURL(for: request))
        loader.update(policy: RemoteContentPolicy())
        assertThrows(.disallowedURL) {
            _ = try loader.sourceURL(for: request)
        }
    }

    func testSessionAndRemoteRequestDoNotUseCookiesCacheCredentialsOrReferrer() throws {
        let configuration = RemoteResourceLoader.makeSessionConfiguration()

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 4)
        XCTAssertEqual(
            configuration.httpAdditionalHeaders?["Accept-Encoding"] as? String,
            "identity"
        )

        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/image.png"))
        let request = try makeLoader().remoteRequest(for: sourceURL)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testRedirectValidationRebuildsRequestAndRejectsUnlistedOrExcessRedirects() throws {
        let loader = makeLoader(additionalHosts: ["media.example.com"])
        let allowedRedirect = try XCTUnwrap(
            URL(string: "https://media.example.com/video/movie.mp4")
        )

        let request = try loader.redirectedRequest(to: allowedRedirect, redirectCount: 0)
        XCTAssertEqual(request.url, allowedRedirect)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))

        let unlisted = try XCTUnwrap(URL(string: "https://attacker.invalid/pixel.png"))
        assertThrows(.disallowedURL) {
            _ = try loader.redirectedRequest(to: unlisted, redirectCount: 0)
        }

        let downgrade = try XCTUnwrap(URL(string: "http://static.example.com/image.png"))
        assertThrows(.disallowedURL) {
            _ = try loader.redirectedRequest(to: downgrade, redirectCount: 0)
        }

        assertThrows(.tooManyRedirects) {
            _ = try loader.redirectedRequest(
                to: allowedRedirect,
                redirectCount: RemoteResourceLoader.maximumRedirects
            )
        }
    }

    func testResponseAcceptsOnlyStaticMIMETypesAndRejectsStatusOrDeclaredOversize() throws {
        let loader = makeLoader()
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/resource"))

        for mimeType in [
            "image/png",
            "text/css; charset=utf-8",
            "font/woff2",
            "application/font-woff",
            "audio/mpeg",
            "video/mp4",
        ] {
            let response = try upstreamResponse(
                url: sourceURL,
                statusCode: 200,
                headers: ["Content-Type": mimeType]
            )
            XCTAssertNoThrow(try loader.metadata(for: response), mimeType)
        }

        let html = try upstreamResponse(
            url: sourceURL,
            statusCode: 200,
            headers: ["Content-Type": "text/html"]
        )
        assertThrows(.unsupportedContentType("text/html")) {
            _ = try loader.metadata(for: html)
        }

        let redirect = try upstreamResponse(
            url: sourceURL,
            statusCode: 302,
            headers: ["Content-Type": "image/png"]
        )
        assertThrows(.invalidResponse) {
            _ = try loader.metadata(for: redirect)
        }

        let oversized = try upstreamResponse(
            url: sourceURL,
            statusCode: 200,
            headers: [
                "Content-Type": "image/png",
                "Content-Length": String(RemoteResourceLoader.maximumResponseBytes + 1),
            ]
        )
        assertThrows(.responseTooLarge) {
            _ = try loader.metadata(for: oversized)
        }
    }

    func testCustomResponseDoesNotForwardUpstreamHeadersAndAddsDefenseHeaders() throws {
        let loader = makeLoader()
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/image.png"))
        let requestURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: authority)
        )
        let upstream = try upstreamResponse(
            url: sourceURL,
            statusCode: 200,
            headers: [
                "Content-Type": "image/png",
                "Set-Cookie": "tracking=1; Secure",
                "ETag": "secret-validator",
                "Access-Control-Allow-Origin": "*",
            ]
        )
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let result = try loader.response(
            for: requestURL,
            sourceURL: sourceURL,
            upstreamResponse: upstream,
            data: data
        )

        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.urlResponse.url, requestURL)
        XCTAssertEqual(result.urlResponse.statusCode, 200)
        XCTAssertEqual(
            result.urlResponse.value(forHTTPHeaderField: "Content-Type"),
            "image/png"
        )
        XCTAssertEqual(
            result.urlResponse.value(forHTTPHeaderField: "X-Content-Type-Options"),
            "nosniff"
        )
        XCTAssertEqual(
            result.urlResponse.value(forHTTPHeaderField: "Cache-Control"),
            "no-store, max-age=0"
        )
        XCTAssertTrue(
            result.urlResponse.value(forHTTPHeaderField: "Content-Security-Policy")?
                .contains("default-src 'none'") == true
        )
        XCTAssertNil(result.urlResponse.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertNil(result.urlResponse.value(forHTTPHeaderField: "ETag"))
        XCTAssertNil(result.urlResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
    }

    func testStylesheetMustBeUTF8AndIsServedWithExplicitCharset() throws {
        let loader = makeLoader()
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/styles/site.css"))
        let requestURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: authority)
        )
        let upstream = try upstreamResponse(
            url: sourceURL,
            statusCode: 200,
            headers: ["Content-Type": "text/css"]
        )

        let result = try loader.response(
            for: requestURL,
            sourceURL: sourceURL,
            upstreamResponse: upstream,
            data: Data("body { color: red; }".utf8)
        )
        XCTAssertEqual(
            result.urlResponse.value(forHTTPHeaderField: "Content-Type"),
            "text/css; charset=utf-8"
        )
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "body { color: red; }")

        assertThrows(.invalidStylesheet) {
            _ = try loader.response(
                for: requestURL,
                sourceURL: sourceURL,
                upstreamResponse: upstream,
                data: Data([0xFF, 0xFE, 0x00])
            )
        }
    }

    func testStylesheetRewritesNestedStaticResourcesOntoOwnedScheme() throws {
        let loader = makeLoader(additionalHosts: ["media.example.com"])
        let sourceURL = try XCTUnwrap(URL(string: "https://static.example.com/styles/site.css"))
        let requestURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: sourceURL, authority: authority)
        )
        let upstream = try upstreamResponse(
            url: sourceURL,
            statusCode: 200,
            headers: ["Content-Type": "text/css"]
        )
        let stylesheet = """
        @import url("../base/reset.css") screen;
        .hero { background-image: url('../images/hero.png'); }
        @font-face { src: url("https://media.example.com/fonts/icon.woff2"); }
        .blocked { background-image: url("http://static.example.com/insecure.png"); }
        """

        let result = try loader.response(
            for: requestURL,
            sourceURL: sourceURL,
            upstreamResponse: upstream,
            data: Data(stylesheet.utf8)
        )
        let rewritten = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        let expectedSources = [
            "https://static.example.com/base/reset.css",
            "https://static.example.com/images/hero.png",
            "https://media.example.com/fonts/icon.woff2",
        ]

        for source in expectedSources {
            let expectedURL = try XCTUnwrap(
                RemoteResourceURL.make(
                    sourceURL: try XCTUnwrap(URL(string: source)),
                    authority: authority
                )
            )
            XCTAssertTrue(rewritten.contains(expectedURL.absoluteString), rewritten)
        }
        XCTAssertFalse(rewritten.contains("url(\"http://"), rewritten)
        XCTAssertFalse(rewritten.contains("url('http://"), rewritten)
    }

    private func makeLoader(additionalHosts: Set<String> = []) -> RemoteResourceLoader {
        RemoteResourceLoader(
            resourceAuthority: authority,
            policy: RemoteContentPolicy(
                allowedHosts: additionalHosts.union([allowedHost])
            )
        )
    }

    private func upstreamResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String]
    ) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        )
    }

    private func assertThrows(
        _ expectedError: RemoteResourceLoadError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? RemoteResourceLoadError,
                expectedError,
                file: file,
                line: line
            )
        }
    }
}
