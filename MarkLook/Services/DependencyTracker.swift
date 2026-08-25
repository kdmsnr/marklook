import Foundation

final class DependencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = Set<URL>()
    private var callback: (@Sendable (URL) -> Void)?

    func record(_ url: URL) {
        let normalized = url.standardizedFileURL
        let shouldNotify = lock.withLock {
            let inserted = loaded.insert(normalized).inserted
            return (inserted, callback)
        }
        if shouldNotify.0 { shouldNotify.1?(normalized) }
    }

    func onNewDependency(_ callback: @escaping @Sendable (URL) -> Void) {
        let existing = lock.withLock {
            self.callback = callback
            return loaded
        }
        existing.forEach(callback)
    }

    func reset() {
        lock.withLock { loaded.removeAll() }
    }
}
