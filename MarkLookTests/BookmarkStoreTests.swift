import Foundation
import XCTest
@testable import MarkLook

final class BookmarkStoreTests: XCTestCase {
    func testResolveAllPreservesOldPathHintWhenRefreshingMovedBookmark() throws {
        try withDefaults { defaults in
            let oldURL = fileURL("old/document.md")
            let movedURL = fileURL("new/document.md")
            let originalData = Data([0x01])
            let renewedData = Data([0x02])
            try persist(
                [.init(kind: .file, pathHint: oldURL.path, data: originalData)],
                in: defaults
            )

            let store = BookmarkStore(
                defaults: defaults,
                resolveBookmark: { data in
                    switch data {
                    case originalData:
                        .init(url: movedURL, isStale: true)
                    case renewedData:
                        .init(url: movedURL, isStale: false)
                    default:
                        throw TestBookmarkError.unavailable
                    }
                },
                createBookmark: { url in
                    guard url.standardizedFileURL == movedURL else {
                        throw TestBookmarkError.unavailable
                    }
                    return renewedData
                }
            )

            let all = store.resolveAll()
            let persistedRecords = try loadRecords(from: defaults)
            let fileResolution = try XCTUnwrap(store.resolveFile(matching: oldURL))

            XCTAssertEqual(all.scopes.count, 1)
            guard case let .file(scopeURL) = try XCTUnwrap(all.scopes.first) else {
                return XCTFail("Expected a file scope")
            }
            XCTAssertEqual(scopeURL, movedURL)
            XCTAssertEqual(persistedRecords, [
                .init(kind: .file, pathHint: oldURL.path, data: renewedData),
            ])
            XCTAssertEqual(fileResolution.url, movedURL)
        }
    }

    func testResolveAllRetainsTemporarilyUnresolvableRecords() throws {
        try withDefaults { defaults in
            let unavailableData = Data([0x10])
            let availableData = Data([0x20])
            let availableURL = fileURL("available/document.md")
            let records: [StoredBookmarkRecord] = [
                .init(
                    kind: .file,
                    pathHint: fileURL("offline/document.md").path,
                    data: unavailableData
                ),
                .init(kind: .file, pathHint: availableURL.path, data: availableData),
            ]
            try persist(records, in: defaults)

            let store = BookmarkStore(
                defaults: defaults,
                resolveBookmark: { data in
                    guard data == availableData else {
                        throw TestBookmarkError.unavailable
                    }
                    return .init(url: availableURL, isStale: false)
                },
                createBookmark: { _ in throw TestBookmarkError.unavailable }
            )

            let resolution = store.resolveAll()

            XCTAssertEqual(resolution.scopes.count, 1)
            XCTAssertEqual(try loadRecords(from: defaults), records)
        }
    }

    private let storageKey = "SecurityScopedBookmarks.v1"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "BookmarkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func persist(
        _ records: [StoredBookmarkRecord],
        in defaults: UserDefaults
    ) throws {
        defaults.set(try PropertyListEncoder().encode(records), forKey: storageKey)
    }

    private func loadRecords(from defaults: UserDefaults) throws -> [StoredBookmarkRecord] {
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        return try PropertyListDecoder().decode([StoredBookmarkRecord].self, from: data)
    }

    private func fileURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: "/tmp/marklook-bookmark-tests/\(relativePath)")
            .standardizedFileURL
    }
}

private struct StoredBookmarkRecord: Codable, Equatable {
    enum Kind: String, Codable { case file, folder }

    let kind: Kind
    let pathHint: String
    let data: Data
}

private enum TestBookmarkError: Error {
    case unavailable
}
