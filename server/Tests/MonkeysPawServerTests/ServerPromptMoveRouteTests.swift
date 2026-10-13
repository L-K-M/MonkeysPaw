import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptMoveRouteTests {
    @Test func moveThenDeleteUsesDestinationSequenceAndNeverRevives() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let id = GroupTestFixture.livePrompt
            let original = promptContent(metadata: "title: Example\nfavorite: true\nprivate: true\n")
            _ = try await fixture.writePrompt(content: original, session: session.identity)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let move = SyncAPI.MovePromptRequest(baseRev: 1, scope: scope, path: "Shared.md")
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(move))) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 2 && write.seq == 3)
                    #expect(write.warnings?.contains { $0.code == "metadata.group_private_removed" } == true)
                }
                let shared = try await fixture.prompts.get(id: id, session: session.identity)
                #expect(shared.scope == scope && shared.path == "Shared.md")
                #expect(!shared.content.contains("favorite:") && !shared.content.contains("private:"))
                try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=2", method: .delete, headers: PromptHTTPTest.headers(session)) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 3 && write.seq == 4 && write.warnings == nil)
                }
                let before = try await fixture.persistence.promptStorageState()
                let put = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Revived.md", content: original)
                for purged in [false, true] {
                    if purged { try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: id)") }
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(put))) { try PromptHTTPTest.error($0, .deleted) }
                    try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(move))) { try PromptHTTPTest.error($0, .deleted) }
                    try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=1", method: .delete, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .deleted)
                    }
                    if !purged { #expect(try await fixture.persistence.promptStorageState() == before) }
                }
                #expect(try await fixture.persistence.count("retired_prompt_ids") == 1)
                #expect(try await fixture.persistence.count("changes") == 4)
            }
        }
    }
}
