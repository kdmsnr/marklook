import Foundation
import XCTest
@testable import MarkLook

final class LocalResourceSchemeHandlerTests: XCTestCase {
    private let authority = "document-session"
    private var rootURL: URL!
    private var documentURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLookSchemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        documentURL = rootURL.appendingPathComponent("document.html")
        try Data("<p>document</p>".utf8).write(to: documentURL)
    }

    override func tearDownWithError() throws {
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        documentURL = nil
    }

    func testAllowedResourceReturnsNoSniffNoStoreResponseAndRecordsDependency() throws {
        let imageURL = rootURL.appendingPathComponent("image.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        try imageData.write(to: imageURL)
        let recorder = LockedURLRecorder()
        let loader = makeLoader { recorder.append($0) }

        let result = try loader.response(for: request(source: "image.png"))

        XCTAssertEqual(result.data, imageData)
        XCTAssertEqual(result.urlResponse.statusCode, 200)
        XCTAssertEqual(result.urlResponse.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(result.urlResponse.value(forHTTPHeaderField: "Cache-Control"), "no-store, max-age=0")
        XCTAssertEqual(recorder.values.map(\.path), [imageURL.path])
    }

    func testStylesheetIsStrictlyDecodedAndResourceURLsAreRewritten() throws {
        let stylesheetURL = rootURL.appendingPathComponent("styles/site.css")
        try FileManager.default.createDirectory(
            at: stylesheetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        body { background: url(../images/local.png); }
        p { background: url(https://attacker.invalid/remote.png); }
        """.utf8).write(to: stylesheetURL)
        let loader = makeLoader()

        let result = try loader.response(for: request(source: "styles/site.css"))
        let css = try XCTUnwrap(String(data: result.data, encoding: .utf8))

        XCTAssertEqual(
            result.urlResponse.value(forHTTPHeaderField: "Content-Type"),
            "text/css; charset=utf-8"
        )
        XCTAssertTrue(css.contains("mark-resource://\(authority)/open?source="))
        XCTAssertFalse(css.contains("attacker.invalid"))
    }

    func testInvalidUTF8OrNULContainingStylesheetFailsClosed() throws {
        let invalidURL = rootURL.appendingPathComponent("invalid.css")
        try Data([0xFF, 0xFE, 0x00]).write(to: invalidURL)
        let loader = makeLoader()

        XCTAssertThrowsError(try loader.response(for: request(source: "invalid.css"))) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
        }

        let nulURL = rootURL.appendingPathComponent("nul.css")
        try Data([0x61, 0x00, 0x62]).write(to: nulURL)
        XCTAssertThrowsError(try loader.response(for: request(source: "nul.css"))) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
        }
    }

    func testWrongAuthorityCannotUseAnotherDocumentsGrantedScopes() {
        let loader = makeLoader()

        XCTAssertThrowsError(
            try loader.response(for: request(source: "document.html", host: "another-session"))
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .noPermissionsToReadFile)
        }
    }

    func testOnlyMarkResourceGETRequestsAreAccepted() {
        let loader = makeLoader()

        var wrongScheme = request(source: "document.html")
        wrongScheme.url = URL(string: "https://example.com/open?source=document.html")
        XCTAssertThrowsError(try loader.response(for: wrongScheme)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }

        var post = request(source: "document.html")
        post.httpMethod = "POST"
        XCTAssertThrowsError(try loader.response(for: post)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }
    }

    func testQueryShapeIsStrictButOneRevisionIsAllowed() throws {
        let loader = makeLoader()

        var duplicateSource = URLComponents()
        duplicateSource.scheme = "mark-resource"
        duplicateSource.host = authority
        duplicateSource.path = "/open"
        duplicateSource.queryItems = [
            .init(name: "source", value: "document.html"),
            .init(name: "source", value: "other.html"),
        ]
        XCTAssertThrowsError(
            try loader.response(for: URLRequest(url: try XCTUnwrap(duplicateSource.url)))
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }

        var unexpected = request(source: "document.html")
        unexpected.url = URL(string: "mark-resource://\(authority)/open?source=document.html&redirect=https://attacker.invalid")
        XCTAssertThrowsError(try loader.response(for: unexpected)) { error in
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }

        var revisionRequest = request(source: "document.html")
        revisionRequest.url = URL(string: "mark-resource://\(authority)/open?source=document.html&revision=42")
        XCTAssertNoThrow(try loader.response(for: revisionRequest))
    }

    func testSourceTraversalAndRemoteSourceAreRejectedByPathValidator() throws {
        let outsideURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let loader = makeLoader()

        XCTAssertThrowsError(try loader.response(for: request(source: "../\(outsideURL.lastPathComponent)"))) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
        XCTAssertThrowsError(
            try loader.response(for: request(source: "https://attacker.invalid/file.png"))
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .unsupportedScheme("https"))
        }
    }

    func testBundleAuthorityOnlyAcceptsKaTeXFontShape() {
        let loader = makeLoader()

        for urlString in [
            "mark-resource://bundle/ViewerRuntime.js",
            "mark-resource://bundle/katex/katex.min.js",
            "mark-resource://bundle/katex/fonts/../katex.min.js",
            "mark-resource://bundle/katex/fonts/NotKaTeX.woff2",
            "mark-resource://bundle/katex/fonts/KaTeX_Main-Regular.woff2?source=other",
        ] {
            XCTAssertThrowsError(
                try loader.response(for: URLRequest(url: try XCTUnwrap(URL(string: urlString))))
            )
        }
    }

    private func makeLoader(
        dependencyLoaded: @escaping @Sendable (URL) -> Void = { _ in }
    ) -> LocalResourceLoader {
        LocalResourceLoader(
            documentURL: documentURL,
            scopes: [.folder(rootURL)],
            resourceAuthority: authority,
            dependencyLoaded: dependencyLoaded
        )
    }

    private func request(source: String, host: String? = nil) -> URLRequest {
        var components = URLComponents()
        components.scheme = "mark-resource"
        components.host = host ?? authority
        components.path = "/open"
        components.queryItems = [.init(name: "source", value: source)]
        return URLRequest(url: components.url!)
    }
}

private final class LockedURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}
