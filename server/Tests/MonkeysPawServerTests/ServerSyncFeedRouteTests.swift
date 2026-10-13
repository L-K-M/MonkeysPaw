import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedRouteTests {
    @Test func currentCursorReturnsAnEmptyDelta() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let write = try await fixture.writePrompt(session: session.identity)
            let databaseID = try await MetaRepository(database: fixture.persistence.database).databaseID().uuidString.lowercased()
            let request = SyncAPI.PullRequest(databaseID: databaseID, cursors: ["user:\(user.id)": String(write.seq)])
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    #expect($0.status == .ok)
                    guard $0.status == .ok else { return }
                    let response = try PromptHTTPTest.success($0, as: SyncAPI.PullResponse.self)
                    #expect(response.databaseID == databaseID && response.removed.isEmpty)
                    #expect(response.scopes == [.init(identity: .user(userID: user.id), mode: .delta, head: write.seq,
                                                     cursor: String(write.seq), hasMore: false, items: [])])
                }
            }
        }
    }

    @Test func malformedBodiesAndNoncanonicalSequenceCursorsReturn400() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let databaseID = try #require(request.databaseID)
            var invalid: [[String: Any]] = [
                [:], ["cursors": [:]], ["database_id": databaseID],
                ["database_id": NSNull(), "cursors": [:], "extra": true],
                ["database_id": databaseID.uppercased(), "cursors": [identity.key: "1"]],
                ["database_id": 1, "cursors": [:]], ["database_id": databaseID, "cursors": NSNull()],
                ["database_id": databaseID, "cursors": [identity.key: 1]],
                ["database_id": databaseID, "cursors": ["group:bad-id": "1"]],
                ["database_id": databaseID, "cursors": ["private:\(user.id)": "1"]]
            ]
            for cursor in ["", "01", "+1", "-1", " 1", "1 ", "1.0", "1e0", "9223372036854775808", "snap:", "snap", "SNAP:opaque"] {
                invalid.append(["database_id": databaseID, "cursors": [identity.key: cursor]])
            }
            let bodies = try invalid.map { try JSONSerialization.data(withJSONObject: $0) } + [Data("{".utf8)]
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for body in bodies {
                    try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                        try PromptHTTPTest.error($0, .failure(.malformedRequest))
                    }
                }
            }
        }
    }

    @Test func exactAndOverflowRequestEnvelopeLimitsAreEnforced() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let baseline = try #require(await fixture.seedFeed(identity: identity, count: 1).last)
            let request = try await fixture.feedRequest(cursors: [identity.key: baseline])
            let json = try JSONEncoder().encode(request)
            let padding = SyncAPI.requestEnvelopeMaxBytes - json.count
            try #require(padding >= 0, "Fixture request must fit inside the request envelope limit")
            let exact = json + Data(repeating: 32, count: padding)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session), body: .init(bytes: exact)) {
                    let response = try PromptHTTPTest.success($0, as: SyncAPI.PullResponse.self)
                    #expect(response.scopes[0].items.isEmpty)
                }
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: exact + Data([32]))) { try PromptHTTPTest.error($0, .failure(.envelopeTooLarge)) }
            }
        }
    }

    @Test func missingInvalidAndRevokedAuthReturn401() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions)
            let body = try JSONEncoder().encode(SyncAPI.PullRequest(databaseID: nil, cursors: [:]))
            let denied: [HTTPFields] = [[:], [.authorization: "Bearer invalid"], [.authorization: "Basic \(session.token.value)"]]
            try await app.test(.router) { client in
                for headers in denied {
                    try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: headers, body: .init(bytes: body)) {
                        try PromptHTTPTest.error($0, .failure(.unauthorized))
                        #expect($0.headers[.wwwAuthenticate] == "Bearer")
                    }
                }
                try await fixture.account.sessions.logout(session.identity)
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                    try PromptHTTPTest.error($0, .failure(.unauthorized))
                }
            }
        }
    }

    @Test func expiredSnapshotUsesTheS1ContractAndRedactsLogs() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            _ = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let request = first.continuation
            try await fixture.persistence.execute("DELETE FROM snapshots")
            let capture = CapturedServerLogs()
            let logger = ServerLogging.makeLogger(level: .trace, sink: capture.write)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                      sessions: fixture.account.sessions, logger: logger)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/sync/pull", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    try PromptHTTPTest.error($0, .snapshotExpired(scopes: ["user:\(user.id)"]))
                }
            }
            let failures = try capture.events().filter { $0.message == "API request failed" }
            #expect(failures.count == 1 && failures.first?.level == "debug")
            #expect(failures.first?.fields["error_type"] == nil)
            let logged = String(decoding: capture.snapshot(), as: UTF8.self)
            for secret in [user.id, session.token.value, first.scopes[0].cursor, "snapshotExpired"] { #expect(!logged.contains(secret)) }
            #expect(String(describing: SyncFeedError.snapshotTooLarge) == "SyncFeedError(<redacted>)")
        }
    }
}
