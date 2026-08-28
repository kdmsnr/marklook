import Foundation
import WebKit

enum RemoteResourceLoadError: Error, Equatable, Sendable {
    case invalidRequest
    case disallowedURL
    case tooManyRedirects
    case invalidResponse
    case unsupportedContentType(String?)
    case responseTooLarge
    case invalidStylesheet
    case transport(URLError.Code)
}

struct RemoteResourceResponse: @unchecked Sendable {
    let sourceURL: URL
    let urlResponse: HTTPURLResponse
    let data: Data
}

/// Serves explicitly allowed HTTPS resources to WebKit without giving the web content direct
/// network access. The app performs every request and redirect; WebKit sees only this custom
/// scheme and receives a small, app-owned response header set.
final class RemoteResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private final class SchemeTaskBox: @unchecked Sendable {
        let task: any WKURLSchemeTask

        init(_ task: any WKURLSchemeTask) {
            self.task = task
        }
    }

    private struct OperationEntry {
        let token: UUID
        let operation: RemoteResourceFetchOperation
    }

    private let loader: RemoteResourceLoader
    private let lock = NSLock()
    private var operations: [ObjectIdentifier: OperationEntry] = [:]

    init(resourceAuthority: String, policy: RemoteContentPolicy) {
        loader = RemoteResourceLoader(
            resourceAuthority: resourceAuthority,
            policy: policy
        )
        super.init()
    }

    @MainActor
    func update(policy: RemoteContentPolicy) {
        loader.update(policy: policy)
        let activeOperations = lock.withLock { operations.values.map(\.operation) }
        activeOperations.forEach { $0.cancelIfDisallowed() }
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let box = SchemeTaskBox(urlSchemeTask)
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let sourceURL: URL
        do {
            sourceURL = try loader.sourceURL(for: box.task.request)
        } catch let error as RemoteResourceLoadError {
            fail(box, with: error)
            return
        } catch {
            fail(box, with: .invalidRequest)
            return
        }

        let token = UUID()
        let operation = RemoteResourceFetchOperation(
            requestURL: box.task.request.url!,
            sourceURL: sourceURL,
            loader: loader
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.complete(
                    identifier: identifier,
                    token: token,
                    task: box,
                    result: result
                )
            }
        }
        let inserted = lock.withLock { () -> Bool in
            guard operations[identifier] == nil else { return false }
            operations[identifier] = OperationEntry(token: token, operation: operation)
            return true
        }
        guard inserted else {
            fail(box, with: .invalidRequest)
            return
        }
        operation.start()
    }

    func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let operation = lock.withLock { operations.removeValue(forKey: identifier)?.operation }
        operation?.cancel()
    }

    @MainActor
    private func complete(
        identifier: ObjectIdentifier,
        token: UUID,
        task: SchemeTaskBox,
        result: Result<RemoteResourceResponse, RemoteResourceLoadError>
    ) {
        let shouldDeliver = lock.withLock { () -> Bool in
            guard operations[identifier]?.token == token else { return false }
            operations.removeValue(forKey: identifier)
            return true
        }
        guard shouldDeliver else { return }

        switch result {
        case let .success(response):
            // Policy updates and delivery both run on the main actor in the app. Revalidate here
            // as well as during fetching so a response queued just before revocation cannot be
            // handed to WebKit after the host has been removed.
            guard loader.allows(response.sourceURL) else {
                task.task.didFailWithError(RemoteResourceLoadError.disallowedURL)
                return
            }
            task.task.didReceive(response.urlResponse)
            task.task.didReceive(response.data)
            task.task.didFinish()
        case let .failure(error):
            task.task.didFailWithError(error)
        }
    }

    private func fail(_ task: SchemeTaskBox, with error: RemoteResourceLoadError) {
        DispatchQueue.main.async {
            task.task.didFailWithError(error)
        }
    }
}

final class RemoteResourceLoader: @unchecked Sendable {
    static let maximumResponseBytes = 25 * 1_024 * 1_024
    static let maximumRedirects = 5

    struct ResponseMetadata: Sendable, Equatable {
        let mimeType: String
        let isStylesheet: Bool
    }

    private let resourceAuthority: String
    private let policyStore: RemoteContentPolicyStore

    init(resourceAuthority: String, policy: RemoteContentPolicy) {
        self.resourceAuthority = resourceAuthority.lowercased()
        policyStore = RemoteContentPolicyStore(policy: policy)
    }

    func update(policy: RemoteContentPolicy) {
        policyStore.update(policy)
    }

    func allows(_ url: URL) -> Bool {
        policyStore.allows(url)
    }

    func sourceURL(for request: URLRequest) throws -> URL {
        guard (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil,
              request.httpBodyStream == nil,
              let resourceURL = request.url,
              let sourceURL = RemoteResourceURL.sourceURL(
                  from: resourceURL,
                  expectedAuthority: resourceAuthority
              )
        else { throw RemoteResourceLoadError.invalidRequest }
        guard policyStore.allows(sourceURL) else {
            throw RemoteResourceLoadError.disallowedURL
        }
        return sourceURL
    }

    func remoteRequest(for sourceURL: URL) throws -> URLRequest {
        guard policyStore.allows(sourceURL) else {
            throw RemoteResourceLoadError.disallowedURL
        }
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    func redirectedRequest(to sourceURL: URL, redirectCount: Int) throws -> URLRequest {
        guard redirectCount < Self.maximumRedirects else {
            throw RemoteResourceLoadError.tooManyRedirects
        }
        return try remoteRequest(for: sourceURL)
    }

    func metadata(for response: HTTPURLResponse) throws -> ResponseMetadata {
        guard response.statusCode == 200 else {
            throw RemoteResourceLoadError.invalidResponse
        }
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw RemoteResourceLoadError.responseTooLarge
        }

        let mimeType = Self.normalizedMIMEType(from: response)
        guard let mimeType, Self.isAllowedMIMEType(mimeType) else {
            throw RemoteResourceLoadError.unsupportedContentType(mimeType)
        }
        return ResponseMetadata(
            mimeType: mimeType,
            isStylesheet: mimeType == "text/css"
        )
    }

    func response(
        for requestURL: URL,
        sourceURL: URL,
        upstreamResponse: HTTPURLResponse,
        data rawData: Data
    ) throws -> RemoteResourceResponse {
        guard policyStore.allows(sourceURL) else {
            throw RemoteResourceLoadError.disallowedURL
        }
        guard rawData.count <= Self.maximumResponseBytes else {
            throw RemoteResourceLoadError.responseTooLarge
        }

        let metadata = try metadata(for: upstreamResponse)
        let data: Data
        let contentType: String
        if metadata.isStylesheet {
            guard let css = String(data: rawData, encoding: .utf8),
                  !css.unicodeScalars.contains(where: { $0.value == 0 })
            else { throw RemoteResourceLoadError.invalidStylesheet }
            let rewritten = CSSResourceRewriter().rewrite(
                css,
                stylesheetURL: sourceURL,
                resourceAuthority: resourceAuthority
            )
            data = Data(rewritten.utf8)
            contentType = "text/css; charset=utf-8"
        } else {
            data = rawData
            contentType = metadata.mimeType
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw RemoteResourceLoadError.responseTooLarge
        }

        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store, max-age=0",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'",
        ]
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { throw RemoteResourceLoadError.invalidResponse }
        return RemoteResourceResponse(
            sourceURL: sourceURL,
            urlResponse: response,
            data: data
        )
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = [
            "Accept": acceptHeader,
            "Accept-Encoding": "identity",
        ]
        return configuration
    }

    private static let acceptHeader = "image/*, text/css, font/*, audio/*, video/*"

    private static let legacyFontMIMETypes: Set<String> = [
        "application/font-sfnt",
        "application/font-woff",
        "application/vnd.ms-fontobject",
        "application/x-font-opentype",
        "application/x-font-ttf",
        "application/x-font-woff",
    ]

    private static func normalizedMIMEType(from response: HTTPURLResponse) -> String? {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Type") else {
            return nil
        }
        let value = rawValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value?.isEmpty == false ? value : nil
    }

    private static func isAllowedMIMEType(_ mimeType: String) -> Bool {
        mimeType == "text/css"
            || mimeType.hasPrefix("image/")
            || mimeType.hasPrefix("font/")
            || mimeType.hasPrefix("audio/")
            || mimeType.hasPrefix("video/")
            || legacyFontMIMETypes.contains(mimeType)
    }
}

private final class RemoteContentPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: RemoteContentPolicy

    init(policy: RemoteContentPolicy) {
        self.policy = policy
    }

    func update(_ policy: RemoteContentPolicy) {
        lock.withLock { self.policy = policy }
    }

    func allows(_ url: URL) -> Bool {
        lock.withLock { policy.allows(url) }
    }
}

private final class RemoteResourceFetchOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum State: Equatable {
        case idle
        case running
        case finished
        case cancelled
    }

    private let requestURL: URL
    private let initialSourceURL: URL
    private let loader: RemoteResourceLoader
    private let completion: @Sendable (
        Result<RemoteResourceResponse, RemoteResourceLoadError>
    ) -> Void
    private let lock = NSLock()
    private var state = State.idle
    private var currentSourceURL: URL
    private var redirectCount = 0
    private var receivedData = Data()
    private var upstreamResponse: HTTPURLResponse?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?

    init(
        requestURL: URL,
        sourceURL: URL,
        loader: RemoteResourceLoader,
        completion: @escaping @Sendable (
            Result<RemoteResourceResponse, RemoteResourceLoadError>
        ) -> Void
    ) {
        self.requestURL = requestURL
        initialSourceURL = sourceURL
        currentSourceURL = sourceURL
        self.loader = loader
        self.completion = completion
    }

    func start() {
        do {
            let request = try loader.remoteRequest(for: initialSourceURL)
            let delegateQueue = OperationQueue()
            delegateQueue.name = "com.example.MarkLook.remote-resource"
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: RemoteResourceLoader.makeSessionConfiguration(),
                delegate: self,
                delegateQueue: delegateQueue
            )
            let task = session.dataTask(with: request)
            let shouldStart = lock.withLock { () -> Bool in
                guard state == .idle else { return false }
                state = .running
                self.session = session
                dataTask = task
                return true
            }
            guard shouldStart else {
                session.invalidateAndCancel()
                return
            }
            task.resume()
        } catch let error as RemoteResourceLoadError {
            finish(.failure(error))
        } catch {
            finish(.failure(.invalidRequest))
        }
    }

    func cancel() {
        let values = lock.withLock { () -> (URLSession?, URLSessionDataTask?) in
            guard state == .idle || state == .running else { return (nil, nil) }
            state = .cancelled
            let values = (session, dataTask)
            session = nil
            dataTask = nil
            return values
        }
        values.1?.cancel()
        values.0?.invalidateAndCancel()
    }

    func cancelIfDisallowed() {
        let sourceURL = lock.withLock { currentSourceURL }
        if !loader.allows(sourceURL) {
            finish(.failure(.disallowedURL), cancellingNetwork: true)
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            guard let redirectURL = request.url else {
                throw RemoteResourceLoadError.invalidResponse
            }
            let count = lock.withLock { redirectCount }
            let redirected = try loader.redirectedRequest(
                to: redirectURL,
                redirectCount: count
            )
            lock.withLock {
                redirectCount += 1
                currentSourceURL = redirectURL
            }
            completionHandler(redirected)
        } catch let error as RemoteResourceLoadError {
            completionHandler(nil)
            finish(.failure(error))
        } catch {
            completionHandler(nil)
            finish(.failure(.invalidResponse))
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let response = response as? HTTPURLResponse else {
                throw RemoteResourceLoadError.invalidResponse
            }
            _ = try loader.metadata(for: response)
            let sourceURL = lock.withLock { currentSourceURL }
            guard loader.allows(sourceURL) else {
                throw RemoteResourceLoadError.disallowedURL
            }
            lock.withLock { upstreamResponse = response }
            completionHandler(.allow)
        } catch let error as RemoteResourceLoadError {
            completionHandler(.cancel)
            finish(.failure(error))
        } catch {
            completionHandler(.cancel)
            finish(.failure(.invalidResponse))
        }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceededLimit = lock.withLock { () -> Bool in
            guard state == .running else { return false }
            let (nextCount, overflow) = receivedData.count.addingReportingOverflow(data.count)
            guard !overflow, nextCount <= RemoteResourceLoader.maximumResponseBytes else {
                return true
            }
            receivedData.append(data)
            return false
        }
        if exceededLimit {
            dataTask.cancel()
            finish(.failure(.responseTooLarge))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let code = (error as? URLError)?.code ?? .unknown
            finish(.failure(.transport(code)))
            return
        }

        let snapshot = lock.withLock {
            (currentSourceURL, upstreamResponse, receivedData)
        }
        guard let upstreamResponse = snapshot.1 else {
            finish(.failure(.invalidResponse))
            return
        }
        do {
            let response = try loader.response(
                for: requestURL,
                sourceURL: snapshot.0,
                upstreamResponse: upstreamResponse,
                data: snapshot.2
            )
            finish(.success(response))
        } catch let error as RemoteResourceLoadError {
            finish(.failure(error))
        } catch {
            finish(.failure(.invalidResponse))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(
        _ result: Result<RemoteResourceResponse, RemoteResourceLoadError>,
        cancellingNetwork: Bool = false
    ) {
        let transition = lock.withLock { () -> (Bool, URLSession?, URLSessionDataTask?) in
            guard state == .idle || state == .running else { return (false, nil, nil) }
            state = .finished
            let session = self.session
            let dataTask = self.dataTask
            self.session = nil
            self.dataTask = nil
            return (true, session, dataTask)
        }
        guard transition.0 else { return }
        if cancellingNetwork {
            transition.2?.cancel()
            transition.1?.invalidateAndCancel()
        }
        completion(result)
        if !cancellingNetwork {
            transition.1?.finishTasksAndInvalidate()
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
