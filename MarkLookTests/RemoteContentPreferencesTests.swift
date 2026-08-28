import Foundation
import XCTest
@testable import MarkLook

final class RemoteContentPreferencesTests: XCTestCase {
    func testStoredHostsAreNormalizedDeduplicatedAndSorted() {
        let hosts = RemoteContentPreferences.allowedHosts(
            storedValue: """
            Images.Example.COM.
            cdn.example.com,images.example.com
            https://rejected.example.com
            *.example.com
            localhost
            127.0.0.1
            """
        )

        XCTAssertEqual(hosts, ["cdn.example.com", "images.example.com"])
        XCTAssertEqual(
            RemoteContentPreferences.storedValue(for: hosts),
            "cdn.example.com\nimages.example.com"
        )
    }

    func testInvalidDomainShapesAreRejected() {
        for value in [
            "localhost",
            "preview",
            "127.0.0.1",
            "127.1",
            "2130706433",
            "0x7f.0.0.1",
            "[::1]",
            "printer.local",
            "router.home.arpa",
            "*.example.com",
            "https://example.com",
            "user@example.com",
            "example.com:443",
            "example.com/path",
            "example.com?query",
            "example.com#fragment",
            "bad_host.example",
            ".example.com",
        ] {
            XCTAssertNil(
                RemoteContentPreferences.normalizedHost(value),
                "Unexpectedly accepted \(value)"
            )
        }
    }

    func testPolicyAllowsOnlyExactHTTPSHostsWithoutCredentialsOrNonstandardPorts() throws {
        let policy = RemoteContentPolicy(allowedHosts: ["assets.example.com"])

        for value in [
            "https://assets.example.com/image.png",
            "HTTPS://ASSETS.EXAMPLE.COM./styles/site.css?revision=1",
            "https://assets.example.com:443/media/movie.mp4",
        ] {
            XCTAssertTrue(policy.allows(try XCTUnwrap(URL(string: value))), value)
        }

        for value in [
            "http://assets.example.com/image.png",
            "https://sub.assets.example.com/image.png",
            "https://example.com/image.png",
            "https://assets.example.com:8443/image.png",
            "https://user@assets.example.com/image.png",
            "https://user:password@assets.example.com/image.png",
        ] {
            XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testRemoteResourceURLRoundTripsAnEligibleSource() throws {
        let source = try XCTUnwrap(
            URL(string: "https://assets.example.com/images/photo.png?size=2#preview")
        )
        let resourceURL = try XCTUnwrap(
            RemoteResourceURL.make(sourceURL: source, authority: "Document-Session")
        )

        XCTAssertEqual(resourceURL.scheme, RemoteResourceURL.scheme)
        XCTAssertEqual(resourceURL.host, "document-session")
        XCTAssertEqual(
            RemoteResourceURL.sourceURL(
                from: resourceURL,
                expectedAuthority: "document-session"
            ),
            source
        )
    }

    func testRemoteResourceURLParserRejectsUnexpectedRequestShape() throws {
        let source = "https%3A%2F%2Fassets.example.com%2Fimage.png"
        for value in [
            "mark-remote-resource://other-session/open?source=\(source)",
            "mark-remote-resource://document-session/other?source=\(source)",
            "mark-remote-resource://document-session/open?source=\(source)&extra=1",
            "mark-remote-resource://document-session/open?source=\(source)&source=\(source)",
            "mark-remote-resource://document-session/open?source=http%3A%2F%2Fassets.example.com%2Fimage.png",
        ] {
            XCTAssertNil(
                RemoteResourceURL.sourceURL(
                    from: try XCTUnwrap(URL(string: value)),
                    expectedAuthority: "document-session"
                ),
                value
            )
        }

        let revisionURL = try XCTUnwrap(
            URL(string: "mark-remote-resource://document-session/open?source=\(source)&revision=42")
        )
        XCTAssertEqual(
            RemoteResourceURL.sourceURL(
                from: revisionURL,
                expectedAuthority: "document-session"
            )?.absoluteString,
            "https://assets.example.com/image.png"
        )
    }
}
