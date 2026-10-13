import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantTranscriptTests: XCTestCase {
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
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0].deadline, deadline)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent[0].body)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let turns = kind == .anthropic ? messages : Array(messages.dropFirst())
            XCTAssertEqual(turns, request.messages.map(\.wireValue))
            XCTAssertEqual(turns.map { $0["role"] }, ["user", "assistant", "user"])
            XCTAssertTrue(try XCTUnwrap(turns.last?["content"]).contains("&lt;/feedback&gt; &amp;"))
            XCTAssertEqual(try LlmOutputDecoder.artifact(from: XCTUnwrap(turns[1]["content"])), output)
        }
    }

    func testBothClientsRefuseExpiredSharedDeadlineBeforeSending() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ConnectionTransport([])
            do {
                _ = try await client(kind, transport: transport).perform(AssistantRequest(action: .write(brief: "Brief")),
                    using: connection(kind), deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
                XCTFail("Expired action succeeded")
            } catch { XCTAssertEqual(error as? AssistantError, .transport(.deadlineExceeded)) }
            let sent = await transport.snapshot()
            XCTAssertTrue(sent.isEmpty)
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
