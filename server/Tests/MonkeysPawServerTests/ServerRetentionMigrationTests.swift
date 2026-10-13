import SQLKit
import Testing
@testable import MonkeysPawServer

struct ServerRetentionMigrationTests {
    private static let previous: [ServerMigration] = [.foundation, .nullableAccountMetadata, .membershipAuditContext, .snapshotCursors]
    private static let indexes = ["changes_retention", "prompts_retention_tombstones", "prompts_retention_revisions"]

    @Test func indexUpgradePreservesExistingDataAndUsesBoundedScans() async throws {
        try await withPersistenceDatabase(migrations: Self.previous) { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt)
            try await repository.execute(PersistenceTestRepository.revision())
            try await repository.execute(PersistenceTestRepository.change())
            try await repository.execute(PersistenceTestRepository.retired(prompt: GroupTestFixture.retiredTombstone))
            try await repository.execute("INSERT INTO scope_floors VALUES (\(bind: "user:\(PersistenceTestRepository.user)"), 1)")
            try await repository.execute("""
                INSERT INTO snapshots SELECT database_id, scope_key, head_seq, X'01',
                    \(bind: PersistenceTestRepository.time), '2026-10-12T00:15:00.000Z'
                FROM meta JOIN scope_heads
                """)
            let identity = try await MetaRepository(database: repository.database).databaseID()
            let before = try await repository.promptStorageState()
            let key = try await repository.string("SELECT hex(secret) AS bytes FROM snapshot_cursor_key", column: "bytes")
            try await repository.database.migrate()
            try await repository.database.migrate()
            #expect(try await repository.count("schema_migrations") == 5)
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            #expect(try await repository.promptStorageState() == before)
            #expect(try await repository.string("SELECT hex(secret) AS bytes FROM snapshot_cursor_key", column: "bytes") == key)
            #expect(try await repository.string("SELECT hex(manifest) AS bytes FROM snapshots", column: "bytes") == "01")
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == "1")
            let plans: [SQLQueryString] = [
                "EXPLAIN QUERY PLAN SELECT seq FROM changes WHERE at < '2027-01-12T00:00:00.000Z' ORDER BY at, seq LIMIT 100",
                "EXPLAIN QUERY PLAN SELECT id FROM prompts WHERE deleted_at < '2027-01-12T00:00:00.000Z' ORDER BY deleted_at, id LIMIT 1",
                "EXPLAIN QUERY PLAN SELECT id FROM prompts WHERE rev > 200 AND id > '' ORDER BY id LIMIT 100"
            ]
            for (query, index) in zip(plans, Self.indexes) {
                let plan = try await repository.string(query, column: "detail")
                #expect(plan.contains(index))
            }
        }
    }

    @Test func failedIndexUpgradeRollsBackDDLAndMarkerAndCanRetry() async throws {
        try await withPersistenceDatabase(migrations: Self.previous) { repository in
            let failure = ServerMigration(name: ServerMigration.retentionIndexes.name) { sql in
                try await ServerMigration.retentionIndexes.prepare(sql)
                throw RetentionMigrationFailure()
            }
            await #expect(throws: RetentionMigrationFailure.self) { try await repository.database.migrate([failure]) }
            #expect(try await repository.count("schema_migrations") == 4)
            for name in Self.indexes {
                #expect(try await repository.database.read { try await $0.raw("SELECT name FROM sqlite_master WHERE name = \(bind: name)").first() == nil })
            }
            try await repository.database.migrate()
            #expect(try await repository.count("schema_migrations") == 5)
        }
    }
}

private struct RetentionMigrationFailure: Error {}
