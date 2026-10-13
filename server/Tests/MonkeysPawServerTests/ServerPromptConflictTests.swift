import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

enum PromptTestScope: Sendable, CaseIterable {
    case user, group
    func wire(groupID: String) -> SyncAPI.PromptScope {
        self == .user ? .user : .group(groupID: groupID)
    }
}

@Suite(.serialized)
struct ServerPromptConflictTests {
    @Test(arguments: PromptTestScope.allCases)
    func conflictPrecedencePathTakenAndScopeChangesUseVisibleHeads(scopeKind: PromptTestScope) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let scope = scopeKind.wire(groupID: group.id)
            let firstID = GroupTestFixture.livePrompt
            let secondID = GroupTestFixture.secondLivePrompt
            let newID = GroupTestFixture.otherPrompt
            _ = try await fixture.writePrompt(scope: scope, path: "Straße/Café.md", session: session.identity)
            _ = try await fixture.writePrompt(id: secondID, scope: scope, path: "Second.md", session: session.identity)
            let first = try await fixture.prompts.get(id: firstID, session: session.identity)
            let second = try await fixture.prompts.get(id: secondID, session: session.identity)
            let conflict = SyncAPI.ErrorResponse.conflict(head: .init(rev: 1, scope: scope, path: second.path, content: second.content))
            let pathTaken = SyncAPI.ErrorResponse.pathTaken(existing: .init(id: firstID, rev: 1, content: first.content))
            let before = try await fixture.persistence.promptStorageState()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let cases: [(String, SyncAPI.PutPromptRequest, SyncAPI.ErrorResponse)] = [
                    (newID, .init(baseRev: 0, scope: scope, path: "STRASSE/Cafe\u{301}.md", content: promptContent(id: newID)), pathTaken),
                    (secondID, .init(baseRev: 0, scope: scope, path: "STRASSE/Café.md", content: promptContent(id: secondID)), conflict),
                    (secondID, .init(baseRev: 99, scope: scope, path: "STRASSE/Café.md", content: promptContent(id: secondID)), conflict),
                    (secondID, .init(baseRev: 1, scope: scope, path: "STRASSE/Café.md", content: promptContent(id: secondID)), pathTaken),
                    (secondID, .init(baseRev: 99, scope: scope, path: "../invalid.md", content: "invalid YAML ---"), conflict),
                    (secondID, .init(baseRev: 1, scope: scopeKind == .user ? .group(groupID: group.id) : .user,
                                     path: "Second.md", content: promptContent(id: secondID)), conflict),
                    // The target is absent; the 409 exposes only the authorized current head.
                    (secondID, .init(baseRev: 1, scope: .group(groupID: PersistenceTestRepository.otherGroup),
                                     path: "Second.md", content: promptContent(id: secondID)), conflict),
                    (newID, .init(baseRev: 1, scope: scope, path: "Missing.md", content: promptContent(id: newID)), .failure(.notFound))
                ]
                for (id, request, expected) in cases {
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) { try PromptHTTPTest.error($0, expected) }
                }
                for suffix in ["", "/revisions", "/revisions/1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(newID)\(suffix)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                // Even identical accepted content records a new revision and event.
                let identical = try await fixture.writePrompt(id: secondID, baseRev: 1, scope: scope, path: second.path, content: second.content, session: session.identity)
                #expect(identical.rev == 2 && identical.seq == 3)
                try await fixture.tombstonePrompt(actorID: owner.id)
                let reused = try await fixture.writePrompt(id: newID, scope: scope, path: "STRASSE/Cafe\u{301}.md", session: session.identity)
                #expect(reused.rev == 1)
            }
        }
    }
}
