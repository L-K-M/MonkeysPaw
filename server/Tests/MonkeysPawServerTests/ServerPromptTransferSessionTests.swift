import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptTransferSessionTests {
    @Test(arguments: DeleteOrMove.allCases.flatMap { operation in
        ["source_demote", "source_remove", "source_delete", "disable", "revoke"].map { (operation, $0) }
        + (operation == .move ? ["destination_demote", "destination_remove", "destination_delete", "source_owner_to_editor"].map { (operation, $0) } : [])
    })
    func queuedDeleteAndMoveRecheckSourceDestinationAndSession(combination: (DeleteOrMove, String)) async throws {
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
            let blocker = Task {
                try await fixture.persistence.database.write { sql in
                    switch change {
                    case "source_demote", "destination_demote", "source_owner_to_editor":
                        let groupID = change == "destination_demote" ? destination.id : source.id
                        let role = change == "source_owner_to_editor" ? "editor" : "viewer"
                        try await sql.raw("UPDATE memberships SET role = \(bind: role) WHERE group_id = \(bind: groupID) AND user_id = \(bind: actor.id)").run()
                    case "source_remove", "destination_remove":
                        let groupID = change == "destination_remove" ? destination.id : source.id
                        try await sql.raw("DELETE FROM memberships WHERE group_id = \(bind: groupID) AND user_id = \(bind: actor.id)").run()
                    case "source_delete", "destination_delete":
                        let groupID = change == "destination_delete" ? destination.id : source.id
                        try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: groupID)").run()
                    case "disable":
                        try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)").run()
                    default:
                        try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    }
                    await entered.open()
                    await release.wait()
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
            let expected: AccountError
            if change == "disable" || change == "revoke" { expected = .unauthorized }
            else if change == "source_demote" || change == "destination_demote" || change == "source_owner_to_editor" { expected = .forbidden }
            else { expected = .notFound }
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.promptStorageState() == before)
        }
    }
}
