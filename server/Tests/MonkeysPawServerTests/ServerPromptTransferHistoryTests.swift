import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptTransferHistoryTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin], [SyncAPI.Role.owner, .editor, .viewer])
    func actualMovesEstablishDestinationErasIncludingReturningToAGroup(kind: SyncAPI.AccountKind, role: SyncAPI.Role) async throws {
        try await withGroupFixture { fixture in
            let creator = try await fixture.user("creator")
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader", kind: kind)
            let first = try await fixture.group(owner: owner)
            let second = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            for group in [first, second] {
                try await fixture.member(groupID: group.id, user: creator, role: .editor)
                try await fixture.member(groupID: group.id, user: reader, role: role)
            }
            let creatorSession = try await fixture.account.session(creator)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let id = GroupTestFixture.livePrompt
            let privateContent = promptContent(metadata: "title: Private\nfavorite: true\nprivate: true\n", body: "Earlier private text\n")
            _ = try await fixture.writePrompt(content: privateContent, session: creatorSession.identity)
            _ = try await fixture.writePrompt(baseRev: 1, content: privateContent, session: creatorSession.identity)
            let firstScope = SyncAPI.PromptScope.group(groupID: first.id)
            let secondScope = SyncAPI.PromptScope.group(groupID: second.id)
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 2, scope: firstScope, path: "Shared.md"), session: creatorSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [3])
            #expect(try await fixture.prompts.revisions(id: id, session: creatorSession.identity).revisions.map(\.rev) == [3, 2, 1])
            _ = try await fixture.writePrompt(baseRev: 3, scope: firstScope, path: "Shared.md", content: promptContent(body: "Shared edit\n"), session: ownerSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [4, 3])
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 4, scope: secondScope, path: "Second.md"), session: creatorSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [5])
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 5, scope: firstScope, path: "Returned.md"), session: ownerSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [6])
            #expect(try await fixture.prompts.revisions(id: id, session: creatorSession.identity).revisions.map(\.rev) == [6, 5, 4, 3, 2, 1])
            let boundary = try await fixture.prompts.revision(id: id, rev: 6, session: session.identity)
            #expect(boundary.origin == .move && boundary.scope == firstScope && boundary.path == "Returned.md" && boundary.authorID == owner.id)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for rev in 1...5 {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/\(rev)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                let old = try await fixture.prompts.revision(id: id, rev: 1, session: creatorSession.identity)
                #expect(old.scope == .user && old.content == privateContent)
                try await fixture.service.removeMember(id: first.id, userID: creator.id, session: ownerSession.identity)
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revisions(id: id, session: creatorSession.identity) }
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: 1, session: creatorSession.identity) }
                _ = try await fixture.prompts.delete(id: id, query: .init(baseRev: 6), session: ownerSession.identity)
                #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [7, 6])
                let deleted = try await fixture.prompts.revision(id: id, rev: 7, session: session.identity)
                #expect(deleted.origin == .delete && deleted.scope == firstScope && deleted.content == boundary.content)
            }
        }
    }

    @Test func privateOwnerChangesPreserveCreatorAndRecanonicalizeEveryGroupEntry() async throws {
        try await withGroupFixture { fixture in
            let creator = try await fixture.user("creator")
            let recipient = try await fixture.user("recipient")
            let group = try await fixture.group(owner: recipient)
            try await fixture.member(groupID: group.id, user: creator, role: .editor)
            let creatorSession = try await fixture.account.session(creator)
            let session = try await fixture.account.session(recipient)
            let id = GroupTestFixture.livePrompt
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            _ = try await fixture.writePrompt(content: promptContent(body: "Creator private\n"), session: creatorSession.identity)
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: scope, path: "Shared.md"), session: creatorSession.identity)
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 2, scope: .user, path: "Recipient.md"), session: session.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [3])
            for rev: Int64 in [1, 2] {
                await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.revision(id: id, rev: rev, session: session.identity) }
            }
            for operation in ["get", "history"] {
                await #expect(throws: AccountError.notFound) {
                    if operation == "get" { _ = try await fixture.prompts.get(id: id, session: creatorSession.identity) }
                    else { _ = try await fixture.prompts.revisions(id: id, session: creatorSession.identity) }
                }
            }
            let personal = promptContent(metadata: "title: Recipient\nfavorite: true\nprivate: true\n", body: "Recipient private edit\n")
            _ = try await fixture.writePrompt(baseRev: 3, path: "Recipient.md", content: personal, session: session.identity)
            let shared = try await fixture.prompts.move(id: id, request: .init(baseRev: 4, scope: scope, path: "Returned.md"), session: session.identity)
            #expect(shared.rev == 5 && shared.warnings?.contains { $0.code == "metadata.group_private_removed" } == true)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [5])
            // B14's creator exception still requires visibility, then includes retained earlier eras.
            #expect(try await fixture.prompts.revision(id: id, rev: 4, session: creatorSession.identity).content == personal)
            // The original creator remains an editor permitted to transfer after ownership changes.
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 5, scope: .user, path: "Creator.md"), session: creatorSession.identity)
            await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.get(id: id, session: session.identity) }
            _ = try await fixture.prompts.move(id: id, request: .init(baseRev: 6, scope: scope, path: "Again.md"), session: creatorSession.identity)
            #expect(try await fixture.prompts.revisions(id: id, session: session.identity).revisions.map(\.rev) == [7])
            #expect(try await fixture.prompts.revisions(id: id, session: creatorSession.identity).revisions.map(\.rev) == [7, 6, 5, 4, 3, 2, 1])
            let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: id) })
            #expect(head.createdBy == creator.id && head.createdAt == creator.createdAt && head.updatedBy == creator.id)
            #expect(!head.content.contains("favorite:") && !head.content.contains("private:"))
        }
    }
}
