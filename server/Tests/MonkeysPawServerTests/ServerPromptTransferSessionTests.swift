import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

enum PromptSessionChange: Sendable {
    case sourceDemote, sourceRemove, sourceDelete, disable, revoke
    case destinationDemote, destinationRemove, destinationDelete, sourceOwnerToEditor
}

@Suite(.serialized)
struct ServerPromptTransferSessionTests {
    private enum BlockerFailure: Error { case injected }

    @Test func failedBlockerStillOpensTheEntryLatch() async throws {
        try await withGroupFixture { fixture in
            let entered = LoginTestLatch(), release = LoginTestLatch()
            defer { Task { await release.open() } }
            let blocker = Task {
                try await Self.holdWrite(database: fixture.persistence.database, entered: entered, release: release) { _ in
                    throw BlockerFailure.injected
                }
            }
            try await entered.wait(timeout: .seconds(10))
            await #expect(throws: BlockerFailure.injected) { try await blocker.value }
        }
    }

    @Test(arguments: DeleteOrMove.allCases.flatMap { operation in
        [PromptSessionChange.sourceDemote, .sourceRemove, .sourceDelete, .disable, .revoke].map { (operation, $0) }
        + (operation == .move ? [PromptSessionChange.destinationDemote, .destinationRemove, .destinationDelete, .sourceOwnerToEditor].map { (operation, $0) } : [])
    })
    func queuedDeleteAndMoveRecheckSourceDestinationAndSession(combination: (DeleteOrMove, PromptSessionChange)) async throws {
        let (operation, change) = combination
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor")
            let source = try await fixture.group(owner: owner)
            let destination = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            for group in [source, destination] { try await fixture.member(groupID: group.id, user: actor, role: .owner) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let id = GroupTestFixture.livePrompt
            _ = try await fixture.writePrompt(scope: .group(groupID: source.id), session: ownerSession.identity)
            let before = try await fixture.persistence.promptStorageState()
            let entered = LoginTestLatch(), release = LoginTestLatch()
            defer { Task { await release.open() } }
            let blocker = Task {
                try await Self.holdWrite(database: fixture.persistence.database, entered: entered, release: release) { sql in
                    switch change {
                    case .sourceDemote, .destinationDemote, .sourceOwnerToEditor:
                        let groupID = change == .destinationDemote ? destination.id : source.id
                        let role = change == .sourceOwnerToEditor ? "editor" : "viewer"
                        try await sql.raw("UPDATE memberships SET role = \(bind: role) WHERE group_id = \(bind: groupID) AND user_id = \(bind: actor.id)").run()
                    case .sourceRemove, .destinationRemove:
                        let groupID = change == .destinationRemove ? destination.id : source.id
                        try await sql.raw("DELETE FROM memberships WHERE group_id = \(bind: groupID) AND user_id = \(bind: actor.id)").run()
                    case .sourceDelete, .destinationDelete:
                        let groupID = change == .destinationDelete ? destination.id : source.id
                        try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: groupID)").run()
                    case .disable:
                        try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)").run()
                    case .revoke:
                        try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    }
                }
            }
            await entered.wait()
            let pending = Task {
                if operation == .delete { return try await fixture.prompts.delete(id: id, query: .init(baseRev: 1), session: session.identity) }
                return try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: .group(groupID: destination.id), path: "Moved.md"),
                                                     session: session.identity)
            }
            await release.open()
            try await blocker.value
            let expected: AccountError = switch change {
            case .disable, .revoke: .unauthorized
            case .sourceDemote, .destinationDemote, .sourceOwnerToEditor: .forbidden
            case .sourceRemove, .destinationRemove, .sourceDelete, .destinationDelete: .notFound
            }
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }

    private static func holdWrite(
        database: ServerDatabase, entered: LoginTestLatch, release: LoginTestLatch,
        change: @escaping @Sendable (any SQLDatabase) async throws -> Void
    ) async throws {
        // A failed transaction must still wake the caller waiting for entry.
        defer { Task { await entered.open() } }
        try await database.write { sql in
            try await change(sql)
            await entered.open()
            await release.wait()
        }
    }
}
