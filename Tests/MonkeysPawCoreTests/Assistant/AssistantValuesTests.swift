import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantValuesTests: XCTestCase {
    func testProviderDraftDefaultNameMatchesItsKindAndKeepsAnExplicitName() {
        XCTAssertEqual(ProviderDraft().displayName, "Anthropic")
        XCTAssertEqual(ProviderDraft(kind: .openaiCompatible).displayName, "OpenAI-compatible")
        XCTAssertEqual(ProviderDraft(displayName: "Local", kind: .openaiCompatible).displayName, "Local")
    }

    func testTypedKeyTrimsSurroundingWhitespaceAndNewlinesOnly() {
        let sentinel = UUID().uuidString
        XCTAssertEqual(ProviderKeyEdit.typed(" \t" + sentinel + "\r\n"), .replace(SecretValue(sentinel)))
        XCTAssertEqual(ProviderKeyEdit.typed(" \t\n"), .keep)
        XCTAssertEqual(ProviderKeyEdit.typed("first\nsecond"), .replace(SecretValue("first\nsecond")))
    }

    func testAccessSeamAllowsEditorOwnerAndPrivatePromptsAndOffersViewerCopy() {
        XCTAssertEqual(AssistantAccessState.privatePrompt.mutationAccess, .currentScope)
        XCTAssertEqual(AssistantAccessState.group(.editor).mutationAccess, .currentScope)
        XCTAssertEqual(AssistantAccessState.group(.owner).mutationAccess, .currentScope)
        XCTAssertEqual(AssistantAccessState.group(.viewer).mutationAccess, .privateCopy)
        XCTAssertEqual(AssistantAccessState.unavailable.mutationAccess, .unavailable)
    }

    func testTransportCarriesMonotonicDeadlineCapsAndNonStreamingData() async throws {
        let deadline = ContinuousClock.now.advanced(by: Limits.llmBudget)
        let request = try HTTPRequest(url: URL(string: "https://example.com/v1/messages")!, method: .post,
            headers: ["x-api-key": "key"], body: Data([1, 2, 3]), requestByteCap: 3,
            responseByteCap: Limits.syncResponseCap, deadline: deadline)
        let response = try await AssistantStubTransport().send(request)
        XCTAssertEqual(request.deadline, deadline)
        XCTAssertEqual(request.body, Data([1, 2, 3]))
        XCTAssertEqual(request.requestByteCap, 3)
        XCTAssertEqual(request.responseByteCap, 16 * 1_024 * 1_024)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data([4, 5]))
        XCTAssertEqual(Limits.responseCap, 2 * 1_024 * 1_024)
        XCTAssertEqual(Limits.httpRequestCap, 2 * 1_024 * 1_024)
        XCTAssertEqual(Limits.modelListTimeout, .seconds(15))
        XCTAssertEqual(Limits.llmBudget, .seconds(300))
    }

    func testRequestRejectsInvalidCapsAndOversizedBody() {
        let url = URL(string: "https://example.com")!
        for cap in [-1, 0] {
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .get, responseByteCap: cap, deadline: .now)) {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest)
            }
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .get, requestByteCap: cap, deadline: .now))
        }
        XCTAssertThrowsError(try HTTPRequest(url: url, method: .post, body: Data([1, 2]),
            requestByteCap: 1, deadline: .now)) { XCTAssertEqual($0 as? HTTPTransportError, .requestTooLarge) }
    }

    func testSecretDraftConnectionTransportAndErrorDescriptionsAreRedacted() throws {
        let sentinel = UUID().uuidString
        let secret = SecretValue(sentinel)
        let stored = StoredSecret(value: secret, tier: .keychain)
        let draft = ProviderDraft(key: .replace(secret))
        let connection = ProviderConnection(profileID: draft.id, kind: draft.kind,
            baseURL: URL(string: draft.baseURL)!, modelID: draft.modelID, key: secret)
        let request = try HTTPRequest(url: URL(string: "https://example.com/?key=\(sentinel)")!, method: .post,
            headers: ["Authorization": sentinel], body: Data(sentinel.utf8), deadline: .now)
        let response = HTTPResponse(statusCode: 500, headers: ["error": sentinel], body: Data(sentinel.utf8))
        let error = AssistantError.unexpectedStop(sentinel)
        for value: Any in [secret, stored, draft, draft.key, connection, request, response, error] {
            XCTAssertFalse(String(describing: value).contains(sentinel))
            XCTAssertFalse(String(reflecting: value).contains(sentinel))
        }
        for value: Any in [secret, stored, draft, connection, request, response] {
            var output = ""
            dump(value, to: &output)
            XCTAssertFalse(output.contains(sentinel))
        }
        XCTAssertEqual(secret.withValue { $0 }, sentinel)
        XCTAssertEqual(ProviderKeyEdit.typed(" \n\t"), .keep)
        XCTAssertEqual(ProviderKeyEdit.typed(sentinel), .replace(secret))
    }
}

private struct AssistantStubTransport: HTTPTransporting {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data([4, 5]))
    }
}
