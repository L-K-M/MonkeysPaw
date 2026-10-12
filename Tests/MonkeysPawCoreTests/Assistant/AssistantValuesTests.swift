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
        let url = try XCTUnwrap(URL(string: "https://example.com/v1/messages"))
        let request = try HTTPRequest(url: url, method: .post,
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

    func testRequestRejectsInvalidCapsAndOversizedBody() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        for cap in [-1, 0] {
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .get, responseByteCap: cap, deadline: .now), "Response cap \(cap)") {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest, "Response cap \(cap)")
            }
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .get, requestByteCap: cap, deadline: .now), "Request cap \(cap)") {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest, "Request cap \(cap)")
            }
        }
        XCTAssertThrowsError(try HTTPRequest(url: url, method: .post, body: Data([1, 2]),
            requestByteCap: 1, deadline: .now)) { XCTAssertEqual($0 as? HTTPTransportError, .requestTooLarge) }
    }

    func testRequestRejectsInvalidHeaderNamesAndControlValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let invalid: [[String: String]] = [
            ["": "value"], ["X-\rName": "value"], ["X-\nName": "value"], ["X-\0Name": "value"],
            ["X Name": "value"], ["X:Name": "value"], ["X-ñ": "value"],
            ["Authorization": "one", "authorization": "two"]
        ]
        for (index, headers) in invalid.enumerated() {
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .post, headers: headers, deadline: .now),
                                 "Header-name case \(index)") {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest, "Header-name case \(index)")
            }
        }
        let controls = ["\r", "\n", "\0", "\t", "\u{1f}", "\u{7f}", "\u{85}", "\r\nX-Injected: b"]
        for (index, control) in controls.enumerated() {
            XCTAssertThrowsError(try HTTPRequest(url: url, method: .post,
                headers: ["Authorization": "Bearer a" + control + "b"], deadline: .now), "Header-value case \(index)") {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest, "Header-value case \(index)")
            }
        }
    }

    func testRequestPreservesValidHeadersIncludingEmptyValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let headers = ["Authorization": "Bearer key", "x-api-key": "key", "X-Empty": "",
                       "X-Text": "café", "!#$%&'*+-.^_`|~0123456789AZaz": "value"]
        let request = try HTTPRequest(url: url, method: .post, headers: headers, deadline: .now)
        XCTAssertEqual(request.headers, headers)
    }

    func testSecretDraftConnectionTransportAndErrorDescriptionsAreRedacted() throws {
        let sentinel = UUID().uuidString
        let secret = SecretValue(sentinel)
        let stored = StoredSecret(value: secret, tier: .keychain)
        let draft = ProviderDraft(key: .replace(secret))
        let baseURL = try XCTUnwrap(URL(string: draft.baseURL))
        let connection = ProviderConnection(profileID: draft.id, kind: draft.kind,
            baseURL: baseURL, modelID: draft.modelID, key: secret)
        let url = try XCTUnwrap(URL(string: "https://example.com/?key=\(sentinel)"))
        let request = try HTTPRequest(url: url, method: .post,
            headers: ["Authorization": sentinel], body: Data(sentinel.utf8), deadline: .now)
        let response = HTTPResponse(statusCode: 500, headers: ["error": sentinel], body: Data(sentinel.utf8))
        let error = AssistantError.unexpectedStop(sentinel)
        for value: Any in [secret, stored, draft, draft.key, connection, request, response, error] {
            XCTAssertFalse(String(describing: value).contains(sentinel), "description leaked from \(type(of: value))")
            XCTAssertFalse(String(reflecting: value).contains(sentinel), "debug description leaked from \(type(of: value))")
        }
        for value: Any in [secret, stored, draft, draft.key, connection, request, response, error] {
            var output = ""
            dump(value, to: &output)
            XCTAssertFalse(output.contains(sentinel), "dump leaked from \(type(of: value))")
        }
        XCTAssertEqual(error, .unexpectedStop(sentinel))
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
