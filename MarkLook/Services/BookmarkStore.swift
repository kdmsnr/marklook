import CryptoKit
import Foundation

struct BookmarkResolution: Sendable {
    let scopes: [LocalResourceScope]
    let leases: [SecurityScopedLease]
}

struct BookmarkFileResolution: Sendable {
    let url: URL
    let lease: SecurityScopedLease
}

final class SecurityScopedLease: @unchecked Sendable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

struct BookmarkStore: @unchecked Sendable {
    struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
    }

    typealias BookmarkResolver = @Sendable (Data) throws -> ResolvedBookmark
    typealias BookmarkCreator = @Sendable (URL) throws -> Data

    private struct Record: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case file, folder }
        let kind: Kind
        let pathHint: String
        let data: Data
    }

    private let defaults: UserDefaults
    private let resolveBookmark: BookmarkResolver
    private let createBookmark: BookmarkCreator
    private let key = "SecurityScopedBookmarks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resolveBookmark = Self.resolveBookmarkData
        createBookmark = Self.createBookmarkData
    }

    init(
        defaults: UserDefaults,
        resolveBookmark: @escaping BookmarkResolver,
        createBookmark: @escaping BookmarkCreator
    ) {
        self.defaults = defaults
        self.resolveBookmark = resolveBookmark
        self.createBookmark = createBookmark
    }

    func save(_ url: URL, asFolder: Bool) throws {
        let data = try createBookmark(url)
        var records = loadRecords()
        records.removeAll { $0.pathHint == url.standardizedFileURL.path }
        records.append(.init(
            kind: asFolder ? .folder : .file,
            pathHint: url.standardizedFileURL.path,
            data: data
        ))
        persist(records)
    }

    /// Resolves a previously granted file bookmark while retaining access for the caller's use.
    /// Matching the stored path hint also lets a bookmark follow a file that has since moved.
    func resolveFile(matching requestedURL: URL) -> BookmarkFileResolution? {
        let requestedPath = requestedURL.standardizedFileURL.path
        var records = loadRecords()

        for index in records.indices.reversed() {
            let record = records[index]
            guard case .file = record.kind else { continue }

            guard let resolved = try? resolveBookmark(record.data) else { continue }

            let standardizedURL = resolved.url.standardizedFileURL
            guard record.pathHint == requestedPath || standardizedURL.path == requestedPath else {
                continue
            }

            if resolved.isStale, let renewed = try? createBookmark(standardizedURL) {
                records[index] = .init(
                    kind: .file,
                    pathHint: standardizedURL.path,
                    data: renewed
                )
                persist(records)
            }

            return BookmarkFileResolution(
                url: standardizedURL,
                lease: SecurityScopedLease(url: standardizedURL)
            )
        }

        return nil
    }

    func resolveAll() -> BookmarkResolution {
        var scopes: [LocalResourceScope] = []
        var leases: [SecurityScopedLease] = []
        var refreshedRecords: [Record] = []

        for record in loadRecords() {
            guard let resolved = try? resolveBookmark(record.data) else {
                // Bookmark resolution can fail transiently when a volume or network location is
                // unavailable. Keep the record so a later launch can recover it.
                refreshedRecords.append(record)
                continue
            }
            let url = resolved.url.standardizedFileURL
            let lease = SecurityScopedLease(url: url)
            leases.append(lease)
            scopes.append(record.kind == .folder ? .folder(url) : .file(url))
            if resolved.isStale, let renewed = try? createBookmark(url) {
                // `pathHint` is also the alias used by Open Recent. Preserve the pre-move path
                // while refreshing the bookmark data so that the old recent URL still resolves to
                // the bookmark's new destination.
                refreshedRecords.append(.init(
                    kind: record.kind,
                    pathHint: record.pathHint,
                    data: renewed
                ))
            } else {
                refreshedRecords.append(record)
            }
        }
        persist(refreshedRecords)
        return BookmarkResolution(scopes: scopes, leases: leases)
    }

    private func persist(_ records: [Record]) {
        if let encoded = try? PropertyListEncoder().encode(records) {
            defaults.set(encoded, forKey: key)
        }
    }

    private func loadRecords() -> [Record] {
        guard let data = defaults.data(forKey: key),
              let records = try? PropertyListDecoder().decode([Record].self, from: data)
        else { return [] }
        return records
    }

    private static func resolveBookmarkData(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedBookmark(url: url, isStale: stale)
    }

    private static func createBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
