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
    private struct Record: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case file, folder }
        let kind: Kind
        let pathHint: String
        let data: Data
    }

    private let defaults: UserDefaults
    private let key = "SecurityScopedBookmarks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ url: URL, asFolder: Bool) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
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

            var stale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: record.data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }

            let standardizedURL = resolvedURL.standardizedFileURL
            guard record.pathHint == requestedPath || standardizedURL.path == requestedPath else {
                continue
            }

            if stale, let renewed = try? standardizedURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
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
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            let lease = SecurityScopedLease(url: url)
            leases.append(lease)
            scopes.append(record.kind == .folder ? .folder(url) : .file(url))
            if stale, let renewed = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                refreshedRecords.append(.init(kind: record.kind, pathHint: url.path, data: renewed))
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
}
