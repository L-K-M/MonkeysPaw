import Foundation
import XCTest
@testable import MonkeysPawCore

final class ModelListTests: XCTestCase {
    func testBothProtocolsEscapePageCursorAndRetainSharedDeadline() async throws {
        let cursor = "model+space &?/é"
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ModelListTransport(Data("{\"data\":[]}".utf8)) { request in
                XCTAssertEqual(request.deadline, deadline)
                XCTAssertEqual(request.method, .get)
                XCTAssertNil(request.body)
                let url = try! XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(url.queryItems, [URLQueryItem(name: "after_id", value: cursor)])
                XCTAssertTrue(url.percentEncodedQuery?.contains("%2B") == true)
                XCTAssertTrue(url.percentEncodedQuery?.contains("%26") == true)
            }
            let client = client(kind, transport: transport)
            _ = try await client.listModels(using: connection(kind), afterID: cursor, deadline: deadline)
        }
    }

    func testBothProtocolsRejectInvalidCursorsAndExpiredDeadlineBeforeSending() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let transport = ModelListTransport(Data("{\"data\":[]}".utf8)) { _ in XCTFail("Must not send") }
            let client = client(kind, transport: transport)
            for cursor in ["", " \t", "id\n"] {
                do {
                    _ = try await client.listModels(using: connection(kind), afterID: cursor,
                                                   deadline: .now.advanced(by: .seconds(15)))
                    XCTFail("Expected invalid cursor")
                } catch { XCTAssertEqual(error as? AssistantError, .invalidOutput) }
            }
            do {
                _ = try await client.listModels(using: connection(kind), afterID: nil,
                                               deadline: .now.advanced(by: .seconds(-1)))
                XCTFail("Expected timeout")
            } catch { XCTAssertEqual(error as? AssistantError, .transport(.deadlineExceeded)) }
        }
    }

    func testBothProtocolsRejectMalformedPaginationIDs() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for field in ["first_id", "last_id"] {
                for cursor in ["", " \t", "id\u{0}"] {
                    let body = try JSONSerialization.data(withJSONObject: ["data": [["id": "model"]], field: cursor])
                    do {
                        _ = try await client(kind, transport: ModelListTransport(body)).listModels(using: connection(kind))
                        XCTFail("Expected invalid pagination ID")
                    } catch { XCTAssertEqual(error as? AssistantError, .invalidOutput) }
                }
            }
        }
    }

    func testBothProtocolsRejectControlCharactersInModelIDs() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for id in ["model\nextra", "model\u{0}extra", "model\textra"] {
                let transport = ModelListTransport(try JSONSerialization.data(withJSONObject: ["data": [["id": id]]]))
                let connection = ProviderConnection(profileID: ProviderProfileID(), kind: kind,
                    baseURL: try ProviderSettings.normalizeBaseURL(kind.defaultBaseURL, kind: kind),
                    modelID: "", key: SecretValue("test-key"))
                let client: AssistantClient = kind == .anthropic ? AnthropicClient(transport: transport)
                    : OpenAIClient(transport: transport, providerState: ProviderStateStore(files: MemoryFileStore()))
                do {
                    _ = try await client.listModels(using: connection)
                    XCTFail("Control characters must not become selectable model IDs")
                } catch { XCTAssertEqual(error as? AssistantError, .invalidOutput) }
            }
        }
    }

    private func client(_ kind: ProviderKind, transport: ModelListTransport) -> AssistantClient {
        kind == .anthropic ? AnthropicClient(transport: transport)
            : OpenAIClient(transport: transport, providerState: ProviderStateStore(files: MemoryFileStore()))
    }

    private func connection(_ kind: ProviderKind) throws -> ProviderConnection {
        ProviderConnection(profileID: ProviderProfileID(), kind: kind,
            baseURL: try ProviderSettings.normalizeBaseURL(kind.defaultBaseURL, kind: kind),
            modelID: "", key: SecretValue("test-key"))
    }
}

private struct ModelListTransport: HTTPTransporting {
    let body: Data
    let inspect: @Sendable (HTTPRequest) -> Void
    init(_ body: Data, inspect: @escaping @Sendable (HTTPRequest) -> Void = { _ in }) {
        self.body = body
        self.inspect = inspect
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        inspect(request)
        return HTTPResponse(statusCode: 200, body: body)
    }
}
