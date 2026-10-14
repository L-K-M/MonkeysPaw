import Foundation

/// One non-streaming Messages call. §7.2's HTTP-400 format probes belong only
/// to OpenAI-compatible providers, so Anthropic never retries automatically.
public struct AnthropicClient: AssistantClient, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let transport: HTTPTransporting
    private let clock: AssistantClock

    public init(transport: HTTPTransporting) { self.init(transport: transport, clock: .live) }

    init(transport: HTTPTransporting, clock: AssistantClock) {
        self.transport = transport
        self.clock = clock
    }

    public func perform(_ request: AssistantRequest, using connection: ProviderConnection) async throws -> AssistantResponse {
        try await perform(request, using: connection, deadline: clock.monotonic().advanced(by: Limits.llmBudget))
    }

    public func perform(_ request: AssistantRequest, using connection: ProviderConnection,
                        deadline: ContinuousClock.Instant) async throws -> AssistantResponse {
        try checkActive(until: deadline)
        guard !connection.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AssistantError.notConfigured
        }
        let headers = try headers(for: connection, operation: .messages)
        let prompt: String
        let schema: Data
        switch request.action {
        case .write:
            prompt = AssistantPrompts.write
            schema = LlmArtifact.jsonSchema
        case .review:
            prompt = AssistantPrompts.review
            schema = LlmReview.jsonSchema
        case .improve:
            prompt = AssistantPrompts.improve
            schema = LlmArtifact.jsonSchema
        }

        guard let schemaObject = try? JSONSerialization.jsonObject(with: schema) else { throw AssistantError.invalidOutput }
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schemaObject]]
        if let effort = request.effort { outputConfig["effort"] = effort.rawValue }
        var body: [String: Any] = ["model": connection.modelID, "max_tokens": 16_000,
            "system": prompt, "messages": request.wireMessages.map(\.wireValue), "output_config": outputConfig]
        if isOfficial(connection) { body["fallbacks"] = "default" }
        guard let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw AssistantError.invalidOutput
        }
        let httpRequest = try httpRequest(url: connection.completionURL, method: .post,
            headers: headers, body: encoded, deadline: deadline)
        let response = try await AssistantHTTP.send(httpRequest, through: transport, nowUTC: clock.utc)
        let text = try outputText(from: response.body)
        let output: AssistantOutput
        switch request.action {
        case .write, .improve: output = .artifact(try LlmOutputDecoder.artifact(from: text))
        case .review(let source): output = .review(try LlmOutputDecoder.review(from: text, source: source))
        }
        let usage = (try? JSONDecoder().decode(UsageEnvelope.self, from: response.body))?.usage
        let tokenUsage = usage.flatMap {
            $0.inputTokens >= 0 && $0.outputTokens >= 0
                ? AssistantTokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) : nil
        }
        return AssistantResponse(output: output, usage: tokenUsage)
    }

    public func listModels(using connection: ProviderConnection) async throws -> AssistantModelPage {
        try await listModels(using: connection, afterID: nil,
                             deadline: clock.monotonic().advanced(by: Limits.modelListTimeout))
    }

    public func listModels(using connection: ProviderConnection, afterID: String?,
                           deadline: ContinuousClock.Instant) async throws -> AssistantModelPage {
        try checkActive(until: deadline)
        let request = try httpRequest(url: AssistantModelList.url(for: connection, afterID: afterID), method: .get,
            headers: headers(for: connection, operation: .models), deadline: deadline)
        let response = try await AssistantHTTP.send(request, through: transport, nowUTC: clock.utc)
        try checkActive(until: deadline)
        guard let page = try? JSONDecoder().decode(ModelPage.self, from: response.body),
              page.data.allSatisfy({ AssistantModelList.validID($0.id) }),
              [page.firstID, page.lastID].compactMap({ $0 }).allSatisfy(AssistantModelList.validID) else {
            throw AssistantError.invalidOutput
        }
        try checkActive(until: deadline)
        return AssistantModelPage(models: page.data.map { ModelDescriptor(id: $0.id, displayName: $0.displayName) },
            hasMore: page.hasMore ?? false, firstID: page.firstID, lastID: page.lastID)
    }

    private func checkActive(until deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw AssistantError.transport(.cancelled) }
        guard clock.monotonic() < deadline else { throw AssistantError.transport(.deadlineExceeded) }
    }

    private enum Operation { case messages, models }

    private func headers(for connection: ProviderConnection, operation: Operation) throws -> [String: String] {
        guard connection.kind == .anthropic else { throw AssistantError.notConfigured }
        guard let key = connection.key, key.withValue({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw AssistantError.authentication }
        var headers = ["x-api-key": key.withValue { $0 }, "anthropic-version": "2023-06-01"]
        if operation == .messages {
            headers["Content-Type"] = "application/json"
            if isOfficial(connection) { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        }
        return headers
    }

    private func isOfficial(_ connection: ProviderConnection) -> Bool {
        connection.baseURL.host == "api.anthropic.com"
    }

    private func httpRequest(url: URL, method: HTTPMethod, headers: [String: String], body: Data? = nil,
                             deadline: ContinuousClock.Instant) throws -> HTTPRequest {
        do { return try HTTPRequest(url: url, method: method, headers: headers, body: body, deadline: deadline) }
        catch let error as HTTPTransportError { throw AssistantError.transport(error) }
        catch { throw AssistantError.transport(.invalidRequest) }
    }

    private func outputText(from body: Data) throws -> String {
        guard !body.isEmpty, !body.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw AssistantError.emptyResponse }
        guard let stop = try? JSONDecoder().decode(StopEnvelope.self, from: body) else { throw AssistantError.invalidOutput }
        // Stop outcomes take precedence over parsing any artifact, even when a
        // truncated/refused response happens to contain valid-looking JSON.
        switch stop.stopReason {
        case "end_turn", "stop_sequence", nil: break
        case "max_tokens", "model_context_window_exceeded": throw AssistantError.truncated
        case "refusal": throw AssistantError.declined
        case let reason?: throw AssistantError.unexpectedStop(reason)
        }
        guard let envelope = try? JSONDecoder().decode(TextEnvelope.self, from: body) else { throw AssistantError.invalidOutput }
        let text = envelope.content.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.emptyResponse }
        guard stop.stopReason != nil else { throw AssistantError.unexpectedStop("missing") }
        return text
    }

    private struct StopEnvelope: Decodable {
        let stopReason: String?
        enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }
    }

    private struct TextEnvelope: Decodable {
        let content: [ContentBlock]
    }

    private struct ContentBlock: Decodable {
        let text: String?

        enum CodingKeys: String, CodingKey { case type, text }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let type = try values.decode(String.self, forKey: .type)
            text = type == "text" ? try values.decode(String.self, forKey: .text) : nil
        }
    }

    private struct UsageEnvelope: Decodable {
        let usage: Usage?
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    private struct ModelPage: Decodable {
        let data: [Model]
        let hasMore: Bool?
        let firstID: String?
        let lastID: String?
        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case firstID = "first_id"
            case lastID = "last_id"
        }
        struct Model: Decodable {
            let id: String
            let displayName: String?
            enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
        }
    }

    public var description: String { "<Anthropic client>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["client": description]) }
}
