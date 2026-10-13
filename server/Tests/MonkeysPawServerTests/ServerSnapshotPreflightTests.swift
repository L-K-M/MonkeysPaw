import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

enum SnapshotPreflightChange: Sendable, CaseIterable {
    case disable, revoke, remove, deleteGroup, renameAndRole, join, databaseID, head
}

@Suite(.serialized)
struct ServerSnapshotPreflightTests {
    @Test(arguments: SnapshotPreflightChange.allCases)
    func snapshotWriterRechecksTheStateSeenByTheReadPreflight(change: SnapshotPreflightChange) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader")
            let group = try await fixture.group(owner: owner)
            let other = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            try await fixture.member(groupID: group.id, user: reader, role: .viewer)
            let session = try await fixture.account.session(reader)
            let personal = PromptOwnership.user(ownerID: reader.id), shared = PromptOwnership.group(groupID: group.id)
            let privatePrompts = try await fixture.seedSnapshot(identity: personal, author: reader, count: 1)
            let sharedPrompts = try await fixture.seedSnapshot(identity: shared, author: owner, count: 1, startingID: 100)
            let otherPrompts = try await fixture.seedSnapshot(identity: .group(groupID: other.id), author: owner, count: 1, startingID: 200)
            let request = try await fixture.feedRequest(cursors: [personal.key: 0, shared.key: 0])
            let newDatabaseID = UUID().uuidString
            let entered = LoginTestLatch(), release = LoginTestLatch(), preflight = LoginTestLatch()
            let blocker = Task {
                // The reader sees the committed old session/scopes/head while this writer holds the gate.
                defer { Task { await entered.open() } }
                try await fixture.persistence.database.write { sql in
                    switch change {
                    case .disable:
                        try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: reader.id)").run()
                    case .revoke:
                        try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    case .remove:
                        try await sql.raw("DELETE FROM memberships WHERE group_id = \(bind: group.id) AND user_id = \(bind: reader.id)").run()
                    case .deleteGroup:
                        try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: group.id)").run()
                    case .renameAndRole:
                        try await sql.raw("UPDATE groups SET name = 'Current' WHERE id = \(bind: group.id)").run()
                        try await sql.raw("UPDATE memberships SET role = 'editor' WHERE group_id = \(bind: group.id) AND user_id = \(bind: reader.id)").run()
                    case .join:
                        try await GroupRepository.Transaction(sql: sql).upsertMember(groupID: other.id, userID: reader.id, role: .viewer, at: reader.createdAt)
                    case .databaseID:
                        try await sql.raw("UPDATE meta SET database_id = \(bind: newDatabaseID)").run()
                    case .head:
                        try await sql.raw("UPDATE prompts SET rev = 2, content = 'Current head payload' WHERE id = \(bind: sharedPrompts[0].id)").run()
                        try await sql.raw("""
                            INSERT INTO changes (scope_key, scope, group_id, prompt_id, kind, path, rev, content, at)
                            VALUES (\(bind: shared.key), 'group', \(bind: group.id), \(bind: sharedPrompts[0].id),
                                    'upsert', \(bind: sharedPrompts[0].path), 2, 'Current head payload', \(bind: reader.createdAt))
                            """).run()
                    }
                    await entered.open()
                    await release.wait()
                }
            }
            let service = SyncFeedService(database: fixture.persistence.database, clock: {
                // page() calls its clock after requireSession has pinned the read snapshot.
                Task { await preflight.open() }
                return fixture.account.clock.now()
            })
            var pending: Task<SyncAPI.PullResponse, any Error>?
            do {
                try await entered.wait(timeout: .seconds(10))
                pending = Task { try await service.pull(request: request, session: session.identity) }
                try await preflight.wait(timeout: .seconds(10))
                #expect(try await fixture.persistence.count("snapshots") == 0)
                await release.open()
                try await blocker.value
                let pull = try #require(pending)
                if change == .disable || change == .revoke {
                    await #expect(throws: AccountError.unauthorized) { _ = try await pull.value }
                    #expect(try await fixture.persistence.count("snapshots") == 0)
                    return
                }
                let response = try await pull.value
                #expect(response.databaseID == (change == .databaseID ? newDatabaseID.lowercased() : request.databaseID))
                #expect(try response.scope(personal.key).items == [.upsert(seq: 1, prompt: privatePrompts[0])])
                if change == .remove || change == .deleteGroup {
                    #expect(response.scopes.map(\.identity.key) == [personal.key] && response.removed == [shared.key])
                    #expect(try await fixture.persistence.count("snapshots") == 1)
                } else {
                    var expected = sharedPrompts[0]
                    if change == .head { expected = .init(id: expected.id, rev: 2, path: expected.path, content: "Current head payload") }
                    let page = try response.scope(shared.key)
                    #expect(page.identity == .group(groupID: group.id, name: change == .renameAndRole ? "Current" : "Original",
                                                    role: change == .renameAndRole ? .editor : .viewer))
                    #expect(page.head == (change == .head ? 4 : 2))
                    #expect(page.items == [.upsert(seq: page.head, prompt: expected)])
                    #expect(page.cursor == String(page.head) && !page.hasMore)
                    #expect(response.removed.isEmpty && response.scopes.count == (change == .join ? 3 : 2))
                    if change == .join {
                        let joined = try response.scope("group:\(other.id)")
                        #expect(joined.identity == .group(groupID: other.id, name: "Original", role: .viewer))
                        #expect(joined.items == [.upsert(seq: 3, prompt: otherPrompts[0])])
                    }
                    #expect(try await fixture.persistence.count("snapshots") == response.scopes.count)
                }
                #expect(response.scopes.allSatisfy { $0.mode == .snapshot && !$0.hasMore })
                #expect(try await fixture.persistence.string("SELECT DISTINCT database_id FROM snapshots", column: "database_id") == response.databaseID.uppercased())
            } catch {
                await release.open()
                _ = await blocker.result
                _ = await pending?.result
                throw error
            }
        }
    }
}
