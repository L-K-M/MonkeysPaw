import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerGroupDeletionTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin])
    func deletionRemovesVisibilityAndRetainsPromptHistoryAndIDs(kind: SyncAPI.AccountKind) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let editor = try await fixture.user("editor")
            let viewer = try await fixture.user("viewer")
            let admin = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: editor, role: .editor)
            try await fixture.member(groupID: group.id, user: viewer, role: .viewer)
            try await fixture.seedPrompts(group: group, owner: owner)
            let ownerSession = try await fixture.account.session(owner)
            let adminSession = try await fixture.account.session(admin)
            let editorSession = try await fixture.account.session(editor)
            let viewerSession = try await fixture.account.session(viewer)
            let actor = kind == .admin ? adminSession : ownerSession
            let before = try await fixture.deletionState(groupID: group.id)
            fixture.account.clock.advance(60)
            let now = ServerTimestamp.string(fixture.account.clock.now())
            try await fixture.service.delete(id: group.id, session: actor.identity)
            let after = try await fixture.deletionState(groupID: group.id)
            #expect(after.deletedAt == now && after.memberIDs.isEmpty)
            #expect(after.prompts.count == before.prompts.count)
            #expect(after.revisions == before.revisions + 2 && after.changes == before.changes + 2)
            #expect(after.retiredIDs == 4 && after.snapshots == before.snapshots)
            #expect(after.head > before.head && after.floor == before.floor)
            for prompt in after.prompts {
                let original = try #require(before.prompts.first { $0.id == prompt.id })
                if [GroupTestFixture.livePrompt, GroupTestFixture.secondLivePrompt].contains(prompt.id) {
                    #expect(prompt.rev == original.rev + 1 && prompt.deletedAt == now)
                    #expect(prompt.updatedBy == actor.user.id && prompt.updatedAt == now)
                    #expect(prompt.content == original.content)
                } else { #expect(prompt == original) }
            }
            for session in [ownerSession, editorSession, viewerSession, adminSession] {
                let me = try await fixture.account.accounts.me(session.identity)
                #expect(!me.groups.contains { $0.groupID == group.id })
                await #expect(throws: AccountError.notFound) { _ = try await fixture.service.members(id: group.id, session: session.identity) }
                await #expect(throws: AccountError.notFound) { _ = try await fixture.service.rename(id: group.id, request: .init(name: "Gone"), session: session.identity) }
                await #expect(throws: AccountError.notFound) {
                    _ = try await fixture.service.upsertMember(id: group.id, userID: owner.id, request: .init(role: .owner), session: session.identity)
                }
                await #expect(throws: AccountError.notFound) { try await fixture.service.removeMember(id: group.id, userID: owner.id, session: session.identity) }
                await #expect(throws: AccountError.notFound) { try await fixture.service.delete(id: group.id, session: session.identity) }
            }
            #expect(try await fixture.account.accounts.me(ownerSession.identity).groups.map(\.groupID) == [PersistenceTestRepository.otherGroup])
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["membership.remove", "membership.remove", "membership.remove", "group.delete"])
            #expect(Set(events.prefix(3).map(\.targetID)) == Set([owner.id, editor.id, viewer.id]))
            #expect(events.prefix(3).allSatisfy { $0.groupID == group.id })
            #expect(events.last?.targetID == group.id && events.last?.groupID == nil)
            #expect(events.allSatisfy { $0.actorID == actor.user.id && $0.at == now })
            let retained = try await fixture.persistence.database.read { sql in
                let changes = try await sql.raw("""
                    SELECT * FROM changes WHERE group_id = \(bind: group.id) AND prompt_id = \(bind: GroupTestFixture.livePrompt) ORDER BY seq
                    """).all()
                let last = try #require(changes.last)
                #expect(try changes.first?.decode(column: "content", as: String.self) == "original event payload")
                #expect(try last.decode(column: "kind", as: String.self) == "delete")
                #expect(try last.decode(column: "content", as: String?.self) == nil)
                #expect(try last.decode(column: "rev", as: Int64.self) == 3)
                #expect(try last.decode(column: "scope_key", as: String.self) == "group:\(group.id)")
                #expect(try last.decode(column: "path", as: String.self) == "\(GroupTestFixture.livePrompt).md")
                let revision = try #require(await sql.raw("""
                    SELECT * FROM prompt_revisions WHERE prompt_id = \(bind: GroupTestFixture.livePrompt) AND rev = 3
                    """).first())
                #expect(try revision.decode(column: "author_id", as: String.self) == actor.user.id)
                #expect(try revision.decode(column: "origin", as: String.self) == "delete")
                #expect(try revision.decode(column: "content", as: String.self) == "current head")
                #expect(try revision.decode(column: "group_id", as: String.self) == group.id)
                let retired = try await sql.raw("SELECT * FROM retired_prompt_ids ORDER BY prompt_id").all()
                return try retired.allSatisfy {
                    try $0.decode(column: "scope", as: String.self) == "group"
                        && $0.decode(column: "group_id", as: String.self) == group.id
                        && $0.decode(column: "retired_at", as: String.self) ==
                            ([GroupTestFixture.tombstone, GroupTestFixture.retiredTombstone].contains($0.decode(column: "prompt_id", as: String.self)) ? group.createdAt : now)
                }
            }
            #expect(retained)
            // Physical retention later cannot erase the immutable event or retired identity.
            try await fixture.persistence.execute("DELETE FROM prompts WHERE group_id = \(bind: group.id)")
            #expect(try await fixture.persistence.count("retired_prompt_ids") == 4)
            #expect(try await fixture.persistence.count("changes") == after.changes)
            await fixture.persistence.reject("""
                INSERT INTO prompts (id, scope, owner_id, path, path_key, content, title, rev, created_by, created_at, updated_by, updated_at)
                VALUES (\(bind: GroupTestFixture.livePrompt), 'user', \(bind: owner.id), 'Revived.md', 'revived.md',
                        'revived', 'Fixture', 1, \(bind: owner.id), \(bind: now), \(bind: owner.id), \(bind: now))
                """)
            await fixture.persistence.reject("DELETE FROM groups WHERE id = \(bind: group.id)")
        }
    }

    @Test(arguments: [DeletionOutcome.commit, .rollback])
    func readersSeeWholeStateAndAuditFailureRollsBackEveryDeletionWrite(outcome: DeletionOutcome) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let viewer = try await fixture.user("viewer")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: viewer, role: .viewer)
            try await fixture.seedPrompts(group: group, owner: owner)
            let session = try await fixture.account.session(owner)
            let before = try await fixture.deletionState(groupID: group.id)
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let service = GroupService(database: fixture.persistence.database, clock: fixture.account.clock.now) { audit, event in
                try await audit.insert(event)
                if event.action == .groupDelete {
                    await entered.open()
                    await release.wait()
                    if outcome == .rollback { throw InjectedAuditError.failure }
                }
            }
            let pending = Task {
                do { try await service.delete(id: group.id, session: session.identity) }
                catch { await entered.open(); throw error }
            }
            await entered.wait()
            #expect(try await fixture.deletionState(groupID: group.id) == before)
            #expect(try await fixture.account.accounts.me(session.identity).groups.contains { $0.groupID == group.id })
            #expect(try await fixture.service.members(id: group.id, session: session.identity).members.count == 2)
            await release.open()
            if outcome == .rollback {
                await #expect(throws: InjectedAuditError.failure) { try await pending.value }
                #expect(try await fixture.deletionState(groupID: group.id) == before)
            } else {
                try await pending.value
                let after = try await fixture.deletionState(groupID: group.id)
                #expect(after.deletedAt != nil && after.memberIDs.isEmpty && after.retiredIDs == 4)
                #expect(after.auditEvents == 3 && after.changes == before.changes + 2 && after.revisions == before.revisions + 2)
                #expect(try await !fixture.account.accounts.me(session.identity).groups.contains { $0.groupID == group.id })
            }
        }
    }

    @Test func failedPromptEventInsertRollsBackGroupMembershipsAndAllPromptWrites() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            try await fixture.seedPrompts(group: group, owner: owner)
            let session = try await fixture.account.session(owner)
            let before = try await fixture.deletionState(groupID: group.id)
            try await fixture.persistence.execute("""
                CREATE TRIGGER injected_group_delete_failure BEFORE INSERT ON changes
                WHEN NEW.kind = 'delete' AND NEW.prompt_id = \(literal: GroupTestFixture.secondLivePrompt)
                BEGIN SELECT RAISE(ABORT, 'Injected failure'); END
                """)
            await #expect(throws: (any Error).self) { try await fixture.service.delete(id: group.id, session: session.identity) }
            #expect(try await fixture.deletionState(groupID: group.id) == before)
            try await fixture.persistence.execute("DROP TRIGGER injected_group_delete_failure")
            try await fixture.service.delete(id: group.id, session: session.identity)
            #expect(try await fixture.deletionState(groupID: group.id).deletedAt != nil)
        }
    }
}

enum DeletionOutcome: Sendable { case commit, rollback }

private struct GroupPromptHead: Sendable, Equatable {
    let id: String
    let rev: Int64
    let content: String
    let updatedBy: String
    let updatedAt: String
    let deletedAt: String?
}

private struct GroupDeletionState: Sendable, Equatable {
    let deletedAt: String?
    let memberIDs: [String]
    let prompts: [GroupPromptHead]
    let revisions: Int
    let changes: Int
    let retiredIDs: Int
    let snapshots: Int
    let head: Int64
    let floor: Int64
    let auditEvents: Int
}

private extension GroupTestFixture {
    func deletionState(groupID: String) async throws -> GroupDeletionState {
        try await persistence.database.read { sql in
            func count(_ table: String) async throws -> Int {
                let row = try #require(await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
                return try row.decode(column: "count", as: Int.self)
            }
            let group = try #require(await sql.raw("SELECT deleted_at FROM groups WHERE id = \(bind: groupID)").first())
            let members = try await sql.raw("SELECT user_id FROM memberships WHERE group_id = \(bind: groupID) ORDER BY user_id").all()
            let prompts: [GroupPromptHead] = try await sql.raw("SELECT * FROM prompts ORDER BY id").all().map {
                try .init(id: $0.decode(column: "id", as: String.self), rev: $0.decode(column: "rev", as: Int64.self),
                          content: $0.decode(column: "content", as: String.self), updatedBy: $0.decode(column: "updated_by", as: String.self),
                          updatedAt: $0.decode(column: "updated_at", as: String.self), deletedAt: $0.decode(column: "deleted_at", as: String?.self))
            }
            let markers = try #require(await sql.raw("""
                SELECT head_seq, floor_seq FROM scope_heads JOIN scope_floors USING (scope_key) WHERE scope_key = \(bind: "group:\(groupID)")
                """).first())
            return try await .init(deletedAt: group.decode(column: "deleted_at", as: String?.self),
                                   memberIDs: members.map { try $0.decode(column: "user_id", as: String.self) }, prompts: prompts,
                                   revisions: count("prompt_revisions"), changes: count("changes"), retiredIDs: count("retired_prompt_ids"),
                                   snapshots: count("snapshots"), head: markers.decode(column: "head_seq", as: Int64.self),
                                   floor: markers.decode(column: "floor_seq", as: Int64.self), auditEvents: count("audit_events"))
        }
    }
}
