import Foundation
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import MonkeysPawCore

struct ScenarioRequestTrace {
    let method: String
    let path: String
    let status: Int
    let body: ScenarioValue?
    let localPaths: [String]
}

/// Every response starts at Hummingbird's real router. A rewrite can corrupt
/// bytes around that request; it cannot manufacture a successful mutation.
final class InProcessHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let clients: [String: any TestClientProtocol]
    private let lock = NSLock()
    private var recorded: [ScenarioRequestTrace] = []
    private var rewrites: [ScenarioRewrite] = []
    private var hooks: [(method: String, path: String, run: () async throws -> Void)] = []
    var library: ScenarioDisk?

    init(clients: [String: any TestClientProtocol]) { self.clients = clients }
    var traces: [ScenarioRequestTrace] { locked { recorded } }
    var pendingRewrites: Int { locked { rewrites.count + hooks.count } }
    func resetMetrics() { locked { recorded.removeAll() } }
    func rewrite(_ value: ScenarioRewrite) { locked { rewrites.append(value) } }
    func before(method: HTTPMethod, path: String, run: @escaping () async throws -> Void) {
        locked { hooks.append((method.rawValue, path, run)) }
    }

    func send(_ request: MonkeysPawCore.HTTPRequest) async throws -> MonkeysPawCore.HTTPResponse {
        try Task.checkCancellation()
        guard ContinuousClock.now < request.deadline else { throw HTTPTransportError.deadlineExceeded }
        guard case .sync(let server) = request.urlPolicy,
              request.url.scheme == server.baseURL.scheme, request.url.host == server.baseURL.host,
              request.url.port == server.baseURL.port, request.url.user == nil, request.url.password == nil,
              let host = request.url.host, let client = clients[host], server.baseURL.path.isEmpty else {
            throw HTTPTransportError.serverMismatch
        }
        guard (request.body?.count ?? 0) <= request.requestByteCap else { throw HTTPTransportError.requestTooLarge }
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let uri = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        if let hook = takeHook(method: request.method.rawValue, path: uri) { try await hook() }
        let requestRewrite = takeRewrite(phase: .request, method: request.method.rawValue, path: uri)
        let responseRewrite = takeRewrite(phase: .response, method: request.method.rawValue, path: uri)
        var bytes = request.body
        if let requestRewrite {
            guard let body = bytes else { throw ScenarioFailure.invalid("request patch without body") }
            bytes = try JSONEncoder().encode(JSONDecoder().decode(ScenarioValue.self, from: body).patching(requestRewrite.patch))
        }
        guard (bytes?.count ?? 0) <= request.requestByteCap else { throw HTTPTransportError.requestTooLarge }
        var fields = HTTPFields()
        for (name, value) in request.headers {
            guard let field = HTTPField.Name(name) else { throw HTTPTransportError.invalidRequest }
            fields[field] = value
        }
        let body = bytes.map { ByteBuffer(bytes: $0) }
        let safeBody = uri.hasPrefix("/api/v1/prompts/") ? try bytes.map { try JSONDecoder().decode(ScenarioValue.self, from: $0) } : nil
        let localPaths = try library?.listFiles().map(\.relativePath) ?? []
        guard let method = HTTPTypes.HTTPRequest.Method(rawValue: request.method.rawValue) else { throw HTTPTransportError.invalidRequest }
        let requestHeaders = fields
        let response = try await withScenarioDeadline(request.deadline) {
            try await client.executeRequest(uri: uri, method: method, headers: requestHeaders, body: body)
        }
        locked { recorded.append(.init(method: request.method.rawValue, path: uri, status: response.status.code, body: safeBody, localPaths: localPaths)) }
        guard response.body.readableBytes <= request.responseByteCap else { throw HTTPTransportError.responseTooLarge }
        var received = Data(response.body.readableBytesView)
        if let responseRewrite {
            guard response.status == .ok else { throw ScenarioFailure.invalid("response patch requires real success") }
            received = try JSONEncoder().encode(JSONDecoder().decode(ScenarioValue.self, from: received).patching(responseRewrite.patch))
        }
        guard received.count <= request.responseByteCap else { throw HTTPTransportError.responseTooLarge }
        try Task.checkCancellation()
        var headers: [String: String] = [:]
        for field in response.headers { headers[field.name.rawName] = field.value }
        return .init(statusCode: response.status.code, headers: headers, body: received)
    }

    private func takeRewrite(phase: ScenarioRewrite.Phase, method: String, path: String) -> ScenarioRewrite? {
        locked {
            guard let index = rewrites.firstIndex(where: { $0.phase == phase && $0.method.rawValue == method && $0.path == path }) else { return nil }
            return rewrites.remove(at: index)
        }
    }

    private func takeHook(method: String, path: String) -> (() async throws -> Void)? {
        locked {
            guard let index = hooks.firstIndex(where: { $0.method == method && $0.path == path }) else { return nil }
            return hooks.remove(at: index).run
        }
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation()
    }
}

func withScenarioDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(until: deadline, clock: .continuous)
            throw HTTPTransportError.deadlineExceeded
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
