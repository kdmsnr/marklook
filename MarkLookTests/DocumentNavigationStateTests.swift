import CryptoKit
import Foundation
import XCTest
@testable import MarkLook

final class DocumentNavigationStateTests: XCTestCase {
    func testReopeningOriginalFileRejectsLegacyRedirectToAnotherFile() throws {
        try withDefaults { defaults in
            let first = URL(fileURLWithPath: "/tmp/first.md")
            let second = URL(fileURLWithPath: "/tmp/second.md")
            let legacyState = DocumentNavigationState(
                currentURL: second,
                backHistory: [first],
                forwardHistory: []
            )
            // Reproduce the old format: A's key contains the state after A → B.
            defaults.set(
                try PropertyListEncoder().encode(legacyState),
                forKey: legacyStorageKey(for: first)
            )

            XCTAssertNil(DocumentNavigationState.restore(for: first, defaults: defaults))
        }
    }

    func testSavingDestinationDoesNotOverwriteOriginalDocumentsHistory() throws {
        try withDefaults { defaults in
            let first = URL(fileURLWithPath: "/tmp/first.md")
            let second = URL(fileURLWithPath: "/tmp/second.html")
            let third = URL(fileURLWithPath: "/tmp/third.csv")
            let initialState = DocumentNavigationState(
                currentURL: first, backHistory: [], forwardHistory: []
            )
            initialState.save(defaults: defaults)
            let secondState = DocumentNavigationState(
                currentURL: second, backHistory: [first], forwardHistory: []
            )
            secondState.save(defaults: defaults)
            let thirdState = DocumentNavigationState(
                currentURL: third, backHistory: [first, second], forwardHistory: []
            )
            thirdState.save(defaults: defaults)

            XCTAssertEqual(DocumentNavigationState.restore(for: first, defaults: defaults), initialState)
            XCTAssertEqual(DocumentNavigationState.restore(for: second, defaults: defaults), secondState)
            XCTAssertEqual(DocumentNavigationState.restore(for: third, defaults: defaults), thirdState)
        }
    }

    func testMatchingDocumentRestoresBackAndForwardHistory() throws {
        try withDefaults { defaults in
            let state = DocumentNavigationState(
                currentURL: URL(fileURLWithPath: "/tmp/current.md"),
                backHistory: [URL(string: "file:///tmp/previous.md#section")!],
                forwardHistory: [URL(fileURLWithPath: "/tmp/next.tsv")]
            )
            state.save(defaults: defaults)

            XCTAssertEqual(
                DocumentNavigationState.restore(for: state.currentURL, defaults: defaults),
                state
            )
        }
    }

    func testRequestedFragmentIsNotReplacedBySavedFragment() throws {
        try withDefaults { defaults in
            let savedURL = URL(string: "file:///tmp/document.md#old")!
            DocumentNavigationState(
                currentURL: savedURL, backHistory: [], forwardHistory: []
            ).save(defaults: defaults)

            XCTAssertNil(DocumentNavigationState.restore(
                for: URL(string: "file:///tmp/document.md#requested")!, defaults: defaults
            ))
            XCTAssertNil(DocumentNavigationState.restore(
                for: URL(fileURLWithPath: "/tmp/document.md"), defaults: defaults
            ))
            XCTAssertEqual(
                DocumentNavigationState.restore(for: savedURL, defaults: defaults)?.currentURL,
                savedURL
            )
        }
    }

    func testRestoredHistoryNormalizesPathsAndFiltersUnsupportedURLs() throws {
        try withDefaults { defaults in
            let current = URL(string: "file:///tmp/folder/../current.md#section")!
            let previous = URL(string: "file:///tmp/folder/../previous.html#heading")!
            let next = URL(fileURLWithPath: "/tmp/next.markdown")
            let remote = URL(string: "https://example.com/document.md")!
            let unsupported = URL(fileURLWithPath: "/tmp/image.png")
            DocumentNavigationState(
                currentURL: current,
                backHistory: [remote, previous, unsupported],
                forwardHistory: [unsupported, next, remote]
            ).save(defaults: defaults)

            let normalizedURL = URL(string: "file:///tmp/current.md#section")!
            let restored = try XCTUnwrap(DocumentNavigationState.restore(
                for: normalizedURL, defaults: defaults
            ))
            XCTAssertEqual(restored.currentURL, normalizedURL)
            XCTAssertEqual(restored.backHistory, [URL(string: "file:///tmp/previous.html#heading")!])
            XCTAssertEqual(restored.forwardHistory, [next])
        }
    }

    func testMissingOrCorruptHistoryIsIgnored() throws {
        try withDefaults { defaults in
            let url = URL(fileURLWithPath: "/tmp/document.md")
            XCTAssertNil(DocumentNavigationState.restore(for: url, defaults: defaults))
            defaults.set(Data("invalid property list".utf8), forKey: legacyStorageKey(for: url))
            XCTAssertNil(DocumentNavigationState.restore(for: url, defaults: defaults))
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "DocumentNavigationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func legacyStorageKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "DocumentNavigation.\(digest)"
    }
}
