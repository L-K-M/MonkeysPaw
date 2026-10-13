import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptRetirementTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func tombstoneAndPurgedIDUseActualWriteAuthorityBeforeAnyDestination(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let id = GroupTestFixture.livePrompt
            _ = try await fixture.writePrompt(scope: .group(groupID: group.id), session: ownerSession.identity)
            _ = try await fixture.prompts.delete(id: id, query: .init(baseRev: 1), session: ownerSession.identity)
            let expected: SyncAPI.ErrorResponse = role == .nonMember ? .failure(.notFound) : role == .viewer ? .failure(.forbidden) : .deleted
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for purged in [false, true] {
                    if purged { try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: id)") }
                    let before = try await fixture.persistence.promptStorageState()
                    for rev: Int64 in [1, 2, 99] {
                        let request = SyncAPI.MovePromptRequest(baseRev: rev, scope: .user, path: "Revived.md")
                        try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                                 body: .init(bytes: JSONEncoder().encode(request))) { try PromptHTTPTest.error($0, expected) }
                        try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=\(rev)", method: .delete, headers: PromptHTTPTest.headers(session)) {
                            try PromptHTTPTest.error($0, expected)
                        }
                    }
                    let put = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Revived.md", content: promptContent())
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(put))) { try PromptHTTPTest.error($0, expected) }
                    #expect(try await fixture.persistence.promptStorageState() == before)
                }
                #expect(try await fixture.persistence.count("retired_prompt_ids") == 1)
                #expect(try await fixture.persistence.count("changes") == 2)
                try await fixture.service.delete(id: group.id, session: ownerSession.identity)
                try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=2", method: .delete, headers: PromptHTTPTest.headers(ownerSession)) {
                    try PromptHTTPTest.error($0, .failure(.notFound))
                }
                let move = SyncAPI.MovePromptRequest(baseRev: 2, scope: .user, path: "Revived.md")
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(ownerSession),
                                         body: .init(bytes: JSONEncoder().encode(move))) { try PromptHTTPTest.error($0, .failure(.notFound)) }
            }
        }
    }

    @Test func retirementAfterTransferRecordsTheFinalOwnerAndSurvivesPurge() async throws {
        try await withGroupFixture { fixture in
            let creator = try await fixture.user("creator")
            let recipient = try await fixture.user("recipient", kind: .admin)
            let group = try await fixture.group(owner: recipient)
            try await fixture.member(groupID: group.id, user: creator, role: .editor)
            let creatorSession = try await fixture.account.session(creator)
            let session = try await fixture.account.session(recipient)
            let id = GroupTestFixture.livePrompt
            _ = try await fixture.writePrompt(session: creatorSession.identity)
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: .group(groupID: group.id), path: "Shared.md"),
                                              session: creatorSession.identity)
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 2, scope: .user, path: "Recipient.md"), session: session.identity)
            let movedEvents = try await fixture.persistence.promptEvents()
            fixture.account.clock.advance(60)
            let at = ServerTimestamp.string(fixture.account.clock.now())
            let deleted = try await fixture.prompts.delete(id: id, query: .init(baseRev: 3), session: session.identity)
            #expect(deleted.rev == 4 && deleted.seq == 6)
            let identity = try await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.retiredIdentity(id: id) }
            #expect(identity == .user(ownerID: recipient.id))
            #expect(try await fixture.persistence.string("SELECT retired_at FROM retired_prompt_ids WHERE prompt_id = \(bind: id)", column: "retired_at") == at)
            let events = try await fixture.persistence.promptEvents()
            #expect(Array(events.prefix(5)) == movedEvents)
            let deletion = try #require(events.last)
            #expect(deletion.kind == "delete" && deletion.identity == identity && deletion.path == "Recipient.md")
            #expect(deletion.rev == 4 && deletion.content == nil && deletion.at == at)
            try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: id)")
            #expect(try await fixture.persistence.count("prompt_revisions") == 0)
            #expect(try await fixture.persistence.count("retired_prompt_ids") == 1)
            #expect(try await fixture.persistence.promptEvents() == events)
            for actor in [creatorSession, session] {
                let put = SyncAPI.PutPromptRequest(baseRev: 0, scope: .group(groupID: group.id), path: "Revived.md", content: promptContent())
                let move = SyncAPI.MovePromptRequest(baseRev: 4, scope: .group(groupID: group.id), path: "Revived.md")
                let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
                try await app.test(.router) { client in
                    let expected: SyncAPI.ErrorResponse = actor.user.id == recipient.id ? .deleted : .failure(.notFound)
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(actor),
                                             body: .init(bytes: JSONEncoder().encode(put))) { try PromptHTTPTest.error($0, expected) }
                    try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(actor),
                                             body: .init(bytes: JSONEncoder().encode(move))) { try PromptHTTPTest.error($0, expected) }
                    try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=4", method: .delete, headers: PromptHTTPTest.headers(actor)) {
                        try PromptHTTPTest.error($0, expected)
                    }
                }
            }
            await fixture.persistence.reject("""
                INSERT INTO prompts (id, scope, owner_id, path, path_key, content, title, rev, created_by, created_at, updated_by, updated_at)
                VALUES (\(bind: id), 'user', \(bind: recipient.id), 'Revived.md', 'revived.md', 'revived', 'Fixture',
                        1, \(bind: creator.id), \(bind: at), \(bind: recipient.id), \(bind: at))
                """)
        }
    }
}
