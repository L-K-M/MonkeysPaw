import Foundation

/// Non-streaming Chat Completions with two possible format probes. Every attempt
/// shares one deadline; only a validated lower-format success updates capability state.
public struct OpenAIClient: AssistantClient, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let transport: HTTPTransporting
    private let providerState: ProviderStateStore
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(transport: HTTPTransporting, providerState: ProviderStateStore) {
        self.init(transport: transport, providerState: providerState, now: { ContinuousClock.now })
    }

    // A monotonic test clock proves exhausted probes without a five-minute wait.
    init(transport: HTTPTransporting, providerState: ProviderStateStore,
         now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.transport = transport
        self.providerState = providerState
        self.now = now
    }

    public func perform(_ request: AssistantRequest, using connection: ProviderConnection) async throws -> AssistantResponse {
        try await perform(request, using: connection, deadline: now().advanced(by: Limits.llmBudget))
    }

    public func perform(_ request: AssistantRequest, using connection: ProviderConnection,
                        deadline: ContinuousClock.Instant) async throws -> AssistantResponse {
        try checkActive(until: deadline)
        guard !connection.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AssistantError.notConfigured
        }
        let headers = try headers(for: connection, operation: .completions)
        try checkActive(until: deadline)
        let initialFormat: OpenAIResponseFormat
        do { initialFormat = try providerState.format(for: connection) }
        catch {
            StandardErrorLog().write(.warning, "Provider capability cache lookup failed.")
            initialFormat = .jsonSchema
        }

        let prompt: String
        let schema: Data
        let schemaName: String
        switch request.action {
        case .write:
            prompt = AssistantPrompts.write
            schema = LlmArtifact.jsonSchema
            schemaName = "prompt_artifact"
        case .review:
            prompt = AssistantPrompts.review
            schema = LlmReview.jsonSchema
            schemaName = "prompt_review"
        case .improve:
            prompt = AssistantPrompts.improve
            schema = LlmArtifact.jsonSchema
            schemaName = "prompt_artifact"
        }

        guard let schemaObject = try? JSONSerialization.jsonObject(with: schema) else { throw AssistantError.invalidOutput }
        var body: [String: Any] = ["model": connection.modelID,
            "messages": [["role": "system", "content": prompt]] + request.wireMessages.map(\.wireValue)]
        if let effort = request.effort { body["reasoning_effort"] = effort.rawValue }
        var format = initialFormat
        while true {
            try checkActive(until: deadline)
            switch format {
            case .jsonSchema:
                body["response_format"] = ["type": "json_schema", "json_schema":
                    ["name": schemaName, "schema": schemaObject, "strict": true]]
            case .jsonObject: body["response_format"] = ["type": "json_object"]
            case .none: body.removeValue(forKey: "response_format")
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                throw AssistantError.invalidOutput
            }
            let httpRequest = try httpRequest(url: connection.completionURL, method: .post,
                headers: headers, body: encoded, deadline: deadline)
            let response = try await AssistantHTTP.send(httpRequest, through: transport, policy: .formatProbe)
            try checkActive(until: deadline)
            if response.statusCode == 400 {
                guard let lower = format.lower, rejects(format, body: response.body) else {
                    throw AssistantError.providerFailure(statusCode: 400)
                }
                format = lower
                continue
            }

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
            // Receipt owns the deadline; parsing must retain an on-time response.
            guard !Task.isCancelled else { throw AssistantError.transport(.cancelled) }
            if format != initialFormat {
                do { try providerState.recordSuccess(format, for: connection) }
                catch { StandardErrorLog().write(.warning, "Provider capability cache update failed.") }
            }
            return AssistantResponse(output: output, usage: tokenUsage)
        }
    }

    public func listModels(using connection: ProviderConnection) async throws -> AssistantModelPage {
        try await listModels(using: connection, afterID: nil,
                             deadline: now().advanced(by: Limits.modelListTimeout))
    }

    public func listModels(using connection: ProviderConnection, afterID: String?,
                           deadline: ContinuousClock.Instant) async throws -> AssistantModelPage {
        let request = try httpRequest(url: AssistantModelList.url(for: connection, afterID: afterID), method: .get,
            headers: headers(for: connection, operation: .models), deadline: deadline)
        try checkActive(until: deadline)
        let response = try await AssistantHTTP.send(request, through: transport)
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

    private enum Operation { case completions, models }

    private func headers(for connection: ProviderConnection, operation: Operation) throws -> [String: String] {
        guard connection.kind == .openaiCompatible else { throw AssistantError.notConfigured }
        var headers = [String: String]()
        if let key = connection.key {
            guard key.withValue({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw AssistantError.authentication
            }
            headers["Authorization"] = key.withValue { "Bearer " + $0 }
        }
        if operation == .completions { headers["Content-Type"] = "application/json" }
        return headers
    }

    private func checkActive(until deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw AssistantError.transport(.cancelled) }
        guard now() < deadline else { throw AssistantError.transport(.deadlineExceeded) }
    }

    private func httpRequest(url: URL, method: HTTPMethod, headers: [String: String], body: Data? = nil,
                             deadline: ContinuousClock.Instant) throws -> HTTPRequest {
        do { return try HTTPRequest(url: url, method: method, headers: headers, body: body, deadline: deadline) }
        catch let error as HTTPTransportError { throw AssistantError.transport(error) }
        catch { throw AssistantError.transport(.invalidRequest) }
    }

    /// A generic 400, invalid schema or unsupported schema keyword is not proof
    /// that this output format is unsupported. Keep the evidence inside the codec.
    private func rejects(_ format: OpenAIResponseFormat, body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        let error = object["error"] as? [String: Any]
        let param = (error?["param"] as? String)?.lowercased()
        let formatParams = ["response_format", "response_format.type"]
        if let param, !formatParams.contains(param) { return false }
        let code = (error?["code"] as? String)?.lowercased()
        let raw = error?["message"] as? String ?? object["error"] as? String ?? ""
        let message = raw.lowercased().replacingOccurrences(of: "[\"'`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: ":", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !["invalid schema", "invalid json schema", "invalid json_schema", "schema keyword", "schema validation"]
            .contains(where: message.contains) else { return false }
        if let param, let code, formatParams.contains(param),
           ["unsupported_parameter", "unsupported_value", "unknown_parameter"].contains(code) { return true }
        return [format.rawValue, "response_format"].contains { subject in
            ["\(subject) is not supported", "\(subject) not supported", "\(subject) is unsupported",
             "\(subject) is not implemented", "\(subject) format is not supported",
             "\(subject) response format is not supported", "does not support \(subject)",
             "doesn't support \(subject)", "unsupported \(subject)", "unknown parameter \(subject)",
             "unrecognized request argument \(subject)", "unrecognized request argument supplied \(subject)",
             "unrecognized parameter \(subject)"]
                .contains { phrase in
                    message.range(of: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "(?!\\w|\\.\\w)",
                        options: .regularExpression) != nil
                }
        }
    }

    private func outputText(from body: Data) throws -> String {
        guard !body.isEmpty, !body.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw AssistantError.emptyResponse }
        guard let stop = try? JSONDecoder().decode(FirstChoice<StopChoice>.self, from: body) else {
            throw AssistantError.invalidOutput
        }
        guard let choice = stop.choice else { throw AssistantError.emptyResponse }
        // Stop outcomes precede content parsing, even for valid-looking JSON.
        switch choice.finishReason {
        case "stop", nil: break
        case "length": throw AssistantError.truncated
        case "content_filter": throw AssistantError.declined
        case let reason?: throw AssistantError.unexpectedStop(reason)
        }
        guard let envelope = try? JSONDecoder().decode(FirstChoice<TextChoice>.self, from: body),
              let message = envelope.choice?.message else { throw AssistantError.invalidOutput }
        if let refusal = message.refusal, !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.declined
        }
        guard let text = message.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.emptyResponse
        }
        guard choice.finishReason != nil else { throw AssistantError.unexpectedStop("missing") }
        return text
    }

    /// Decode only the first choice, including when later choices are malformed.
    private struct FirstChoice<Choice: Decodable>: Decodable {
        let choice: Choice?
        enum CodingKeys: String, CodingKey { case choices }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var choices = try values.nestedUnkeyedContainer(forKey: .choices)
            choice = choices.isAtEnd ? nil : try choices.decode(Choice.self)
        }
    }

    private struct StopChoice: Decodable {
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case finishReason = "finish_reason" }
    }

    private struct TextChoice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String?
            let refusal: String?
        }
    }

    private struct UsageEnvelope: Decodable {
        let usage: Usage?
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "prompt_tokens"
                case outputTokens = "completion_tokens"
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
            enum CodingKeys: String, CodingKey { case id, name; case displayName = "display_name" }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
                    ?? values.decodeIfPresent(String.self, forKey: .name)
            }
        }
    }

    public var description: String { "<OpenAI-compatible client>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["client": description]) }
}
