import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPersistenceTests {
    private typealias Fixtures = PersistenceTestRepository

    @Test func emptyAndRepeatedMigrationsKeepIdentityAndAllTables() async throws {
        try await withPersistenceDatabase { repository in
            let identity = try await MetaRepository(database: repository.database).databaseID()
            try await repository.database.migrate()
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            #expect(try await repository.count("schema_migrations") == 1)
            for table in ["users", "groups", "memberships", "prompts", "prompt_revisions", "changes",
                          "scope_heads", "scope_floors", "devices", "invites", "audit_events",
                          "login_account_buckets", "login_ip_buckets", "retired_prompt_ids", "snapshots"] {
                #expect(try await repository.count(table) == 0)
            }
        }
    }

    @Test func failedMigrationRollsBackDDLDataAndMarkerAndCanRetry() async throws {
        try await withPersistenceDatabase { repository in
            let failing = ServerMigration(name: "test_failure") { sql in
                try await sql.raw("CREATE TABLE rollback_probe (value TEXT)").run()
                try await sql.raw("INSERT INTO rollback_probe VALUES ('must disappear')").run()
                try await sql.raw("INSERT INTO no_such_table VALUES (1)").run()
            }
            await #expect(throws: (any Error).self) { try await repository.database.migrate([failing]) }
            #expect(try await repository.count("schema_migrations") == 1)
            let retry = ServerMigration(name: failing.name) { sql in
                try await sql.raw("CREATE TABLE rollback_probe (value TEXT)").run()
                try await sql.raw("INSERT INTO rollback_probe VALUES ('committed')").run()
            }
            try await repository.database.migrate([retry])
            try await repository.database.migrate([retry])
            #expect(try await repository.count("rollback_probe") == 1)
            #expect(try await repository.count("schema_migrations") == 2)
        }
    }

    @Test func databaseIdentityRejectsMalformedUUIDsAndAllowsExplicitRestoreRotation() async throws {
        try await withPersistenceDatabase { repository in
            let identity = try await MetaRepository(database: repository.database).databaseID()
            for invalid in ["x", String(repeating: "A", count: 36), identity.uuidString + "\u{0}",
                            identity.uuidString.replacingOccurrences(of: "-", with: "A")] {
                await repository.reject("UPDATE meta SET database_id = \(bind: invalid)")
            }
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            let restoredID = UUID()
            try await repository.execute("UPDATE meta SET database_id = \(bind: restoredID.uuidString)")
            #expect(try await MetaRepository(database: repository.database).databaseID() == restoredID)
        }
    }

    @Test func identityAndDataSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let firstID = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            try await Fixtures(database: database).seed()
            return try await MetaRepository(database: database).databaseID()
        }
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database async throws -> Void in
            #expect(try await MetaRepository(database: database).databaseID() == firstID)
            #expect(try await Fixtures(database: database).count("users") == 2)
        }
    }

    @Test func connectionPragmasApplyToWritersAndConcurrentReaders() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.database.write { try await Self.assertPragmas($0) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await repository.database.read { try await Self.assertPragmas($0) } }
                }
                try await group.waitForAll()
            }
            await #expect(throws: (any Error).self) {
                try await repository.database.read { try await $0.raw("CREATE TABLE illegal_reader_write (id INTEGER)").run() }
            }
        }
    }

    @Test func userKindUsernameAndPrimaryKeyConstraints() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            await repository.reject("INSERT INTO meta (singleton, database_id) VALUES (2, 'other')")
            await repository.reject("INSERT INTO meta (singleton, database_id) VALUES (1, 'other')")
            await repository.reject("DELETE FROM meta")
            await repository.reject("INSERT OR REPLACE INTO meta VALUES (1, \(bind: UUID().uuidString))")
            await repository.reject("UPDATE meta SET singleton = 2")
            for username in ["", "Alice", "é", "a b", "a\u{0}b", String(repeating: "a", count: 65)] {
                await repository.reject("UPDATE users SET username = \(bind: username) WHERE id = \(bind: Fixtures.user)")
            }
            await repository.reject("UPDATE users SET username = 'bob' WHERE id = \(bind: Fixtures.user)")
            await repository.reject("UPDATE users SET account_kind = 'owner'")
            await repository.reject("UPDATE users SET id = \(bind: Fixtures.otherUser) WHERE id = \(bind: Fixtures.user)")
            try await repository.execute("UPDATE users SET account_kind = 'admin', username = 'alice_1.-' WHERE id = \(bind: Fixtures.user)")
        }
    }

    @Test func groupMembershipDeviceInviteAndAuditConstraints() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let membership: SQLQueryString = "INSERT INTO memberships VALUES (\(bind: Fixtures.group), \(bind: Fixtures.user), 'owner', \(bind: Fixtures.time))"
            try await repository.execute(membership)
            await repository.reject(membership)
            for (table, column) in [("groups", "created_by"), ("memberships", "group_id"), ("memberships", "user_id")] {
                await repository.reject("UPDATE \(ident: table) SET \(ident: column) = 'missing'")
            }
            await repository.reject("UPDATE groups SET id = \(bind: Fixtures.otherGroup) WHERE id = \(bind: Fixtures.group)")
            await repository.reject("UPDATE memberships SET role = 'admin'")
            for role in ["viewer", "editor", "owner"] {
                try await repository.execute("UPDATE memberships SET role = \(bind: role)")
            }
            try await repository.execute("INSERT INTO devices VALUES ('device', \(bind: Fixtures.user), 'Device', 'hash', \(bind: Fixtures.time), \(bind: Fixtures.time), NULL)")
            await repository.reject("INSERT INTO devices SELECT 'device2', user_id, name, token_hash, created_at, last_seen_at, revoked_at FROM devices")
            await repository.reject("INSERT INTO devices SELECT * FROM devices")
            await repository.reject("UPDATE devices SET user_id = 'missing'")
            try await repository.execute("INSERT INTO invites VALUES ('invite', NULL, NULL, \(bind: Fixtures.user), \(bind: Fixtures.time), NULL)")
            await repository.reject("INSERT INTO invites SELECT * FROM invites")
            await repository.reject("UPDATE invites SET role = 'viewer'")
            await repository.reject("UPDATE invites SET group_id = \(bind: Fixtures.group)")
            try await repository.execute("UPDATE invites SET group_id = \(bind: Fixtures.group), role = 'viewer'")
            await repository.reject("UPDATE invites SET role = 'admin'")
            await repository.reject("UPDATE invites SET group_id = 'missing'")
            await repository.reject("UPDATE invites SET created_by = 'missing'")
            try await repository.execute("INSERT INTO audit_events VALUES ('audit', \(bind: Fixtures.user), 'user.disable', 'target', \(bind: Fixtures.time))")
            await repository.reject("INSERT INTO audit_events SELECT * FROM audit_events")
            await repository.reject("UPDATE audit_events SET actor_id = 'missing'")
            try await repository.execute("UPDATE audit_events SET actor_id = NULL")
            await repository.reject("DELETE FROM users WHERE id = \(bind: Fixtures.user)")
            await repository.reject("DELETE FROM groups WHERE id = \(bind: Fixtures.group)")
        }
    }

    @Test func ownershipChecksRejectEveryInvalidScopeShape() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: Fixtures.prompt)
            let invalid: [(String, String?, String?)] = [
                ("user", nil, nil), ("user", Fixtures.user, Fixtures.group), ("user", nil, Fixtures.group),
                ("group", nil, nil), ("group", Fixtures.user, Fixtures.group), ("group", Fixtures.user, nil),
                ("other", Fixtures.user, nil),
            ]
            for (scope, owner, group) in invalid {
                await repository.reject("UPDATE prompts SET scope = \(bind: scope), owner_id = \(bind: owner), group_id = \(bind: group)")
                await repository.reject(Fixtures.revision(scope: scope, owner: owner, group: group))
                await repository.reject(Fixtures.change(scope: scope, owner: owner, group: group))
                await repository.reject(Fixtures.retired(scope: scope, owner: owner, group: group))
            }
            try await repository.execute(Fixtures.revision())
            try await repository.execute(Fixtures.revision(rev: 2, scope: "group", owner: nil, group: Fixtures.group))
        }
    }

    @Test func foldedPathsAreUniqueOnlyWithinLiveMatchingScopes() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            for (index, variants) in [["Résumé.md", "RE\u{301}SUME\u{301}.md"], ["Straße.md", "STRASSE.md"]].enumerated() {
                let path = variants[0]
                let alternate = variants[1]
                try await repository.insertPrompt(id: "private-\(index)", path: path)
                await #expect(throws: (any Error).self) { try await repository.insertPrompt(id: "clash-\(index)", path: alternate) }
                try await repository.insertPrompt(id: "other-\(index)", path: alternate, owner: Fixtures.otherUser)
                try await repository.insertPrompt(id: "group-\(index)", path: path, scope: .group, owner: nil, group: Fixtures.group)
                await #expect(throws: (any Error).self) {
                    try await repository.insertPrompt(id: "group-clash-\(index)", path: alternate, scope: .group, owner: nil, group: Fixtures.group)
                }
                try await repository.insertPrompt(id: "other-group-\(index)", path: alternate, scope: .group, owner: nil, group: Fixtures.otherGroup)
                try await repository.insertPrompt(id: "deleted-\(index)", path: alternate, deleted: Fixtures.time)
                try await repository.insertPrompt(id: "deleted-group-\(index)", path: alternate, scope: .group, owner: nil, group: Fixtures.group, deleted: Fixtures.time)
                try await repository.execute("UPDATE prompts SET deleted_at = \(bind: Fixtures.time) WHERE id = \(bind: "private-\(index)")")
                try await repository.insertPrompt(id: "replacement-\(index)", path: alternate)
                await repository.reject("UPDATE prompts SET deleted_at = NULL WHERE id = \(bind: "private-\(index)")")
            }
        }
    }

    @Test func promptAndRevisionReferencesAndPositiveRevisions() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: Fixtures.prompt)
            for column in ["owner_id", "created_by", "updated_by"] {
                await repository.reject("UPDATE prompts SET \(ident: column) = 'missing'")
            }
            await repository.reject("UPDATE prompts SET scope = 'group', owner_id = NULL, group_id = 'missing'")
            for rev in [-1, 0] {
                await repository.reject("UPDATE prompts SET rev = \(bind: rev)")
                await repository.reject(Fixtures.revision(rev: rev))
            }
            await repository.reject("UPDATE prompts SET rev = 1.5")
            try await repository.execute(Fixtures.revision())
            await repository.reject(Fixtures.revision())
            await repository.reject(Fixtures.revision(prompt: "missing", rev: 2))
            await repository.reject(Fixtures.revision(rev: 2, author: "missing"))
            await repository.reject(Fixtures.revision(rev: 2, owner: "missing"))
            await repository.reject(Fixtures.revision(rev: 2, scope: "group", owner: nil, group: "missing"))
            await repository.reject("UPDATE prompt_revisions SET rev = 1.5")
            await repository.reject("INSERT INTO prompts SELECT * FROM prompts")
            await repository.reject("INSERT OR REPLACE INTO prompts SELECT * FROM prompts")
            #expect(try await repository.count("prompt_revisions") == 1)
            try await repository.execute("DELETE FROM prompts")
            #expect(try await repository.count("prompt_revisions") == 0)
        }
    }

    @Test func changesOwnImmutablePayloadsAndHeadsSurvivePurge() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: Fixtures.prompt)
            try await repository.execute(Fixtures.revision())
            try await repository.execute(Fixtures.change())
            try await repository.execute("UPDATE prompts SET content = 'changed', path = 'Changed.md', path_key = 'changed.md', rev = 2")
            #expect(try await repository.string("SELECT content FROM changes", column: "content") == "original")
            #expect(try await repository.string("SELECT path FROM changes", column: "path") == "Example.md")
            await repository.reject("UPDATE changes SET content = 'changed'")
            await repository.reject("INSERT OR REPLACE INTO changes SELECT seq, scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, 'changed', at FROM changes")
            await repository.reject(Fixtures.change(kind: "unknown"))
            await repository.reject(Fixtures.change(kind: "delete"))
            await repository.reject(Fixtures.change(content: nil))
            await repository.reject(Fixtures.change(rev: 0))
            await repository.reject(Fixtures.change(owner: "missing", key: "user:missing"))
            await repository.reject(Fixtures.change(scope: "group", owner: nil, group: "missing", key: "group:missing"))
            await repository.reject(Fixtures.change(key: "group:\(Fixtures.group)"))
            await repository.reject("INSERT INTO changes SELECT * FROM changes")
            try await repository.execute(Fixtures.change(kind: "delete", rev: 3, content: nil))
            try await repository.execute(Fixtures.change(kind: "move_out", rev: 4, content: nil))
            try await repository.execute("INSERT INTO scope_floors VALUES (\(bind: "user:\(Fixtures.user)"), 4)")
            await repository.reject("INSERT INTO scope_floors SELECT * FROM scope_floors")
            await repository.reject("INSERT INTO scope_heads VALUES ('ghost', 100)")
            await repository.reject("UPDATE scope_heads SET head_seq = 100")
            await repository.reject("INSERT OR REPLACE INTO scope_heads VALUES (\(bind: "user:\(Fixtures.user)"), 100)")
            await repository.reject("UPDATE scope_floors SET floor_seq = 0")
            await repository.reject("UPDATE scope_floors SET floor_seq = 3")
            await repository.reject("UPDATE scope_floors SET floor_seq = 4.5")
            await repository.reject("UPDATE scope_floors SET floor_seq = 5")
            await repository.reject("INSERT OR REPLACE INTO scope_floors VALUES (\(bind: "user:\(Fixtures.user)"), 1)")
            await repository.reject("INSERT INTO scope_floors VALUES ('missing', 1)")
            try await repository.execute("INSERT INTO scope_heads VALUES ('empty', 0)")
            await repository.reject("INSERT INTO scope_floors VALUES ('empty', 2)")
            await repository.reject("UPDATE scope_heads SET head_seq = -1")
            await repository.reject("UPDATE scope_heads SET head_seq = 2")
            await repository.reject("UPDATE scope_heads SET head_seq = 3.5")
            await repository.reject("INSERT OR REPLACE INTO scope_heads VALUES (\(bind: "user:\(Fixtures.user)"), 0)")
            await repository.reject("INSERT INTO scope_heads SELECT * FROM scope_heads")
            await repository.reject("DELETE FROM scope_heads")
            await repository.reject("DELETE FROM scope_floors")
            try await repository.execute("DELETE FROM prompts")
            #expect(try await repository.count("changes") == 3)
            try await repository.execute("DELETE FROM changes")
            #expect(try await repository.string("SELECT head_seq FROM scope_heads WHERE scope_key = \(bind: "user:\(Fixtures.user)")", column: "head_seq") == "3")
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == "4")
            try await repository.execute(Fixtures.change(rev: 5))
            #expect(try await repository.string("SELECT seq FROM changes", column: "seq") == "4")
        }
    }

    @Test func retiredIdentitySurvivesTombstonePurge() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: Fixtures.prompt, deleted: Fixtures.time)
            await repository.reject(Fixtures.retired(owner: "missing"))
            await repository.reject(Fixtures.retired(scope: "group", owner: nil, group: "missing"))
            try await repository.execute(Fixtures.retired())
            await repository.reject(Fixtures.retired())
            await repository.reject("DELETE FROM retired_prompt_ids")
            await repository.reject("UPDATE retired_prompt_ids SET owner_id = \(bind: Fixtures.otherUser)")
            await repository.reject("INSERT OR REPLACE INTO retired_prompt_ids SELECT prompt_id, scope, \(bind: Fixtures.otherUser), group_id, retired_at FROM retired_prompt_ids")
            try await repository.execute("DELETE FROM prompts")
            #expect(try await repository.count("retired_prompt_ids") == 1)
            await #expect(throws: (any Error).self) { try await repository.insertPrompt(id: Fixtures.prompt) }
            try await repository.insertPrompt(id: "fresh-id")
            await repository.reject("UPDATE prompts SET id = \(bind: Fixtures.prompt) WHERE id = 'fresh-id'")
        }
    }

    @Test func independentLoginBucketsPersistWithoutRequiringAnAccount() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.execute("INSERT INTO login_account_buckets VALUES ('unknown', 5, \(bind: Fixtures.time), \(bind: Fixtures.time))")
            try await repository.execute("INSERT INTO login_ip_buckets VALUES ('127.0.0.1', 6, \(bind: Fixtures.time), \(bind: Fixtures.time))")
            for table in ["login_account_buckets", "login_ip_buckets"] {
                await repository.reject("INSERT INTO \(ident: table) SELECT * FROM \(ident: table)")
                await repository.reject("UPDATE \(ident: table) SET failures = -1")
                await repository.reject("UPDATE \(ident: table) SET failures = 1.5")
            }
            for username in ["", "Unknown", "é", "a\u{0}b", String(repeating: "a", count: 65)] {
                await repository.reject("UPDATE login_account_buckets SET username = \(bind: username)")
            }
            try await repository.execute("UPDATE login_account_buckets SET failures = 0, locked_until = NULL")
            #expect(try await repository.string("SELECT failures FROM login_ip_buckets", column: "failures") == "6")
        }
    }

    private static func assertPragmas(_ sql: any SQLDatabase) async throws {
        let mode = try #require(await sql.raw("PRAGMA journal_mode").first())
        #expect(try mode.decode(column: "journal_mode", as: String.self) == "wal")
        for (pragma, column, expected) in [("foreign_keys", "foreign_keys", 1), ("synchronous", "synchronous", 2),
                                          ("busy_timeout", "timeout", ServerLimits.databaseBusyTimeoutMilliseconds)] {
            let row = try #require(await sql.raw("PRAGMA \(unsafeRaw: pragma)").first())
            #expect(try row.decode(column: column, as: Int.self) == expected)
        }
    }
}
