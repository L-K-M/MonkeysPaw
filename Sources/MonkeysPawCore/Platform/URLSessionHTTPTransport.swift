import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The portable networking driver allowed in Core by §19 B1. Each operation
/// owns an ephemeral session with credentials, cookies and caching disabled.
/// Services consume it only through HTTPTransporting.
public struct URLSessionHTTPTransport: HTTPTransporting {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = try Self.validatedURL(request)
        let transfer = HTTPTransfer(cap: request.responseByteCap, deadline: request.deadline)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, url: url, continuation: continuation)
            }
        } onCancel: {
            transfer.finish(.failure(.cancelled))
        }
    }

    private static func validatedURL(_ request: HTTPRequest) throws -> URL {
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw HTTPTransportError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw HTTPTransportError.credentialsInURL
        }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains("%"), host.unicodeScalars.allSatisfy(\.isASCII) else {
            throw HTTPTransportError.invalidURL
        }
        guard scheme == "https" || ProviderSettings.isLoopback(host) else {
            throw HTTPTransportError.insecureURL
        }

        // swift-corelibs-foundation rejects GET bodies; reject consistently
        // before creating a session on either platform.
        guard request.method != .get || request.body == nil else { throw HTTPTransportError.invalidRequest }
        components.scheme = scheme
        components.host = host
        guard let url = components.url else { throw HTTPTransportError.invalidURL }
        return url
    }
}

final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cap: Int
    private let deadline: ContinuousClock.Instant
    // Protects every mutable field against delegate, deadline and cancellation
    // callbacks. Cancellation, invalidation and resumption happen unlocked.
    private let lock = NSLock()
    private var result: Result<HTTPResponse, HTTPTransportError>?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadlineTask: Task<Void, Never>?
    private var response: HTTPURLResponse?
    private var body = Data()

    init(cap: Int, deadline: ContinuousClock.Instant) {
        self.cap = cap
        self.deadline = deadline
    }

    func start(_ request: HTTPRequest, url: URL, continuation: CheckedContinuation<HTTPResponse, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result.mapError { $0 as Error })
            return
        }
        self.continuation = continuation
        guard ContinuousClock.now < deadline else {
            lock.unlock()
            finish(.failure(.deadlineExceeded))
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        // Linux rounds platform timeouts to whole seconds and resets the idle
        // timer on receipt. The separate ContinuousClock sleeper owns expiry.
        let timeout = max(Limits.httpSessionTimeoutFloor, ceil(seconds) + 1)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.allHTTPHeaderFields = request.headers
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: urlRequest)
        self.session = session
        self.task = task
        deadlineTask = Task { [weak self, deadline] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            self?.finish(.failure(.deadlineExceeded))
        }
        lock.unlock()
        task.resume()
    }

    func finish(_ proposed: Result<HTTPResponse, HTTPTransportError>) {
        lock.lock()
        finishLocked(proposed)()
    }

    // Caller holds the lock. Claim the result before releasing it, then run
    // framework calls and continuation resumption outside the lock.
    private func finishLocked(_ proposed: Result<HTTPResponse, HTTPTransportError>) -> () -> Void {
        guard result == nil else { lock.unlock(); return {} }
        var outcome = proposed
        if case .success = outcome, ContinuousClock.now >= deadline {
            outcome = .failure(.deadlineExceeded)
        }
        result = outcome
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        let deadlineTask = self.deadlineTask
        self.continuation = nil
        self.task = nil
        self.session = nil
        self.deadlineTask = nil
        response = nil
        body = Data()
        lock.unlock()

        return {
            deadlineTask?.cancel()
            task?.cancel()
            // URLSession retains its delegate until invalidation completes.
            session?.invalidateAndCancel()
            continuation?.resume(with: outcome.mapError { $0 as Error })
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // With storage nil, default handling has no stored credential to try
        // and preserves normal TLS server-trust validation.
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(.redirectRefused))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let error: HTTPTransportError?
        if result != nil { error = .cancelled }
        else if ContinuousClock.now >= deadline { error = .deadlineExceeded }
        else if let response = response as? HTTPURLResponse {
            if (300..<400).contains(response.statusCode) { error = .redirectRefused }
            else if response.expectedContentLength > Int64(cap) { error = .responseTooLarge }
            else { self.response = response; error = nil }
        } else { error = .invalidResponse }
        if let error {
            let complete = finishLocked(.failure(error))
            completionHandler(.cancel)
            complete()
        } else {
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let error: HTTPTransportError?
        if ContinuousClock.now >= deadline { error = .deadlineExceeded }
        else if data.count > cap - body.count { error = .responseTooLarge }
        else { body.append(data); error = nil }
        if let error { finishLocked(.failure(error))() }
        else { lock.unlock() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let outcome: Result<HTTPResponse, HTTPTransportError>
        if ContinuousClock.now >= deadline { outcome = .failure(.deadlineExceeded) }
        else if let error = error as? URLError, error.code == .cancelled { outcome = .failure(.cancelled) }
        else if error != nil { outcome = .failure(.networkFailure) }
        else if let response = response ?? task.response as? HTTPURLResponse {
            // Some Foundation implementations suppress the response callback
            // for redirects with no usable Location header.
            if (300..<400).contains(response.statusCode) { outcome = .failure(.redirectRefused) }
            else {
                var headers = [String: String]()
                for (key, value) in response.allHeaderFields {
                    if let name = key as? String, let value = value as? String {
                        headers[name.lowercased()] = value
                    }
                }
                outcome = .success(HTTPResponse(statusCode: response.statusCode, headers: headers, body: body))
            }
        } else { outcome = .failure(.invalidResponse) }
        finishLocked(outcome)()
    }
}
