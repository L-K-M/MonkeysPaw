import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerProviderSettingsRouteTests {
    private static let uri = "/api/v1/me/provider-settings"
    private static let document = "AYx2kA-j0Zr8QvN3lKp1mT7wB4cX9yF2hU6eR5tS8vW0xZ1C4bN7mQ9"

    @Test func getReturnsEmptyDocumentBeforeAnyWrite() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: Self.uri, method: .get, headers: [.authorization: "Bearer \(session.token.value)"]) { response in
                    #expect(response.status == .ok)
                    let document = try JSONDecoder().decode(SyncAPI.ProviderSettingsDocument.self, from: Data(response.body.readableBytesView))
                    #expect(document == .init(rev: 0, document: nil, updatedAt: nil))
                }
            }
        }
    }

    @Test func putStoresDocumentAndIncrementsRevisionLastWriterWins() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
            try await app.test(.router) { client in
                for (index, document) in [Self.document, "AAAA", "BBBB"].enumerated() {
                    let body = try JSONEncoder().encode(SyncAPI.PutProviderSettingsRequest(document: document))
                    try await client.execute(uri: Self.uri, method: .put, headers: headers, body: .init(bytes: body)) { response in
                        #expect(response.status == .ok)
                        let written = try JSONDecoder().decode(SyncAPI.ProviderSettingsResponse.self, from: Data(response.body.readableBytesView))
                        #expect(written == .init(rev: Int64(index + 1)))
                    }
                    try await client.execute(uri: Self.uri, method: .get, headers: headers) { response in
                        #expect(response.status == .ok)
                        let stored = try JSONDecoder().decode(SyncAPI.ProviderSettingsDocument.self, from: Data(response.body.readableBytesView))
                        #expect(stored.rev == Int64(index + 1))
                        #expect(stored.document == document)
                        #expect(stored.updatedAt != nil)
                    }
                }
            }
        }
    }

    @Test func documentsAreIsolatedBetweenAccounts() async throws {
        try await withAccountFixture { fixture in
            let first = try await fixture.session(try await fixture.user())
            let second = try await fixture.session(try await fixture.user(username: "bob"))
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutProviderSettingsRequest(document: Self.document))
                try await client.execute(uri: Self.uri, method: .put,
                                         headers: [.authorization: "Bearer \(first.token.value)", .contentType: "application/json"],
                                         body: .init(bytes: body)) { #expect($0.status == .ok) }
                try await client.execute(uri: Self.uri, method: .get, headers: [.authorization: "Bearer \(second.token.value)"]) { response in
                    #expect(response.status == .ok)
                    let stored = try JSONDecoder().decode(SyncAPI.ProviderSettingsDocument.self, from: Data(response.body.readableBytesView))
                    #expect(stored == .init(rev: 0, document: nil, updatedAt: nil))
                }
            }
        }
    }

    @Test func requestsRequireAuthenticationAndActiveAccounts() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
            let body = try JSONEncoder().encode(SyncAPI.PutProviderSettingsRequest(document: Self.document))
            try await app.test(.router) { client in
                for method in [HTTPRequest.Method.get, .put] {
                    try await client.execute(uri: Self.uri, method: method) { try Self.failure($0, .unauthorized) }
                    try await client.execute(uri: Self.uri, method: method, headers: [.authorization: "Bearer invalid"]) { try Self.failure($0, .unauthorized) }
                }
                try await client.execute(uri: Self.uri, method: .put, headers: headers, body: .init(bytes: body)) { #expect($0.status == .ok) }
                try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at")
                try await client.execute(uri: Self.uri, method: .get, headers: headers) { try Self.failure($0, .unauthorized) }
                try await client.execute(uri: Self.uri, method: .put, headers: headers, body: .init(bytes: body)) { try Self.failure($0, .unauthorized) }
            }
        }
    }

    @Test func malformedAndOutOfContractBodiesAreRejected() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            let headers: HTTPFields = [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
            try await app.test(.router) { client in
                for invalid in ["{", "{}", "[]", "{\"document\":\"a=b\"}", "{\"document\":\"\"}",
                                "{\"document\":5}", "{\"document\":\"\(Self.document)\",\"extra\":1}",
                                "{\"document\":\"\(String(repeating: "a", count: 349_601))\"}"] {
                    try await client.execute(uri: Self.uri, method: .put, headers: headers, body: .init(string: invalid)) { try Self.failure($0, .malformedRequest) }
                }
                let boundary = String(repeating: "a", count: 349_600)
                try await client.execute(uri: Self.uri, method: .put, headers: headers,
                                         body: .init(string: "{\"document\":\"\(boundary)\"}")) { #expect($0.status == .ok) }
            }
        }
    }

    @Test func storedRowsHoldOnlyOpaqueCiphertext() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let session = try await fixture.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.accounts, sessions: fixture.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutProviderSettingsRequest(document: Self.document))
                try await client.execute(uri: Self.uri, method: .put,
                                         headers: [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"],
                                         body: .init(bytes: body)) { #expect($0.status == .ok) }
            }
            let count = try await fixture.persistence.string("SELECT COUNT(*) AS count FROM provider_settings", column: "count")
            #expect(count == "1")
            // The route contract accepts opaque ciphertext only; DB CHECKs reject plaintext-ish rows.
            await #expect(throws: (any Error).self) {
                try await fixture.persistence.execute("INSERT INTO provider_settings (user_id, rev, document, updated_at) VALUES ('x', 1, 'sk-ant-plaintext', 'x')")
            }
            try await fixture.assertNoPlaintext([session.token.value])
        }
    }

    private static func failure(_ response: TestResponse, _ code: SyncAPI.FailureCode) throws {
        #expect(response.status.code == code.httpStatus)
        let envelope = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
        #expect(envelope == .failure(code))
    }
}
