import Foundation
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

enum PromptRace: Sendable, CaseIterable { case createID, createPath, update }
private enum PromptRaceResult: Sendable {
    case accepted(id: String, write: SyncAPI.WriteResponse)
    case rejected(SyncAPI.ErrorResponse)
}
enum PromptWriteOperation: Sendable, CaseIterable { case create, update }
enum PromptFailureStage: Sendable, CaseIterable { case head, revision, change, scopeHead }

@Suite(.serialized)
struct ServerPromptServiceTests {
    @Test(arguments: PromptRace.allCases, PromptTestScope.allCases)
    func overlappingCreatesAndUpdatesHaveExactlyOneWinner(race: PromptRace, scopeKind: PromptTestScope) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let scope = scopeKind.wire(groupID: group.id)
            for iteration in 0..<5 {
                let id = try ServerTimestamp.id(at: fixture.account.clock.now())
                let otherID = try ServerTimestamp.id(at: fixture.account.clock.now())
                let initialPath = "Original\(iteration).md"
                if race == .update { _ = try await fixture.writePrompt(id: id, scope: scope, path: initialPath, session: session.identity) }
                let before = try await fixture.persistence.count("changes")
                let start = LoginTestLatch()
                let results = try await withThrowingTaskGroup(of: PromptRaceResult.self) { tasks in
                    for index in 0..<2 {
                        let candidateID = race == .createPath && index == 1 ? otherID : id
                        let path = race == .createPath ? (index == 0 ? "Race\(iteration).md" : "RACE\(iteration).md") : "Winner\(iteration)-\(index).md"
                        tasks.addTask {
                            await start.wait()
                            do {
                                let write = try await fixture.writePrompt(id: candidateID, baseRev: race == .update ? 1 : 0, scope: scope, path: path,
                                                                          content: promptContent(id: candidateID, body: "Candidate \(index)\n"), session: session.identity)
                                return .accepted(id: candidateID, write: write)
                            } catch let error as PromptError { return .rejected(error.response) }
                        }
                    }
                    await start.open()
                    var results: [PromptRaceResult] = []
                    for try await result in tasks { results.append(result) }
                    return results
                }
                let accepted = results.compactMap { result -> (String, SyncAPI.WriteResponse)? in
                    if case .accepted(let id, let write) = result { return (id, write) }
                    return nil
                }
                let rejected = results.compactMap { result -> SyncAPI.ErrorResponse? in
                    if case .rejected(let response) = result { return response }
                    return nil
                }
                #expect(accepted.count == 1 && rejected.count == 1)
                let winner = try #require(accepted.first)
                let head = try await fixture.prompts.get(id: winner.0, session: session.identity)
                #expect(head.rev == (race == .update ? 2 : 1) && winner.1.rev == head.rev)
                if race == .createPath {
                    #expect(rejected.first == .pathTaken(existing: .init(id: head.id, rev: head.rev, content: head.content)))
                } else {
                    #expect(rejected.first == .conflict(head: .init(rev: head.rev, scope: head.scope, path: head.path, content: head.content)))
                }
                #expect(try await fixture.persistence.count("changes") == before + 1)
                let revisions = try await fixture.prompts.revisions(id: head.id, session: session.identity).revisions
                #expect(revisions.map(\.rev) == (race == .update ? [2, 1] : [1]))
                if race == .createPath {
                    let loserID = winner.0 == id ? otherID : id
                    await #expect(throws: AccountError.notFound) { _ = try await fixture.prompts.get(id: loserID, session: session.identity) }
                }
            }
        }
    }

    @Test func everyAcceptedWriteStoresAnImmutablePayloadAndPreservesCreationMetadata() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let editor = try await fixture.user("editor")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: editor, role: .editor)
            let ownerSession = try await fixture.account.session(owner)
            let editorSession = try await fixture.account.session(editor)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let source = promptContent(metadata: "title: First\nfavorite: true\nprivate: true\nx: [a, b]\n", body: "First body\n")
            let first = try await fixture.writePrompt(scope: scope, path: "First.md", content: source, session: ownerSession.identity)
            let canonicalFirst = String(decoding: try CanonicalForm.group(Data(source.utf8), filename: "First.md").bytes, as: UTF8.self)
            fixture.account.clock.advance(60)
            let edited = promptContent(metadata: "title: Second\n", body: "Second body\n")
            let second = try await fixture.writePrompt(baseRev: 1, scope: scope, path: "Second.md", content: edited, origin: .llm, session: editorSession.identity)
            let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: GroupTestFixture.livePrompt) })
            #expect(head.createdBy == owner.id && head.createdAt == owner.createdAt && head.updatedBy == editor.id)
            #expect(head.title == "Second" && head.rev == 2 && head.updatedAt == ServerTimestamp.string(fixture.account.clock.now()))
            let revisions = try await fixture.prompts.revisions(id: head.id, session: editorSession.identity).revisions
            #expect(revisions.map(\.authorID) == [editor.id, owner.id] && revisions.map(\.origin) == [.llm, .edit])
            try await fixture.persistence.database.read { sql in
                let changes = try await sql.raw("""
                    SELECT seq, scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at FROM changes ORDER BY seq
                    """).all()
                #expect(changes.count == 2)
                for (index, row) in changes.enumerated() {
                    #expect(try row.decode(column: "seq", as: Int64.self) == (index == 0 ? first.seq : second.seq))
                    #expect(try row.decode(column: "scope_key", as: String.self) == "group:\(group.id)")
                    #expect(try row.decode(column: "scope", as: String.self) == "group")
                    #expect(try row.decode(column: "owner_id", as: String?.self) == nil)
                    #expect(try row.decode(column: "group_id", as: String.self) == group.id)
                    #expect(try row.decode(column: "prompt_id", as: String.self) == head.id)
                    #expect(try row.decode(column: "kind", as: String.self) == "upsert")
                    #expect(try row.decode(column: "path", as: String.self) == (index == 0 ? "First.md" : "Second.md"))
                    #expect(try row.decode(column: "rev", as: Int64.self) == Int64(index + 1))
                    #expect(try row.decode(column: "content", as: String.self) == (index == 0 ? canonicalFirst : edited))
                    #expect(try row.decode(column: "at", as: String.self) == (index == 0 ? owner.createdAt : head.updatedAt))
                }
            }
            // Retained feed payloads never depend on a later head or pruned revision.
            try await fixture.persistence.execute("DELETE FROM prompt_revisions WHERE rev = 1")
            #expect(try await fixture.persistence.string("SELECT content FROM changes WHERE seq = \(bind: first.seq)", column: "content") == canonicalFirst)
            #expect(try await fixture.persistence.string("SELECT path FROM changes WHERE seq = \(bind: first.seq)", column: "path") == "First.md")
            let marker = try await fixture.persistence.database.read { sql in
                let row = try #require(await sql.raw("SELECT head_seq FROM scope_heads WHERE scope_key = \(bind: "group:\(group.id)")").first())
                return try row.decode(column: "head_seq", as: Int64.self)
            }
            #expect(marker == second.seq)
        }
    }

    @Test(arguments: ["demote", "remove", "delete_group", "disable", "revoke"], PromptWriteOperation.allCases)
    func queuedWritesRecheckCurrentSessionAndMembership(change: String, operation: PromptWriteOperation) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: actor, role: .editor)
            let session = try await fixture.account.session(actor)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            if operation == .update { _ = try await fixture.writePrompt(scope: scope, session: session.identity) }
            let before = try await fixture.persistence.promptStorageState()
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let blocker = Task {
                try await fixture.persistence.database.write { sql in
                    switch change {
                    case "demote": try await sql.raw("UPDATE memberships SET role = 'viewer' WHERE user_id = \(bind: actor.id)").run()
                    case "remove": try await sql.raw("DELETE FROM memberships WHERE user_id = \(bind: actor.id)").run()
                    case "delete_group": try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: group.id)").run()
                    case "disable": try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)").run()
                    default: try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    }
                    await entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            let pending = Task { try await fixture.writePrompt(baseRev: operation == .update ? 1 : 0, scope: scope, session: session.identity) }
            await release.open()
            try await blocker.value
            let expected: AccountError = change == "demote" ? .forbidden : (change == "remove" || change == "delete_group" ? .notFound : .unauthorized)
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }

    @Test(arguments: PromptFailureStage.allCases, PromptWriteOperation.allCases)
    func anyStorageFailureRollsBackTheEntireHTTPWrite(stage: PromptFailureStage, operation: PromptWriteOperation) async throws {
        for scopeKind in PromptTestScope.allCases {
            try await withGroupFixture { fixture in
                let owner = try await fixture.user("owner")
                let group = try await fixture.group(owner: owner)
                let session = try await fixture.account.session(owner)
                let scope = scopeKind.wire(groupID: group.id)
                if operation == .update { _ = try await fixture.writePrompt(scope: scope, session: session.identity) }
                let before = try await fixture.persistence.promptStorageState()
                let table: String
                switch stage {
                case .head: table = "prompts"
                case .revision: table = "prompt_revisions"
                case .change: table = "changes"
                case .scopeHead: table = "scope_heads"
                }
                let event = (stage == .head || stage == .scopeHead) && operation == .update ? "UPDATE" : "INSERT"
                try await fixture.persistence.execute("""
                    CREATE TRIGGER injected_prompt_failure AFTER \(unsafeRaw: event) ON \(ident: table)
                    BEGIN SELECT RAISE(ABORT, 's11-private-sql-error-sentinel'); END
                    """)
                let capture = CapturedServerLogs()
                let logger = ServerLogging.makeLogger(level: .trace, clock: fixture.account.clock.now, sink: capture.write)
                let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions, logger: logger)
                let content = promptContent(body: "s11-private-body-sentinel\n")
                let request = SyncAPI.PutPromptRequest(baseRev: operation == .update ? 1 : 0, scope: scope, path: "Renamed.md", content: content)
                try await app.test(.router) { client in
                    try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) {
                        try PromptHTTPTest.error($0, .failure(.internalError))
                        #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
                    }
                    #expect(try await fixture.persistence.promptStorageState() == before)
                    let logText = String(decoding: capture.snapshot(), as: UTF8.self)
                    let noPrivateData = !logText.contains("s11-private-body-sentinel") && !logText.contains("s11-private-sql-error-sentinel")
                        && !logText.contains(session.token.value) && !logText.contains(owner.passwordHash)
                    #expect(noPrivateData)
                    let failures = try capture.events().filter { $0.fields["status"] == "500" }
                    #expect(failures.count == 1 && failures.first?.level == "error")
                    try await fixture.persistence.execute("DROP TRIGGER injected_prompt_failure")
                    let accepted = try await fixture.prompts.put(id: GroupTestFixture.livePrompt, request: request, session: session.identity)
                    #expect(accepted.rev == (operation == .update ? 2 : 1) && accepted.seq == accepted.rev)
                    #expect(try await fixture.persistence.count("prompt_revisions") == Int(accepted.rev))
                    #expect(try await fixture.persistence.count("changes") == Int(accepted.rev))
                }
            }
        }
    }

    @Test func revisionCounterExhaustionFailsWithoutTrappingOrWriting() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            _ = try await fixture.writePrompt(session: session.identity)
            try await fixture.persistence.execute("UPDATE prompts SET rev = \(bind: Int64.max)")
            let before = try await fixture.persistence.promptStorageState()
            await #expect(throws: PromptPersistenceError.self) {
                _ = try await fixture.writePrompt(baseRev: Int64.max, session: session.identity)
            }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }
}
