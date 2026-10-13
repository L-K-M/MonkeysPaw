import Foundation
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
}
