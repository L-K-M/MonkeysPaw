import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

enum GroupTestRole: Sendable, CaseIterable {
    case owner, editor, viewer, nonMember

    var role: SyncAPI.Role? {
        switch self {
        case .owner: return .owner
        case .editor: return .editor
        case .viewer: return .viewer
        case .nonMember: return nil
        }
    }
}

struct GroupTestFixture: Sendable {
    static let livePrompt = PersistenceTestRepository.prompt
    static let secondLivePrompt = "01ARZ3NDEKTSV4RRFFQ69G5FB0"
    static let tombstone = "01ARZ3NDEKTSV4RRFFQ69G5FB1"
    static let retiredTombstone = "01ARZ3NDEKTSV4RRFFQ69G5FB2"
    static let otherPrompt = "01ARZ3NDEKTSV4RRFFQ69G5FB3"
    static let privatePrompt = "01ARZ3NDEKTSV4RRFFQ69G5FB4"
    let account: AccountTestFixture
    var persistence: PersistenceTestRepository { account.persistence }
    var service: GroupService { .init(database: persistence.database, clock: account.clock.now) }
    var repository: GroupRepository { .init(database: persistence.database) }

    // Group authorization tests mint sessions directly, without credential work.
    func user(_ username: String, kind: SyncAPI.AccountKind = .member) async throws -> AccountRecord {
        let user = try AccountRecord(id: ServerTimestamp.id(at: account.clock.now()), username: username, displayName: nil,
                                     passwordHash: "group-fixture-hash", accountKind: kind,
                                     createdAt: ServerTimestamp.string(account.clock.now()), disabledAt: nil)
        try await account.accounts.repository.write { accounts, _ in try await accounts.insert(user) }
        return user
    }

    func group(owner: AccountRecord, id: String = PersistenceTestRepository.group) async throws -> SyncAPI.Group {
        let group = SyncAPI.Group(id: id, name: "Original", createdBy: owner.id, createdAt: owner.createdAt)
        try await repository.write { groups, _, _, _ in
            try await groups.insert(group)
            try await groups.upsertMember(groupID: id, userID: owner.id, role: .owner, at: owner.createdAt)
        }
        return group
    }

    func member(groupID: String, user: AccountRecord, role: SyncAPI.Role) async throws {
        try await repository.write { groups, _, _, _ in
            try await groups.upsertMember(groupID: groupID, userID: user.id, role: role, at: user.createdAt)
        }
    }

    func seedPrompts(group: SyncAPI.Group, owner: AccountRecord) async throws {
        _ = try await self.group(owner: owner, id: PersistenceTestRepository.otherGroup)
        for id in [Self.livePrompt, Self.secondLivePrompt] {
            try await prompt(id: id, groupID: group.id, authorID: owner.id)
        }
        for id in [Self.tombstone, Self.retiredTombstone] {
            try await prompt(id: id, groupID: group.id, authorID: owner.id, deletedAt: group.createdAt)
        }
        try await persistence.execute("""
            INSERT INTO retired_prompt_ids (prompt_id, scope, group_id, retired_at)
            VALUES (\(bind: Self.retiredTombstone), 'group', \(bind: group.id), \(bind: group.createdAt))
            """)
        try await prompt(id: Self.otherPrompt, groupID: PersistenceTestRepository.otherGroup, authorID: owner.id)
        try await prompt(id: Self.privatePrompt, ownerID: owner.id, authorID: owner.id)
        try await persistence.execute("INSERT INTO scope_floors VALUES (\(bind: "group:\(group.id)"), 1)")
        try await persistence.execute("""
            INSERT INTO snapshots (database_id, scope_key, head_seq, manifest, created_at, expires_at)
            SELECT database_id, \(bind: "group:\(group.id)"), head_seq, x'01', \(bind: group.createdAt),
                   \(bind: ServerTimestamp.string(account.clock.now().addingTimeInterval(600)))
            FROM meta JOIN scope_heads WHERE scope_key = \(bind: "group:\(group.id)")
            """)
    }

    private func prompt(id: String, groupID: String? = nil, ownerID: String? = nil, authorID: String, deletedAt: String? = nil) async throws {
        let scope = groupID == nil ? "user" : "group"
        let key: String
        if let groupID { key = "group:\(groupID)" } else { key = "user:\(try #require(ownerID))" }
        let path = "\(id).md"
        let at = ServerTimestamp.string(account.clock.now())
        try await persistence.database.write { sql in
            try await sql.raw("""
                INSERT INTO prompts (id, scope, owner_id, group_id, path, path_key, content, title, rev,
                                     created_by, created_at, updated_by, updated_at, deleted_at)
                VALUES (\(bind: id), \(bind: scope), \(bind: ownerID), \(bind: groupID), \(bind: path), \(bind: path.lowercased()),
                        'current head', 'Fixture', \(bind: deletedAt == nil ? 2 : 3), \(bind: authorID), \(bind: at),
                        \(bind: authorID), \(bind: at), \(bind: deletedAt))
                """).run()
            for rev in 1...(deletedAt == nil ? 2 : 3) {
                let content = rev == 1 ? "original event payload" : "current head"
                let kind = rev == 3 ? "delete" : "upsert"
                try await sql.raw("""
                    INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id, path, content, created_at, origin)
                    VALUES (\(bind: id), \(bind: rev), \(bind: authorID), \(bind: scope), \(bind: ownerID), \(bind: groupID),
                            \(bind: path), \(bind: content), \(bind: at), \(bind: rev == 3 ? "delete" : "edit"))
                    """).run()
                try await sql.raw("""
                    INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
                    VALUES (\(bind: key), \(bind: scope), \(bind: ownerID), \(bind: groupID), \(bind: id), \(bind: kind),
                            \(bind: path), \(bind: rev), \(bind: rev == 3 ? nil : content), \(bind: at))
                    """).run()
            }
        }
    }
}

func withGroupFixture(_ operation: @Sendable (GroupTestFixture) async throws -> Void) async throws {
    try await withAccountFixture { try await operation(GroupTestFixture(account: $0)) }
}
