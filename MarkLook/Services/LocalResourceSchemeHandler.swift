import Foundation
import UniformTypeIdentifiers
import WebKit

final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private final class SchemeTaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask

        init(_ task: any WKURLSchemeTask) {
            self.task = task
        }
    }

    private let loader: LocalResourceLoader
    private let queue = DispatchQueue(
        label: "com.example.MarkLook.local-resources",
        qos: .userInitiated
    )

    init(
        documentURL: URL,
        scopes: [LocalResourceScope],
        resourceAuthority: String,
        dependencyLoaded: @escaping @Sendable (URL) -> Void
    ) {
        loader = LocalResourceLoader(
            documentURL: documentURL,
            scopes: scopes,
            resourceAuthority: resourceAuthority,
            dependencyLoaded: dependencyLoaded
        )
    }

    func update(documentURL: URL, scopes: [LocalResourceScope]) {
        loader.update(documentURL: documentURL, scopes: scopes)
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let box = SchemeTaskBox(urlSchemeTask)
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        loader.begin(identifier)

        queue.async { [loader] in
            do {
                let response = try loader.response(for: box.task.request)
                guard !loader.isCancelled(identifier) else {
                    loader.finish(identifier)
                    return
                }
                DispatchQueue.main.async {
                    guard !loader.isCancelled(identifier) else {
                        loader.finish(identifier)
                        return
                    }
                    box.task.didReceive(response.urlResponse)
                    box.task.didReceive(response.data)
                    box.task.didFinish()
                    loader.finish(identifier)
                }
            } catch {
                guard !loader.isCancelled(identifier) else {
                    loader.finish(identifier)
                    return
                }
                DispatchQueue.main.async {
                    guard !loader.isCancelled(identifier) else {
                        loader.finish(identifier)
                        return
                    }
                    box.task.didFailWithError(error)
                    loader.finish(identifier)
                }
            }
        }
    }

    func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        loader.cancel(ObjectIdentifier(urlSchemeTask as AnyObject))
    }
}

final class LocalResourceLoader: @unchecked Sendable {
    private struct State {
        var documentURL: URL
        var scopes: [LocalResourceScope]
        var cancelledTasks = Set<ObjectIdentifier>()
    }

    private let lock = NSLock()
    private var state: State
    private let validator = LocalPathValidator()
    private let resourceAuthority: String
    private let dependencyLoaded: @Sendable (URL) -> Void

    init(
        documentURL: URL,
        scopes: [LocalResourceScope],
        resourceAuthority: String,
        dependencyLoaded: @escaping @Sendable (URL) -> Void
    ) {
        state = State(documentURL: documentURL, scopes: scopes)
        self.resourceAuthority = resourceAuthority.lowercased()
        self.dependencyLoaded = dependencyLoaded
    }

    func update(documentURL: URL, scopes: [LocalResourceScope]) {
        lock.withLock {
            state.documentURL = documentURL
            state.scopes = scopes
        }
    }

    func begin(_ identifier: ObjectIdentifier) {
        _ = lock.withLock { state.cancelledTasks.remove(identifier) }
    }

    func cancel(_ identifier: ObjectIdentifier) {
        _ = lock.withLock { state.cancelledTasks.insert(identifier) }
    }

    func finish(_ identifier: ObjectIdentifier) {
        _ = lock.withLock { state.cancelledTasks.remove(identifier) }
    }

    func isCancelled(_ identifier: ObjectIdentifier) -> Bool {
        lock.withLock { state.cancelledTasks.contains(identifier) }
    }

    func response(for request: URLRequest) throws -> (urlResponse: HTTPURLResponse, data: Data) {
        guard let requestURL = request.url,
              requestURL.scheme?.lowercased() == "mark-resource",
              (request.httpMethod ?? "GET").uppercased() == "GET",
              requestURL.user == nil,
              requestURL.password == nil,
              requestURL.port == nil
        else { throw URLError(.badURL) }

        let data: Data
        let sourceURL: URL
        if requestURL.host?.lowercased() == "bundle" {
            guard requestURL.query == nil, requestURL.fragment == nil else {
                throw URLError(.badURL)
            }
            sourceURL = try bundledURL(for: requestURL.path)
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } else {
            guard requestURL.host?.lowercased() == resourceAuthority,
                  requestURL.path == "/open"
            else { throw URLError(.noPermissionsToReadFile) }
            guard let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
            else { throw URLError(.badURL) }
            let queryItems = components.queryItems ?? []
            let sourceItems = queryItems.filter { $0.name == "source" }
            let revisionItems = queryItems.filter { $0.name == "revision" }
            guard sourceItems.count == 1,
                  let source = sourceItems[0].value,
                  !source.isEmpty,
                  revisionItems.count <= 1,
                  queryItems.count == sourceItems.count + revisionItems.count,
                  requestURL.fragment == nil
            else { throw URLError(.badURL) }

            let snapshot = lock.withLock { (state.documentURL, state.scopes) }
            sourceURL = try validator.validate(
                requestPath: source,
                relativeTo: snapshot.0.deletingLastPathComponent(),
                allowedScopes: snapshot.1
            )
            let rawData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            if sourceURL.pathExtension.lowercased() == "css" {
                guard let css = String(data: rawData, encoding: .utf8),
                      !css.unicodeScalars.contains(where: { $0.value == 0 })
                else { throw URLError(.cannotDecodeContentData) }
                let rewritten = CSSResourceRewriter().rewrite(
                    css,
                    stylesheetURL: sourceURL,
                    resourceAuthority: requestURL.host ?? ""
                )
                data = Data(rewritten.utf8)
            } else {
                data = rawData
            }
            dependencyLoaded(sourceURL)
        }

        let mimeType = mimeType(for: sourceURL)
        let headers = [
            "Content-Type": mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store, max-age=0",
            "X-Content-Type-Options": "nosniff",
        ]
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { throw URLError(.cannotParseResponse) }
        return (response, data)
    }

    private func bundledURL(for rawPath: String) throws -> URL {
        guard let resourceRoot = Bundle.main.resourceURL else { throw URLError(.fileDoesNotExist) }
        let relative = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components[0] == "katex",
              components[1] == "fonts",
              components[2].hasPrefix("KaTeX_"),
              ["woff2", "woff", "ttf"].contains(
                  URL(fileURLWithPath: components[2]).pathExtension.lowercased()
              ),
              !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
        else { throw URLError(.badURL) }

        let filename = components[2]
        let candidates = [
            resourceRoot.appendingPathComponent(relative),
            resourceRoot.appendingPathComponent("ThirdParty/KaTeX/fonts").appendingPathComponent(filename),
            resourceRoot.appendingPathComponent("KaTeX/fonts").appendingPathComponent(filename),
            resourceRoot.appendingPathComponent(filename),
        ]
        guard let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw URLError(.fileDoesNotExist)
        }
        return match
    }

    private func mimeType(for url: URL) -> String {
        // UTType reports only `text/css`; make the response's strict decoding contract
        // explicit so WebKit never guesses a legacy stylesheet encoding.
        if url.pathExtension.lowercased() == "css" {
            return "text/css; charset=utf-8"
        }
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return switch url.pathExtension.lowercased() {
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
