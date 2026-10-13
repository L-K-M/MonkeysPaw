import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptHistoryTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin], [SyncAPI.Role.owner, .editor, .viewer])
    func creatorKeepsVisibleHistoryAndOtherReadersSeeOnlyTheDestinationEra(kind: SyncAPI.AccountKind, role: SyncAPI.Role) async throws {
        try await withGroupFixture { fixture in
            let creator = try await fixture.user("creator")
            let groupOwner = try await fixture.user("groupowner")
            let reader = try await fixture.user("reader", kind: kind)
            let first = try await fixture.group(owner: groupOwner)
            let second = try await fixture.group(owner: groupOwner, id: PersistenceTestRepository.otherGroup)
            for group in [first, second] {
                try await fixture.member(groupID: group.id, user: creator, role: .editor)
                try await fixture.member(groupID: group.id, user: reader, role: role)
            }
            let creatorSession = try await fixture.account.session(creator)
            let ownerSession = try await fixture.account.session(groupOwner)
            let session = try await fixture.account.session(reader)
            let id = GroupTestFixture.livePrompt
            let privateContent = promptContent(metadata: "title: Private\nfavorite: true\nprivate: true\n", body: "private-history-sentinel\n")
            _ = try await fixture.writePrompt(content: privateContent, session: creatorSession.identity)
            _ = try await fixture.writePrompt(baseRev: 1, path: "Private.md", content: privateContent, session: creatorSession.identity)
            let shared = promptContent(body: "shared era\n")
            try await fixture.movePrompt(identity: .group(groupID: first.id), actorID: creator.id, path: "Shared.md", content: shared)
            _ = try await fixture.writePrompt(baseRev: 3, scope: .group(groupID: first.id), path: "Renamed.md", content: shared, session: ownerSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: creatorSession.identity).revisions.map(\.rev) == [4, 3, 2, 1])
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [4, 3])
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for rev in [1, 2] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/\(rev)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/1", method: .get, headers: PromptHTTPTest.headers(creatorSession)) {
                    let revision = try PromptHTTPTest.success($0, as: SyncAPI.Revision.self)
                    #expect(revision.content == privateContent && revision.scope == .user && revision.authorID == creator.id)
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/3", method: .get, headers: PromptHTTPTest.headers(session)) {
                    let revision = try PromptHTTPTest.success($0, as: SyncAPI.Revision.self)
                    #expect(revision.content == shared && revision.origin == .move && revision.path == "Shared.md")
                    #expect(revision.scope == .group(groupID: first.id) && revision.authorID == creator.id)
                }
                try await fixture.movePrompt(identity: .group(groupID: second.id), actorID: creator.id, path: "Second.md", content: shared)
                #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [5])
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: 4, session: session.identity) }
                try await fixture.movePrompt(identity: .group(groupID: first.id), actorID: creator.id, path: "Returned.md", content: shared)
                #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [6])
                #expect(try await fixture.prompts.revisions(id: id, session: creatorSession.identity).revisions.map(\.rev) == [6, 5, 4, 3, 2, 1])
                for rev: Int64 in [3, 4, 5] {
                    await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: rev, session: session.identity) }
                }
                // Creator status cannot bypass current visibility after removal.
                try await fixture.service.removeMember(id: first.id, userID: creator.id, session: ownerSession.identity)
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revisions(id: id, session: creatorSession.identity) }
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: 1, session: creatorSession.identity) }
                try await fixture.tombstonePrompt(actorID: groupOwner.id)
                #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [7, 6])
                let deleted = try await fixture.prompts.revision(id: id, rev: 7, session: session.identity)
                #expect(deleted.origin == .delete && deleted.authorID == groupOwner.id && deleted.path == "Returned.md")
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin])
    func privateOwnershipIsPartOfTheRevisionEra(kind: SyncAPI.AccountKind) async throws {
        try await withGroupFixture { fixture in
            let creator = try await fixture.user("creator")
            let recipient = try await fixture.user("recipient", kind: kind)
            let group = try await fixture.group(owner: recipient)
            try await fixture.member(groupID: group.id, user: creator, role: .editor)
            let creatorSession = try await fixture.account.session(creator)
            let session = try await fixture.account.session(recipient)
            _ = try await fixture.writePrompt(content: promptContent(body: "creator private sentinel\n"), session: creatorSession.identity)
            try await fixture.movePrompt(identity: .group(groupID: group.id), actorID: creator.id, content: promptContent(body: "shared\n"))
            try await fixture.movePrompt(identity: .user(ownerID: recipient.id), actorID: recipient.id, content: promptContent(body: "recipient private\n"))
            let id = GroupTestFixture.livePrompt
            let list = try await fixture.prompts.revisions(id: id, session: session.identity).revisions
            #expect(list.map(\.rev) == [3] && list.first?.scope == .user)
            await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: 1, session: session.identity) }
            await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: 2, session: session.identity) }
            await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.get(id: id, session: creatorSession.identity) }
            await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revisions(id: id, session: creatorSession.identity) }
            try await fixture.tombstonePrompt(actorID: recipient.id)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [4, 3])
            let before = try await fixture.persistence.promptStorageState()
            await #expect(throws: PromptError(.deleted)) { _ = try await fixture.writePrompt(baseRev: 4, session: session.identity) }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }

    @Test func revisionListsAreBoundedWithoutPruningRetainedHistory() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            _ = try await fixture.writePrompt(session: session.identity)
            let id = GroupTestFixture.livePrompt
            // S15 owns pruning; this fixture proves the S1 list bound before maintenance.
            try await fixture.persistence.database.write { sql in
                for rev in 2...205 {
                    try await sql.raw("""
                        INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, path, content, created_at, origin)
                        VALUES (\(bind: id), \(bind: rev), \(bind: owner.id), 'user', \(bind: owner.id), 'Example.md',
                                \(bind: promptContent()), \(bind: owner.createdAt), 'edit')
                        """).run()
                }
                try await sql.raw("UPDATE prompts SET rev = 205 WHERE id = \(bind: id)").run()
            }
            let list = try await fixture.prompts.revisions(id: id, session: session.identity).revisions
            #expect(list.count == 200 && list.first?.rev == 205 && list.last?.rev == 6)
            #expect(try await fixture.prompts.revision(id: id, rev: 1, session: session.identity).content == promptContent())
            #expect(try await fixture.persistence.count("prompt_revisions") == 205)
        }
    }
}
