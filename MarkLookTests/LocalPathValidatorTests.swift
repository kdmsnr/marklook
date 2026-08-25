import Foundation
import XCTest
@testable import MarkLook

final class LocalPathValidatorTests: XCTestCase {
    private let validator = LocalPathValidator()
    private var rootURL: URL!
    private var allowedFolderURL: URL!
    private var outsideFolderURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLookPathTests-\(UUID().uuidString)", isDirectory: true)
        allowedFolderURL = rootURL.appendingPathComponent("allowed", isDirectory: true)
        outsideFolderURL = rootURL.appendingPathComponent("outside", isDirectory: true)

        try FileManager.default.createDirectory(
            at: allowedFolderURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideFolderURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
        allowedFolderURL = nil
        outsideFolderURL = nil
    }

    func testPercentDecodedNestedFileInsideFolderScopeIsAccepted() throws {
        let imageFolder = allowedFolderURL.appendingPathComponent("image assets", isDirectory: true)
        try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        let imageURL = imageFolder.appendingPathComponent("preview image.png")
        try Data("image".utf8).write(to: imageURL)

        let result = try validator.validate(
            requestPath: "image%20assets/preview%20image.png",
            relativeTo: allowedFolderURL,
            allowedScopes: [.folder(allowedFolderURL)]
        )

        XCTAssertEqual(result.path, imageURL.resolvingSymlinksInPath().path)
    }

    func testExactFileScopeDoesNotGrantSiblingFile() throws {
        let grantedURL = allowedFolderURL.appendingPathComponent("granted.md")
        let siblingURL = allowedFolderURL.appendingPathComponent("sibling.md")
        try Data("granted".utf8).write(to: grantedURL)
        try Data("sibling".utf8).write(to: siblingURL)

        let granted = try validator.validate(
            fileURL: grantedURL,
            allowedScopes: [.file(grantedURL)]
        )
        XCTAssertEqual(granted.path, grantedURL.path)

        XCTAssertThrowsError(
            try validator.validate(fileURL: siblingURL, allowedScopes: [.file(grantedURL)])
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
    }

    func testPlainTraversalOutsideFolderScopeIsRejected() throws {
        let secretURL = outsideFolderURL.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secretURL)

        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "../outside/secret.txt",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
    }

    func testPercentEncodedTraversalOutsideFolderScopeIsRejected() throws {
        let secretURL = outsideFolderURL.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secretURL)

        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "%2e%2E%2Foutside%2Fsecret.txt",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
    }

    func testSymlinkEscapingFolderScopeIsRejected() throws {
        let secretURL = outsideFolderURL.appendingPathComponent("secret.css")
        try Data("body {}".utf8).write(to: secretURL)
        let escapeURL = allowedFolderURL.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: escapeURL,
            withDestinationURL: outsideFolderURL
        )

        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "escape/secret.css",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
    }

    func testSymlinkIsResolvedBeforeDotDotNormalization() throws {
        let linkedDirectory = outsideFolderURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedDirectory,
            withIntermediateDirectories: true
        )
        let secretURL = outsideFolderURL.appendingPathComponent("outside-secret.txt")
        try Data("secret".utf8).write(to: secretURL)
        let linkURL = allowedFolderURL.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: linkedDirectory)

        // POSIX resolution is: allowed/link -> outside/nested, then `..` -> outside.
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "link/../outside-secret.txt",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .outsideAllowedScopes)
        }
    }

    func testSymlinkWhoseTargetRemainsInsideScopeIsAccepted() throws {
        let assetsURL = allowedFolderURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let targetURL = assetsURL.appendingPathComponent("style.css")
        try Data("body {}".utf8).write(to: targetURL)
        let linkURL = allowedFolderURL.appendingPathComponent("style-link.css")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let result = try validator.validate(
            requestPath: "style-link.css",
            relativeTo: allowedFolderURL,
            allowedScopes: [.folder(allowedFolderURL)]
        )

        XCTAssertEqual(result.path, targetURL.path)
    }

    func testMalformedPercentEncodingIsRejected() {
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "asset%2G.png",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .malformedPercentEncoding)
        }
    }

    func testPercentEncodedNULIsRejected() {
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "asset%00.png",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .embeddedNUL)
        }
    }

    func testRemoteSchemesAreRejectedBeforeFileAccess() {
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "https://example.com/image.png",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .unsupportedScheme("https"))
        }
    }

    func testRemoteFileHostIsRejected() {
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "file://example.com/share/image.png",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .remoteFileHost("example.com"))
        }
    }

    func testRegularFileRequirementRejectsDirectory() {
        XCTAssertThrowsError(
            try validator.validate(
                fileURL: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .targetIsNotRegularFile)
        }
    }

    func testNoAllowedScopesFailsClosed() throws {
        let fileURL = allowedFolderURL.appendingPathComponent("document.md")
        try Data("text".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try validator.validate(fileURL: fileURL, allowedScopes: [])
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .noAllowedScopes)
        }
    }

    func testMissingTargetIsRejectedWithoutBroadeningScope() {
        XCTAssertThrowsError(
            try validator.validate(
                requestPath: "missing.png",
                relativeTo: allowedFolderURL,
                allowedScopes: [.folder(allowedFolderURL)]
            )
        ) { error in
            XCTAssertEqual(error as? LocalPathValidationError, .targetDoesNotExist)
        }
    }
}
