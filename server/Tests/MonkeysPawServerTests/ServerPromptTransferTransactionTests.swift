import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

enum PromptMutation: Sendable { case edit, delete, move }
private enum PromptMutationResult: Sendable {
    case accepted(PromptMutation, SyncAPI.WriteResponse)
    case rejected(SyncAPI.ErrorResponse)
}
enum DeleteOrMove: Sendable, CaseIterable { case delete, move }
private enum TransferFailureStage: Sendable, CaseIterable {
    case head, revision, removal, upsert, sourceHead, destinationHead, retired
}

@Suite(.serialized)
struct ServerPromptTransferTransactionTests {
    @Test(arguments: [
        [PromptMutation.edit, .delete], [.edit, .move], [.delete, .move], [.edit, .delete, .move]
    ], PromptTransferDirection.allCases)
    func editDeleteAndMoveCASRacesHaveExactlyOneWinner(operations: [PromptMutation], direction: PromptTransferDirection) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            _ = try await fixture.group(owner: owner)
            _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(owner)
            for iteration in 0..<5 {
                let id = try ServerTimestamp.id(at: fixture.account.clock.now())
                _ = try await fixture.writePrompt(id: id, scope: direction.sourceScope, path: "Original\(iteration).md", session: session.identity)
                let before = try await fixture.persistence.promptEvents().count
                let start = LoginTestLatch()
                let results = try await withThrowingTaskGroup(of: PromptMutationResult.self) { tasks in
                    for operation in operations {
                        tasks.addTask {
                            await start.wait()
                            do {
                                let write: SyncAPI.WriteResponse
                                switch operation {
                                case .edit:
                                    write = try await fixture.writePrompt(id: id, baseRev: 1, scope: direction.sourceScope,
                                                                          path: "Edited\(iteration).md", content: promptContent(id: id, body: "Edited\n"),
                                                                          session: session.identity)
                                case .delete:
                                    write = try await fixture.prompts.delete(id: id, query: .init(baseRev: 1), session: session.identity)
                                case .move:
                                    write = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: direction.destinationScope,
                                                                                               path: "Moved\(iteration).md"), session: session.identity)
                                }
                                return .accepted(operation, write)
                            } catch let error as PromptError { return .rejected(error.response) }
                        }
                    }
                    await start.open()
                    var results: [PromptMutationResult] = []
                    for try await result in tasks { results.append(result) }
                    return results
                }
                let accepted = results.compactMap { result -> (PromptMutation, SyncAPI.WriteResponse)? in
                    if case .accepted(let operation, let write) = result { return (operation, write) }
                    return nil
                }
                let rejected = results.compactMap { result -> SyncAPI.ErrorResponse? in
                    if case .rejected(let response) = result { return response }
                    return nil
                }
                #expect(accepted.count == 1 && rejected.count == operations.count - 1)
                let (winner, write) = try #require(accepted.first)
                let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: id) })
                #expect(head.rev == 2 && write.rev == 2 && head.createdBy == owner.id)
                #expect(rejected.allSatisfy { $0 == (winner == .delete ? .deleted : .conflict(head: head.conflictHead)) })
                let events = try await fixture.persistence.promptEvents()
                #expect(events.count == before + (winner == .move ? 2 : 1) && events.last?.seq == write.seq)
                let revisions = try await fixture.prompts.revisions(id: id, session: session.identity).revisions
                #expect(revisions.map(\.rev) == [2, 1])
                #expect(revisions.first?.origin == (winner == .move ? .move : winner == .delete ? .delete : .edit))
                let retired = try await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.retiredIdentity(id: id) }
                #expect((retired != nil) == (winner == .delete) && (head.deletedAt != nil) == (winner == .delete))
            }
        }
    }

    @Test(arguments: PromptTransferDirection.allCases)
    func concurrentMovesToAFoldedDestinationPathHaveOneWinner(direction: PromptTransferDirection) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            _ = try await fixture.group(owner: owner)
            _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(owner)
            for iteration in 0..<5 {
                let ids = try [ServerTimestamp.id(at: fixture.account.clock.now()), ServerTimestamp.id(at: fixture.account.clock.now())]
                for (index, id) in ids.enumerated() {
                    _ = try await fixture.writePrompt(id: id, scope: direction.sourceScope, path: "Source\(iteration)-\(index).md", session: session.identity)
                }
                let before = try await fixture.persistence.promptEvents().count
                let start = LoginTestLatch()
                let results = try await withThrowingTaskGroup(of: PromptMutationResult.self) { tasks in
                    for (index, id) in ids.enumerated() {
                        tasks.addTask {
                            await start.wait()
                            do {
                                let path = index == 0 ? "Straße\(iteration)/Café.md" : "STRASSE\(iteration)/Cafe\u{301}.md"
                                let write = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: direction.destinationScope,
                                                                                               path: path), session: session.identity)
                                return .accepted(.move, write)
                            } catch let error as PromptError { return .rejected(error.response) }
                        }
                    }
                    await start.open()
                    var results: [PromptMutationResult] = []
                    for try await result in tasks { results.append(result) }
                    return results
                }
                let heads = try await fixture.promptRepository.read { prompts, _, _, _ in
                    try await [prompts.head(id: ids[0]), prompts.head(id: ids[1])]
                }
                let winner = try #require(heads.compactMap { $0 }.first { $0.rev == 2 })
                #expect(heads.compactMap { $0 }.filter { $0.rev == 1 }.count == 1)
                #expect(results.filter { if case .accepted = $0 { return true }; return false }.count == 1)
                #expect(results.filter { if case .rejected(.pathTaken(existing: winner.existing)) = $0 { return true }; return false }.count == 1)
                #expect(try await fixture.persistence.promptEvents().count == before + 2)
            }
        }
    }

    @Test(arguments: PromptTransferDirection.allCases)
    func pairedEventsRetainEventTimePayloadAfterFurtherWritesAndPruning(direction: PromptTransferDirection) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            _ = try await fixture.group(owner: owner)
            _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(owner)
            let id = GroupTestFixture.livePrompt
            let original = promptContent(metadata: "title: First\nfavorite: true\nprivate: true\n", body: "Original bytes\r\n")
            _ = try await fixture.writePrompt(scope: direction.sourceScope, path: "Before.md", content: original, session: session.identity)
            let stored = try await fixture.prompts.get(id: id, session: session.identity).content
            let firstEvents = try await fixture.persistence.promptEvents()
            fixture.account.clock.advance(60)
            let at = ServerTimestamp.string(fixture.account.clock.now())
            let write = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: direction.destinationScope,
                                                                            path: "Moved/Cafe\u{301}.md"), session: session.identity)
            let moved = try await fixture.prompts.get(id: id, session: session.identity)
            let events = try await fixture.persistence.promptEvents()
            #expect(events.count == 3 && events.first == firstEvents.first && write.seq == 3)
            let old = events[1], new = events[2]
            #expect(old.seq == 2 && new.seq == write.seq && old.rev == 2 && new.rev == 2 && write.rev == 2)
            #expect(old.promptID == id && new.promptID == id && old.at == at && new.at == at)
            #expect(old.kind == "move_out" && old.content == nil && old.path == "Before.md")
            #expect(old.identity == PromptOwnership(scope: direction.sourceScope, userID: owner.id))
            #expect(new.kind == "upsert" && new.content == moved.content && new.path == "Moved/Café.md")
            #expect(new.identity == PromptOwnership(scope: direction.destinationScope, userID: owner.id))
            #expect(events[0].content == stored && events[0].path == "Before.md" && events[0].rev == 1)
            let revision = try await fixture.prompts.revision(id: id, rev: 2, session: session.identity)
            #expect(revision.origin == .move && revision.content == moved.content && revision.scope == direction.destinationScope)
            _ = try await fixture.writePrompt(baseRev: 2, scope: direction.destinationScope, path: "Final.md",
                                              content: promptContent(body: "Later bytes\n"), session: session.identity)
            _ = try await fixture.prompts.delete(id: id, query: .init(baseRev: 3), session: session.identity)
            #expect(Array(try await fixture.persistence.promptEvents().prefix(3)) == events)
            try await fixture.persistence.execute("DELETE FROM prompt_revisions WHERE prompt_id = \(bind: id)")
            #expect(Array(try await fixture.persistence.promptEvents().prefix(3)) == events)
            try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: id)")
            let retained = try await fixture.persistence.promptEvents()
            #expect(retained.count == 5 && Array(retained.prefix(3)) == events)
            try await fixture.persistence.database.read { sql in
                for (scope, seq) in [(direction.sourceScope, Int64(2)), (direction.destinationScope, Int64(5))] {
                    let key = PromptOwnership(scope: scope, userID: owner.id).key
                    let row = try #require(await sql.raw("SELECT head_seq FROM scope_heads WHERE scope_key = \(bind: key)").first())
                    #expect(try row.decode(column: "head_seq", as: Int64.self) == seq)
                }
            }
        }
    }

    @Test(arguments: DeleteOrMove.allCases, PromptTransferDirection.allCases)
    func eachStorageFailureRollsBackHeadHistoryEventsRetirementAndSequence(operation: DeleteOrMove, direction: PromptTransferDirection) async throws {
        let stages = TransferFailureStage.allCases.filter {
            operation == .move ? $0 != .retired : $0 != .upsert && $0 != .destinationHead
        }
        for stage in stages {
            for existingDestination in (stage == .destinationHead ? [false, true] : [false]) {
                try await withGroupFixture { fixture in
                    let owner = try await fixture.user("owner")
                    _ = try await fixture.group(owner: owner)
                    _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
                    let session = try await fixture.account.session(owner)
                    let id = GroupTestFixture.livePrompt
                    _ = try await fixture.writePrompt(scope: direction.sourceScope, content: promptContent(body: "s12-private-content-sentinel\n"), session: session.identity)
                    if existingDestination {
                        _ = try await fixture.writePrompt(id: GroupTestFixture.secondLivePrompt, scope: direction.destinationScope,
                                                          path: "Other.md", session: session.identity)
                    }
                    let before = try await fixture.persistence.promptStorageState()
                    let sourceKey = PromptOwnership(scope: direction.sourceScope, userID: owner.id).key
                    let destinationKey = PromptOwnership(scope: direction.destinationScope, userID: owner.id).key
                    let table: String, event: String, condition: SQLQueryString
                    switch stage {
                    case .head: table = "prompts"; event = "UPDATE"; condition = "NEW.id = \(literal: id)"
                    case .revision: table = "prompt_revisions"; event = "INSERT"; condition = "NEW.prompt_id = \(literal: id)"
                    case .removal:
                        table = "changes"; event = "INSERT"
                        condition = "NEW.kind = \(literal: operation == .delete ? "delete" : "move_out")"
                    case .upsert: table = "changes"; event = "INSERT"; condition = "NEW.kind = 'upsert'"
                    case .sourceHead: table = "scope_heads"; event = "UPDATE"; condition = "NEW.scope_key = \(literal: sourceKey)"
                    case .destinationHead:
                        table = "scope_heads"; event = existingDestination ? "UPDATE" : "INSERT"
                        condition = "NEW.scope_key = \(literal: destinationKey)"
                    case .retired: table = "retired_prompt_ids"; event = "INSERT"; condition = "NEW.prompt_id = \(literal: id)"
                    }
                    try await fixture.persistence.execute("""
                        CREATE TRIGGER injected_transfer_failure AFTER \(unsafeRaw: event) ON \(ident: table) WHEN \(condition)
                        BEGIN SELECT RAISE(ABORT, 's12-private-sql-error-sentinel'); END
                        """)
                    let capture = CapturedServerLogs()
                    let logger = ServerLogging.makeLogger(level: .trace, clock: fixture.account.clock.now, sink: capture.write)
                    let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts,
                                              sessions: fixture.account.sessions, logger: logger)
                    let move = SyncAPI.MovePromptRequest(baseRev: 1, scope: direction.destinationScope, path: "Moved.md")
                    let uri = "/api/v1/prompts/\(id)" + (operation == .delete ? "?base_rev=1" : "/move")
                    try await app.test(.router) { client in
                        try await client.execute(uri: uri, method: operation == .delete ? .delete : .post, headers: PromptHTTPTest.headers(session),
                                                 body: operation == .delete ? nil : .init(bytes: JSONEncoder().encode(move))) {
                            try PromptHTTPTest.error($0, .failure(.internalError))
                            #expect(String(buffer: $0.body) == "{\"code\":\"internal_error\"}")
                        }
                        #expect(try await fixture.persistence.promptStorageState() == before)
                        let logText = String(decoding: capture.snapshot(), as: UTF8.self)
                        #expect(!logText.contains("s12-private-content-sentinel") && !logText.contains("s12-private-sql-error-sentinel"))
                        #expect(!logText.contains(session.token.value) && !logText.contains(owner.passwordHash))
                        let failures = try capture.events().filter { $0.fields["status"] == "500" }
                        #expect(failures.count == 1 && failures.first?.level == "error")
                        try await fixture.persistence.execute("DROP TRIGGER injected_transfer_failure")
                        try await client.execute(uri: uri, method: operation == .delete ? .delete : .post, headers: PromptHTTPTest.headers(session),
                                                 body: operation == .delete ? nil : .init(bytes: JSONEncoder().encode(move))) {
                            let accepted = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                            #expect(accepted.rev == 2 && accepted.seq == (operation == .move ? 3 : 2) + (existingDestination ? 1 : 0))
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: DeleteOrMove.allCases)
    func exhaustionNeverTrapsOrMutatesState(operation: DeleteOrMove) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            _ = try await fixture.writePrompt(session: session.identity)
            try await fixture.persistence.execute("UPDATE prompts SET rev = \(bind: Int64.max)")
            let before = try await fixture.persistence.promptStorageState()
            await #expect(throws: PromptPersistenceError.revisionExhausted) {
                if operation == .delete {
                    _ = try await fixture.prompts.delete(id: GroupTestFixture.livePrompt, query: .init(baseRev: Int64.max), session: session.identity)
                } else {
                    _ = try await fixture.prompts.move(id: GroupTestFixture.livePrompt,
                                                      request: .init(baseRev: Int64.max, scope: .group(groupID: group.id), path: "Moved.md"), session: session.identity)
                }
            }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }
}
