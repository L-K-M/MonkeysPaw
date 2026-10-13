import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantActionMain: MainThread {
    private let lock = NSRecursiveLock()
    private var jobs: [() -> Void] = []
    private var depth = 0
    let queued: Bool

    init(queued: Bool) { self.queued = queued }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return depth > 0 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if queued { jobs.append(work) }
        else { ui(work) }
    }

    func ui(_ work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        depth += 1
        defer { depth -= 1 }
        work()
    }

    func drain() {
        lock.lock()
        defer { lock.unlock() }
        while !jobs.isEmpty { ui(jobs.removeFirst()) }
    }
}

final class AssistantCountingEntropy: EntropySource {
    private var next: UInt8 = 0
    func bytes(count: Int) throws -> [UInt8] {
        next &+= 1
        return Array(repeating: next, count: count)
    }
}

final class AssistantClientReturns: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}

struct AssistantObservedClient: AssistantClient {
    let client: AssistantClient
    let returned: AssistantClientReturns
    func perform(_ request: AssistantRequest, using connection: ProviderConnection) async throws -> AssistantResponse {
        defer { returned.record() }
        return try await client.perform(request, using: connection)
    }
    func perform(_ request: AssistantRequest, using connection: ProviderConnection,
                 deadline: ContinuousClock.Instant) async throws -> AssistantResponse {
        defer { returned.record() }
        return try await client.perform(request, using: connection, deadline: deadline)
    }
    func listModels(using connection: ProviderConnection) async throws -> AssistantModelPage {
        try await client.listModels(using: connection)
    }
    func listModels(using connection: ProviderConnection, afterID: String?,
                    deadline: ContinuousClock.Instant) async throws -> AssistantModelPage {
        try await client.listModels(using: connection, afterID: afterID, deadline: deadline)
    }
}

final class AssistantActionHarness {
    let provider = ProviderHarness()
    let editor = EditorHarness()
    let main: AssistantActionMain
    let work = ConnectionQueuedWork()
    let time = ConnectionManualClock()
    let returned = AssistantClientReturns()
    let transport: ConnectionTransport
    let service: AssistantService
    let kind: ProviderKind
    var libraryID = UUID()
    var access = AssistantAccessState.privatePrompt
    lazy var model = AssistantModel(service: service, main: main,
        context: { [unowned self] in self.context }, now: { [time] in time.now() })

    var context: AssistantContext {
        AssistantContext(libraryID: libraryID, profile: service.selectedProfile,
                         editor: editor.model.assistantSnapshot, access: access)
    }

    init(_ replies: [ConnectionTransport.Reply] = [.held], source: String? = nil,
         kind: ProviderKind = .openaiCompatible, queued: Bool = true,
         budget: Duration = Limits.llmBudget) throws {
        self.kind = kind
        main = AssistantActionMain(queued: queued)
        transport = ConnectionTransport(replies)
        service = AssistantService(providerSettings: provider.service,
            anthropic: AssistantObservedClient(client: AnthropicClient(transport: transport), returned: returned),
            openAICompatible: AssistantObservedClient(client: OpenAIClient(transport: transport,
                providerState: ProviderStateStore(files: provider.files)), returned: returned),
            work: work, main: main, timeout: Limits.modelListTimeout, now: { [time] in time.now() },
            actionBudget: budget, clock: editor.h.clock, entropy: AssistantCountingEntropy())
        try provider.service.save(ProviderDraft(kind: kind, modelID: "manual-model", key: .replace(SecretValue("test-key"))))
        if let source { try editor.open(source) }
    }

    func ui(_ body: () -> Void) { main.ui(body) }
    func settle() { main.drain(); work.drain(); main.drain() }
    func changed() { ui { model.contextChanged() }; settle() }

    func sent(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            settle()
            if await transport.snapshot().count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Assistant request did not reach transport", file: file, line: line)
    }

    func phase(_ phase: AssistantPhase, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            settle()
            if model.state.phase == phase { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected assistant phase \(phase), got \(model.state.phase)", file: file, line: line)
    }

    func replyQueued(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if main.count > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Assistant reply did not queue on MainThread", file: file, line: line)
    }

    func clientReturned(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if returned.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Assistant client did not return", file: file, line: line)
    }

    func artifact(body: String = "Use {{topic}}.", notes: String = "Changed the prompt.") async throws {
        await transport.release(try response(["title": "Candidate", "description": "Reusable template",
            "tags": [], "fields": [], "body": body, "notes": notes]))
    }

    func response(_ output: [String: Any]) throws -> HTTPResponse {
        let text = try AssistantOutputFixtures.json(output)
        let object: [String: Any] = kind == .anthropic
            ? ["stop_reason": "end_turn", "content": [["type": "text", "text": text]],
               "usage": ["input_tokens": 11, "output_tokens": 7]]
            : ["choices": [["finish_reason": "stop", "message": ["content": text]]],
               "usage": ["prompt_tokens": 11, "completion_tokens": 7]]
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: object))
    }

    func messages(at index: Int = 0) async throws -> [[String: String]] {
        let requests = await transport.snapshot()
        let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil)
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        return kind == .anthropic ? messages : Array(messages.dropFirst())
    }
}
