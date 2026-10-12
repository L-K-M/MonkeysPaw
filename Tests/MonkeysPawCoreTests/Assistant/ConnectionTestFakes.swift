import Foundation
@testable import MonkeysPawCore

final class ConnectionMainQueue: MainThread {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    var onEnqueue: (() -> Void)?
    private(set) var isRunning = false

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        jobs.append(work)
        lock.unlock()
        onEnqueue?()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    func drain() {
        lock.lock()
        let pending = jobs
        jobs = []
        lock.unlock()
        isRunning = true
        pending.forEach { $0() }
        isRunning = false
    }
}

struct ConnectionBackground: BackgroundWork {
    private let queue = DispatchQueue(label: "connection-test-work")
    func run(_ work: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: work)) }
}

final class ConnectionQueuedWork: BackgroundWork {
    private var jobs: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { jobs.append(work) }
    func drain() {
        let pending = jobs
        jobs = []
        pending.forEach { $0() }
    }
}

final class ConnectionManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }
    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }
}

actor ConnectionTransport: HTTPTransporting {
    enum Reply {
        case response(HTTPResponse)
        case failure(HTTPTransportError)
        case unsafeFailure(String)
        case waiting
        /// Deliberately ignores cancellation until the test releases it.
        case held
    }
    private var replies: [Reply]
    private let afterSend: @Sendable () -> Void
    private var requests: [HTTPRequest] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var held: [CheckedContinuation<HTTPResponse, Never>] = []
    private var cancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [Reply], afterSend: @escaping @Sendable () -> Void = {}) {
        self.replies = replies
        self.afterSend = afterSend
    }

    func snapshot() -> [HTTPRequest] { requests }
    func waitUntilSent(_ count: Int = 1) async {
        if requests.count >= count { return }
        await withCheckedContinuation { sentWaiters.append((count, $0)) }
    }
    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
    func release(_ response: HTTPResponse) {
        let pending = held
        held = []
        pending.forEach { $0.resume(returning: response) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        for (count, waiter) in sentWaiters where count <= requests.count { waiter.resume() }
        sentWaiters.removeAll { $0.0 <= requests.count }
        afterSend()
        guard !replies.isEmpty else { throw HTTPTransportError.invalidResponse }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .failure(let error): throw error
        case .unsafeFailure(let description): throw UnsafeError(description: description)
        case .held: return await withCheckedContinuation { held.append($0) }
        case .waiting:
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                cancelled = true
                cancellationWaiters.forEach { $0.resume() }
                cancellationWaiters = []
                throw error
            }
            throw HTTPTransportError.deadlineExceeded
        }
    }

    private struct UnsafeError: Error, CustomStringConvertible { let description: String }
}

final class ConnectionHarness {
    let provider = ProviderHarness()
    let main = ConnectionMainQueue()
    let service: AssistantService
    let transport: ConnectionTransport

    init(_ replies: [ConnectionTransport.Reply], work: BackgroundWork = ConnectionBackground(),
         timeout: Duration = Limits.modelListTimeout,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         afterSend: @escaping @Sendable () -> Void = {}) {
        transport = ConnectionTransport(replies, afterSend: afterSend)
        service = AssistantService(providerSettings: provider.service, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: provider.files)),
            work: work, main: main, timeout: timeout, now: now)
    }

    func draft(_ kind: ProviderKind = .openaiCompatible) -> ProviderDraft {
        ProviderDraft(kind: kind, modelID: "manual-model", key: .replace(SecretValue("test-key")))
    }

    static func page(_ models: [[String: Any]] = [], more: Bool = false, last: String? = nil) throws -> HTTPResponse {
        var object: [String: Any] = ["data": models, "has_more": more, "unknown": ["ignored": true]]
        object["last_id"] = last
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
