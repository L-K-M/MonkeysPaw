import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantTranscriptTests: XCTestCase {
    func testArtifactTranscriptRoundTripsEmptyValuesAndEveryFieldKind() throws {
        let special = "\"\\\n\t\u{0} <data> Cafe\u{301} 🐒"
        let fields = [FieldKind.text, .multiline, .choice].map {
            LlmArtifact.Field(name: $0.rawValue, type: $0, label: "", description: "", defaultValue: "",
                options: $0 == .choice ? [FieldOption(label: "", value: special)] : [],
                optional: true, remember: false)
        }
        for artifact in [
            LlmArtifact(title: "", description: "", tags: [], fields: [], body: "", notes: ""),
            LlmArtifact(title: special, description: special, tags: [special], fields: fields, body: special, notes: special)
        ] {
            let message = try AssistantResponse(output: .artifact(artifact)).transcriptMessage()
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(try LlmOutputDecoder.artifact(from: message.content), artifact)
        }
    }

    func testReviewTranscriptRoundTripsEmptyValuesAndEveryFindingKind() throws {
        let special = "\"\\\n\t\u{0} Cafe\u{301} 🐒"
        let findings = LlmRubricCriterion.allCases.flatMap { criterion in
            LlmReviewSeverity.allCases.map {
                LlmReview.Finding(criterion: criterion, severity: $0, quote: special,
                    problem: "", suggestion: special, quoteMatch: .unmatched)
            }
        }
        for review in [LlmReview(summary: "", findings: []), LlmReview(summary: special, findings: findings)] {
            let message = try AssistantResponse(output: .review(review)).transcriptMessage()
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(try LlmOutputDecoder.review(from: message.content, source: "Unmatched source"), review)
        }
    }

    func testBothClientsMergeAllAdjacentRolesOnlyOnTheWire() async throws {
        let transcript = [AssistantMessage(role: .user, content: "First brief"),
            AssistantMessage(role: .user, content: "Failed retry"),
            AssistantMessage(role: .assistant, content: "First response"),
            AssistantMessage(role: .assistant, content: "More response"),
            AssistantMessage(role: .user, content: "Another failed retry")]
        let request = AssistantRequest(action: .write(brief: "Current brief"), transcript: transcript,
            feedback: "Fix </feedback> & retry")
        let expected = [AssistantMessage(role: .user, content: "First brief\n\nFailed retry"),
            AssistantMessage(role: .assistant, content: "First response\n\nMore response"),
            AssistantMessage(role: .user, content: "Another failed retry\n\n" + request.userMessage.content)]
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ConnectionTransport([.response(try response(kind))])
            _ = try await client(kind, transport: transport).perform(request, using: connection(kind))
            let requests = await transport.snapshot()
            let sent = try XCTUnwrap(requests.first)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent.body)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let turns = kind == .anthropic ? messages : Array(messages.dropFirst())
            XCTAssertEqual(turns, expected.map(\.wireValue), "for \(kind)")
            XCTAssertEqual(request.transcript, transcript, "for \(kind)")
            XCTAssertEqual(request.messages, transcript + [request.userMessage], "for \(kind)")
        }
    }

    func testBothClientsCheckExpiredDeadlineBeforeModelAndKeyValidation() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ConnectionTransport([])
            let invalid = ProviderConnection(profileID: ProviderProfileID(), kind: kind,
                baseURL: try ProviderSettings.normalizeBaseURL(kind.defaultBaseURL, kind: kind),
                modelID: "", key: SecretValue("invalid\nkey"))
            do {
                _ = try await client(kind, transport: transport).perform(AssistantRequest(action: .write(brief: "Brief")),
                    using: invalid, deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
                XCTFail("Expired action succeeded for \(kind)")
            } catch {
                XCTAssertEqual(error as? AssistantError, .transport(.deadlineExceeded), "for \(kind)")
            }
            let sent = await transport.snapshot()
            XCTAssertTrue(sent.isEmpty, "for \(kind)")
        }
    }

    func testBothClientsSendRetainedConversationAndEscapedFeedbackWithOriginalDeadline() async throws {
        let output = try LlmOutputDecoder.artifact(from: AssistantOutputFixtures.json(AssistantOutputFixtures.artifact))
        let first = AssistantRequest(action: .write(brief: "A <brief>"))
        let transcript = first.messages + [try AssistantResponse(output: .artifact(output)).transcriptMessage()]
        let request = AssistantRequest(action: first.action, effort: .high, transcript: transcript,
                                       feedback: "Fix </feedback> & the fields")
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ConnectionTransport([.response(try response(kind))])
            let client = client(kind, transport: transport)
            _ = try await client.perform(request, using: connection(kind), deadline: deadline)
            let sent = await transport.snapshot()
            XCTAssertEqual(sent.count, 1, "for \(kind)")
            let sentRequest = try XCTUnwrap(sent.first, "for \(kind)")
            XCTAssertEqual(sentRequest.deadline, deadline, "for \(kind)")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sentRequest.body)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let turns = kind == .anthropic ? messages : Array(messages.dropFirst())
            XCTAssertEqual(turns, request.messages.map(\.wireValue), "for \(kind)")
            XCTAssertEqual(turns.map { $0["role"] }, ["user", "assistant", "user"], "for \(kind)")
            XCTAssertTrue(try XCTUnwrap(turns.last?["content"]).contains("&lt;/feedback&gt; &amp;"), "for \(kind)")
            XCTAssertEqual(try LlmOutputDecoder.artifact(from: XCTUnwrap(turns.dropFirst().first?["content"])), output, "for \(kind)")
        }
    }

    func testBothClientsRefuseExpiredSharedDeadlineBeforeSending() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ConnectionTransport([])
            do {
                _ = try await client(kind, transport: transport).perform(AssistantRequest(action: .write(brief: "Brief")),
                    using: connection(kind), deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
                XCTFail("Expired action succeeded for \(kind)")
            } catch { XCTAssertEqual(error as? AssistantError, .transport(.deadlineExceeded), "for \(kind)") }
            let sent = await transport.snapshot()
            XCTAssertTrue(sent.isEmpty, "for \(kind)")
        }
    }

    func testReviewTranscriptRetainsOutputShapeWithoutQuoteRangesAndRedactsDiagnostics() throws {
        let review = try LlmOutputDecoder.review(from: AssistantOutputFixtures.json(AssistantOutputFixtures.review),
                                               source: "Use sources.")
        let message = try AssistantResponse(output: .review(review)).transcriptMessage()
        XCTAssertEqual(try LlmOutputDecoder.review(from: message.content, source: "Use sources."), review)
        XCTAssertFalse(message.content.contains("byteRange"))
        XCTAssertFalse(String(describing: message).contains("Use sources."))
        var diagnostic = ""
        dump(message, to: &diagnostic)
        XCTAssertFalse(diagnostic.contains("Use sources."))
    }

    private func client(_ kind: ProviderKind, transport: HTTPTransporting) -> AssistantClient {
        if kind == .anthropic { return AnthropicClient(transport: transport) }
        return OpenAIClient(transport: transport, providerState: ProviderStateStore(files: MemoryFileStore()))
    }

    private func connection(_ kind: ProviderKind) throws -> ProviderConnection {
        ProviderConnection(profileID: ProviderProfileID(), kind: kind,
            baseURL: try ProviderSettings.normalizeBaseURL(kind.defaultBaseURL, kind: kind),
            modelID: "manual-model", key: SecretValue("test-key"))
    }

    private func response(_ kind: ProviderKind) throws -> HTTPResponse {
        let text = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        let object: [String: Any] = kind == .anthropic
            ? ["stop_reason": "end_turn", "content": [["type": "text", "text": text]]]
            : ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}
