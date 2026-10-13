import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

struct StoredTestAudit: Sendable {
    let id: String
    let actorID: String?
    let action: String
    let targetID: String
    let groupID: String?
    let at: String
}

extension PersistenceTestRepository {
    func auditEvents() async throws -> [StoredTestAudit] {
        try await database.read { sql in
            // Explicit columns refresh a reader's cached schema after the audit upgrade.
            try await sql.raw("SELECT id, actor_id, action, target, group_id, at FROM audit_events ORDER BY rowid").all().map { row in
                try .init(id: row.decode(column: "id", as: String.self),
                          actorID: row.decode(column: "actor_id", as: String?.self),
                          action: row.decode(column: "action", as: String.self),
                          targetID: row.decode(column: "target", as: String.self),
                          groupID: row.decode(column: "group_id", as: String?.self),
                          at: row.decode(column: "at", as: String.self))
            }
        }
    }

    func seedAccountData(_ user: AccountRecord, role: SyncAPI.Role = .owner) async throws {
        try await execute("INSERT INTO groups VALUES (\(bind: Self.group), 'Group', \(bind: user.id), \(bind: user.createdAt), NULL)")
        try await execute("INSERT INTO memberships VALUES (\(bind: Self.group), \(bind: user.id), \(bind: role.rawValue), \(bind: user.createdAt))")
        try await execute("""
            INSERT INTO prompts (id, scope, owner_id, path, path_key, content, title, rev,
                                 created_by, created_at, updated_by, updated_at)
            VALUES (\(bind: Self.prompt), 'user', \(bind: user.id), 'Example.md', 'example.md',
                    'preserved private prompt', 'Fixture', 1, \(bind: user.id), \(bind: user.createdAt),
                    \(bind: user.id), \(bind: user.createdAt))
            """)
        try await execute(Self.revision(author: user.id, owner: user.id))
    }
}

enum InjectedAuditError: Error { case failure }

actor AdminTestHasher: PasswordHashing {
    private let entered: LoginTestLatch?
    private let release: LoginTestLatch?
    private var hashCount = 0

    init(entered: LoginTestLatch? = nil, release: LoginTestLatch? = nil) {
        self.entered = entered
        self.release = release
    }

    func hash(_ password: String) async throws -> String {
        hashCount += 1
        await entered?.open()
        await release?.wait()
        return try await BcryptPasswordHasher().hash(password)
    }

    func verify(_ password: String, hash: String) async throws -> Bool {
        Issue.record("Admin password resets must not verify the old password")
        return false
    }

    func hashes() -> Int { hashCount }
}
