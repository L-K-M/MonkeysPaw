import Foundation
@testable import MonkeysPawCore

/// Executes the production async client from the existing synchronous full-corpus dispatcher.
enum LlmExchangeFixtureCorpus {
    static func consume(_ envelope: [String: LlmFixtureJSON], at directory: URL) throws -> (files: [String], expectations: Int) {
        let result = ExchangeResult()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.value = .success(try await run(envelope, at: directory)) }
            catch { result.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.value!.get()
    }

    private static func run(_ root: [String: LlmFixtureJSON], at directory: URL) async throws -> (files: [String], expectations: Int) {
        try keys(root, ["schema", "category", "kind", "setup", "actions"])
        guard try member(root, "schema").integer == 1, try member(root, "category").string == "llm",
              try member(root, "kind").string == "exchange" else { throw invalid }
        let setup = try member(root, "setup").object
        try keys(setup, ["capabilityState", "nowUTC", "nowMonotonicMs"])
        guard try member(setup, "capabilityState").isNull else { throw invalid }
        let utcString = try member(setup, "nowUTC").string
        let formatter = ISO8601DateFormatter()
        guard utcString.utf8.count == 20, let utc = formatter.date(from: utcString),
              formatter.string(from: utc) == utcString else { throw invalid }
        let originMs = try nonnegative(member(setup, "nowMonotonicMs"))
        let origin = ContinuousClock.now.advanced(by: .milliseconds(originMs))
        let actions = try member(root, "actions").array
        guard !actions.isEmpty else { throw invalid }
        var files = [String]()
        var expectations = LlmFixtureJSON.object(setup).expectationCount
        func bytes(_ value: LlmFixtureJSON, extensions: [String]) throws -> Data {
            let name = try LlmFixtureCorpus.sourceName(value, extensions: extensions)
            guard !files.contains(name) else { throw invalid }
            files.append(name)
            return try Data(contentsOf: directory.appendingPathComponent(name))
        }
        func text(_ value: LlmFixtureJSON, extensions: [String]) throws -> String {
            let data = try bytes(value, extensions: extensions)
            let text = String(decoding: data, as: UTF8.self)
            guard Data(text.utf8) == data else { throw invalid }
            return text
        }
        for item in actions {
            let action = try item.object
            try keys(action, ["profile", "intent", "budgetMs", "exchanges", "expected"])
            let profile = try member(action, "profile").object
            try keys(profile, ["id", "kind", "baseURL", "modelID", "key"])
            guard let uuid = UUID(uuidString: try member(profile, "id").string),
                  let provider = ProviderKind(rawValue: try member(profile, "kind").string), provider == .anthropic else { throw invalid }
            let key = try nullableString(member(profile, "key"))
            let connection = ProviderConnection(profileID: ProviderProfileID(uuid), kind: provider,
                baseURL: try ProviderSettings.normalizeBaseURL(member(profile, "baseURL").string, kind: provider),
                modelID: try member(profile, "modelID").string, key: key.map(SecretValue.init))
            let intent = try member(action, "intent").object
            let kind = try member(intent, "kind").string
            let request: AssistantRequest?
            let afterID: String?
            if kind == "models" {
                try keys(intent, ["kind", "afterID"])
                afterID = try nullableString(member(intent, "afterID"))
                request = nil
            } else {
                afterID = nil
                let dataKeys: Set<String>
                switch kind {
                case "write": dataKeys = ["brief"]
                case "review": dataKeys = ["source"]
                case "improve": dataKeys = ["source", "instruction", "selectedFindings"]
                default: throw invalid
                }
                try keys(intent, dataKeys.union(["kind", "effort", "transcript", "feedback"]))
                let effortString = try nullableString(member(intent, "effort"))
                let effort = effortString.flatMap(AssistantEffort.init(rawValue:))
                guard effortString == nil || effort != nil else { throw invalid }
                let task: AssistantAction
                switch kind {
                case "write": task = .write(brief: try text(member(intent, "brief"), extensions: [".txt"]))
                case "review": task = .review(source: try text(member(intent, "source"), extensions: [".md"]))
                default:
                    let source = try text(member(intent, "source"), extensions: [".md"])
                    let selected = try LlmOutputDecoder.review(from: text(member(intent, "selectedFindings"), extensions: [".json"]), source: source)
                    task = .improve(source: source, instruction: try text(member(intent, "instruction"), extensions: [".txt"]), selectedFindings: selected.findings)
                }
                let transcript = try member(intent, "transcript").array.map { value -> AssistantMessage in
                    let turn = try value.object
                    try keys(turn, ["role", "source"])
                    guard let role = AssistantMessage.Role(rawValue: try member(turn, "role").string) else { throw invalid }
                    return AssistantMessage(role: role, content: try text(member(turn, "source"), extensions: [".txt"]))
                }
                let feedbackValue = try member(intent, "feedback")
                let feedback = feedbackValue.isNull ? nil : try text(feedbackValue, extensions: [".txt"])
                request = AssistantRequest(action: task, effort: effort, transcript: transcript, feedback: feedback)
            }
            let budgetValue = try member(action, "budgetMs")
            let budget = budgetValue.isNull ? nil : try budgetValue.integer
            guard budget == nil || (-300_000...300_000).contains(budget!) else { throw invalid }
            let frameValues = try member(action, "exchanges").array
            var frames = [ExchangeFrame]()
            for value in frameValues {
                let frame = try value.object
                try keys(frame, ["elapsedMs", "request", "response"])
                let sendMs = try nonnegative(member(frame, "elapsedMs"))
                let golden = try member(frame, "request").object
                try keys(golden, ["method", "url", "headers", "requestByteCap", "responseByteCap", "deadlineMs", "body"])
                guard ["GET", "POST"].contains(try member(golden, "method").string) else { throw invalid }
                _ = try member(golden, "url").string
                let headers = try headerMap(member(golden, "headers"), lowercase: true)
                let requestCap = try positive(member(golden, "requestByteCap"))
                let responseCap = try positive(member(golden, "responseByteCap"))
                let deadlineMs = try member(golden, "deadlineMs").integer
                let bodyValue = try member(golden, "body")
                let body = bodyValue.isNull ? nil : try bytes(bodyValue, extensions: [".json"])
                let response = try member(frame, "response").object
                let receiveMs = try nonnegative(member(response, "elapsedMs"))
                guard receiveMs >= sendMs else { throw invalid }
                let reply: ExchangeFrame.Reply
                if let failure = response["failure"] {
                    try keys(response, ["elapsedMs", "failure"])
                    reply = .failure(try transportError(failure.string))
                } else {
                    try keys(response, ["elapsedMs", "status", "headers", "body"])
                    let status = try member(response, "status").integer
                    guard (100...599).contains(status) else { throw invalid }
                    reply = .response(HTTPResponse(statusCode: status, headers: try headerMap(member(response, "headers")),
                        body: try bytes(member(response, "body"), extensions: [".bin", ".json", ".txt"])))
                }
                frames.append(ExchangeFrame(sendMs: sendMs, receiveMs: receiveMs, method: try member(golden, "method").string,
                    url: try member(golden, "url").string, headers: headers, requestCap: requestCap, responseCap: responseCap,
                    deadlineMs: deadlineMs, body: body, reply: reply))
                expectations += LlmFixtureJSON.object(golden).expectationCount + 1
            }
            let expected = try member(action, "expected").object
            try keys(expected, ["output", "page", "usage", "error", "requestCount", "cache"])
            guard try ["output", "page", "error"].filter({ !(try member(expected, $0)).isNull }).count == 1,
                  try nonnegative(member(expected, "requestCount")) == frames.count else { throw invalid }
            let cache = try member(expected, "cache").object
            try keys(cache, ["format", "writes"])
            guard try member(cache, "format").string == "json_schema", try member(cache, "writes").integer == 0 else { throw invalid }
            let clock = ExchangeClock(origin: origin, utc: utc)
            let transport = ExchangeTransport(frames: frames, clock: clock)
            let client = AnthropicClient(transport: transport, clock: clock.clock)
            var output: AssistantResponse?
            var page: AssistantModelPage?
            var error: AssistantError?
            do {
                if let request {
                    if let budget { output = try await client.perform(request, using: connection, deadline: origin.advanced(by: .milliseconds(budget))) }
                    else { output = try await client.perform(request, using: connection) }
                } else if let budget {
                    page = try await client.listModels(using: connection, afterID: afterID, deadline: origin.advanced(by: .milliseconds(budget)))
                } else if afterID != nil {
                    page = try await client.listModels(using: connection, afterID: afterID, deadline: origin.advanced(by: Limits.modelListTimeout))
                } else { page = try await client.listModels(using: connection) }
            } catch let failure as AssistantError { error = failure }
            if let violation = await transport.violation { throw violation }
            guard await transport.count == frames.count else { throw mismatch("call count") }
            let expectedError = try member(expected, "error")
            guard try errorSnapshot(error).bytes() == expectedError.bytes() else { throw mismatch("typed error") }
            let outputValue = try member(expected, "output")
            if outputValue.isNull { guard output == nil else { throw mismatch("unexpected output") } }
            else {
                let outputGolden = try outputValue.object
                try keys(outputGolden, ["kind", "source"])
                let outputKind = try member(outputGolden, "kind").string
                guard outputKind == (kind == "review" ? "review" : "artifact"), let output else { throw invalid }
                let golden = try JSONDecoder().decode(LlmFixtureJSON.self, from: bytes(member(outputGolden, "source"), extensions: [".json"]))
                try LlmFixtureCorpus.validateResult(golden, outputKind: outputKind)
                guard try LlmFixtureCorpus.snapshot(output.output).bytes() == golden.bytes() else { throw mismatch("typed output") }
                expectations += golden.expectationCount
            }
            let pageValue = try member(expected, "page")
            if !pageValue.isNull { guard kind == "models" else { throw invalid }; try validatePage(pageValue.object) }
            guard try pageSnapshot(page).bytes() == pageValue.bytes() else { throw mismatch("model page") }
            let usage = try member(expected, "usage")
            if !usage.isNull {
                let usage = try usage.object
                try keys(usage, ["inputTokens", "outputTokens"])
                _ = try nonnegative(member(usage, "inputTokens")); _ = try nonnegative(member(usage, "outputTokens"))
            }
            guard try usageSnapshot(output?.usage).bytes() == usage.bytes() else { throw mismatch("optional usage") }
            try validateError(expectedError)
            expectations += LlmFixtureJSON.object(expected).expectationCount
        }
        return (files, expectations)
    }

    private static func validatePage(_ page: [String: LlmFixtureJSON]) throws {
        try keys(page, ["models", "hasMore", "firstID", "lastID"])
        _ = try member(page, "hasMore").boolean
        _ = try nullableString(member(page, "firstID")); _ = try nullableString(member(page, "lastID"))
        for value in try member(page, "models").array {
            let model = try value.object
            try keys(model, ["id", "displayName"])
            _ = try member(model, "id").string; _ = try nullableString(member(model, "displayName"))
        }
    }
    private static func validateError(_ value: LlmFixtureJSON) throws {
        if value.isNull { return }
        let error = try value.object
        let payload: Set<String>
        switch try member(error, "code").string {
        case "transport": payload = ["transport"]; _ = try transportError(member(error, "transport").string)
        case "unexpectedStop": payload = ["reason"]; _ = try member(error, "reason").string
        case "providerFailure": payload = ["status"]; _ = try member(error, "status").integer
        case "rateLimited":
            payload = ["retryAfter"]
            let retry = try member(error, "retryAfter")
            if !retry.isNull {
                switch retry {
                case .integer(let value): guard value >= 0 else { throw invalid }
                case .number(let value): guard value >= 0, value.isFinite else { throw invalid }
                default: throw invalid
                }
            }
        case "notConfigured", "authentication", "modelNotFound", "overloaded", "truncated", "declined", "emptyResponse", "invalidOutput": payload = []
        default: throw invalid
        }
        try keys(error, payload.union(["code"]))
    }
    private static func errorSnapshot(_ error: AssistantError?) -> LlmFixtureJSON {
        guard let error else { return .null }
        var result: [String: LlmFixtureJSON] = [:]
        switch error {
        case .transport(let value): result = ["code": .string("transport"), "transport": .string(value.rawValue)]
        case .unexpectedStop(let value): result = ["code": .string("unexpectedStop"), "reason": .string(value)]
        case .providerFailure(let value): result = ["code": .string("providerFailure"), "status": .integer(value)]
        case .rateLimited(let value): result = ["code": .string("rateLimited"), "retryAfter": value.map(LlmFixtureJSON.number) ?? .null]
        default: result = ["code": .string(error.description)]
        }
        return .object(result)
    }
    private static func pageSnapshot(_ page: AssistantModelPage?) -> LlmFixtureJSON {
        guard let page else { return .null }
        return .object(["models": .array(page.models.map { .object(["id": .string($0.id), "displayName": $0.displayName.map(LlmFixtureJSON.string) ?? .null]) }),
            "hasMore": .boolean(page.hasMore), "firstID": page.firstID.map(LlmFixtureJSON.string) ?? .null, "lastID": page.lastID.map(LlmFixtureJSON.string) ?? .null])
    }
    private static func usageSnapshot(_ usage: AssistantTokenUsage?) -> LlmFixtureJSON {
        guard let usage else { return .null }
        return .object(["inputTokens": .integer(usage.inputTokens), "outputTokens": .integer(usage.outputTokens)])
    }
    private static func headerMap(_ value: LlmFixtureJSON, lowercase: Bool = false) throws -> [String: String] {
        let headers = try value.object.mapValues { try $0.string }
        guard headers.keys.allSatisfy({ !$0.isEmpty && (!lowercase || $0 == $0.lowercased()) }) else { throw invalid }
        return headers
    }
    private static func nullableString(_ value: LlmFixtureJSON) throws -> String? { value.isNull ? nil : try value.string }
    private static func nonnegative(_ value: LlmFixtureJSON) throws -> Int {
        let value = try value.integer
        guard value >= 0 else { throw invalid }; return value
    }
    private static func positive(_ value: LlmFixtureJSON) throws -> Int {
        let value = try nonnegative(value)
        guard value > 0 else { throw invalid }; return value
    }
    private static var invalid: Error { LlmFixtureCorpus.Failure.invalidCorpus }
    private static func mismatch(_ field: String) -> Error { LlmFixtureCorpus.Failure.mismatch("exchange: " + field) }
    private static func member(_ value: [String: LlmFixtureJSON], _ key: String) throws -> LlmFixtureJSON { try LlmFixtureCorpus.member(value, key) }
    private static func keys(_ value: [String: LlmFixtureJSON], _ required: Set<String>) throws { try LlmFixtureCorpus.keys(value, required) }
    private static func transportError(_ code: String) throws -> HTTPTransportError {
        switch code {
        case "invalidRequest": return .invalidRequest
        case "invalidURL": return .invalidURL
        case "insecureURL": return .insecureURL
        case "credentialsInURL": return .credentialsInURL
        case "serverMismatch": return .serverMismatch
        case "redirectRefused": return .redirectRefused
        case "requestTooLarge": return .requestTooLarge
        case "responseTooLarge": return .responseTooLarge
        case "deadlineExceeded": return .deadlineExceeded
        case "cancelled": return .cancelled
        case "invalidResponse": return .invalidResponse
        case "networkFailure": return .networkFailure
        default: throw invalid
        }
    }

    private struct ExchangeFrame: Sendable {
        enum Reply: Sendable { case response(HTTPResponse), failure(HTTPTransportError) }
        let sendMs: Int, receiveMs: Int
        let method: String, url: String
        let headers: [String: String]
        let requestCap: Int, responseCap: Int, deadlineMs: Int
        let body: Data?
        let reply: Reply
    }
    private actor ExchangeTransport: HTTPTransporting {
        let frames: [ExchangeFrame]
        let clock: ExchangeClock
        private(set) var count = 0
        private(set) var violation: Error?
        init(frames: [ExchangeFrame], clock: ExchangeClock) { self.frames = frames; self.clock = clock }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let index = count
            count += 1
            guard index < frames.count else {
                let failure = mismatch("unexpected automatic request")
                violation = failure
                throw failure
            }
            let frame = frames[index]
            let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
            guard clock.elapsed == frame.sendMs, request.method.rawValue == frame.method,
                  Array(request.url.absoluteString.utf8) == Array(frame.url.utf8), headers == frame.headers,
                  request.requestByteCap == frame.requestCap, request.responseByteCap == frame.responseCap,
                  request.deadline == clock.origin.advanced(by: .milliseconds(frame.deadlineMs)),
                  request.body == frame.body else {
                let failure = mismatch("raw HTTP request")
                violation = failure
                throw failure
            }
            clock.elapsed = frame.receiveMs
            switch frame.reply { case .response(let response): return response; case .failure(let failure): throw failure }
        }
    }
    private final class ExchangeClock: @unchecked Sendable {
        let origin: ContinuousClock.Instant
        private let utc: Date
        private let lock = NSLock()
        private var milliseconds = 0
        init(origin: ContinuousClock.Instant, utc: Date) { self.origin = origin; self.utc = utc }
        var elapsed: Int {
            get { lock.lock(); defer { lock.unlock() }; return milliseconds }
            set { lock.lock(); defer { lock.unlock() }; milliseconds = newValue }
        }
        var clock: AssistantClock { AssistantClock(monotonic: { self.origin.advanced(by: .milliseconds(self.elapsed)) },
                                                   utc: { self.utc.addingTimeInterval(Double(self.elapsed) / 1000) }) }
    }
    private final class ExchangeResult: @unchecked Sendable {
        // The semaphore publishes this single writer's result before the caller reads it.
        var value: Result<(files: [String], expectations: Int), Error>?
    }
}
