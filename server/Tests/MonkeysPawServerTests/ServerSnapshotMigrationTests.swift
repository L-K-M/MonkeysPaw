import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

struct ServerSnapshotMigrationTests {
    @Test func upgradePreservesIdentityDataAndDurableHeadsAndKeepsItsKey() async throws {
        try await withPersistenceDatabase(migrations: [.foundation, .nullableAccountMetadata, .membershipAuditContext]) { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt)
            try await repository.execute(PersistenceTestRepository.change())
            let key = "user:\(PersistenceTestRepository.user)"
            try await repository.execute("INSERT INTO scope_floors VALUES (\(bind: key), 2)")
            let identity = try await MetaRepository(database: repository.database).databaseID()
            try await repository.database.migrate()
            let before = try await repository.database.read { sql in
                let row = try #require(await sql.raw("SELECT secret FROM snapshot_cursor_key").first())
                return try row.decode(column: "secret", as: Data.self)
            }
            try await repository.database.migrate()
            let after = try await repository.database.read { sql in
                let row = try #require(await sql.raw("SELECT secret FROM snapshot_cursor_key").first())
                return try row.decode(column: "secret", as: Data.self)
            }
            let preserved = before == after
            #expect(preserved)
            #expect(before.count == ServerLimits.snapshotSigningKeyBytes)
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            #expect(try await repository.count("prompts") == 1)
            #expect(try await repository.count("schema_migrations") == 4)
            #expect(try await repository.string("SELECT CAST(head_seq AS TEXT) AS head_seq FROM scope_heads", column: "head_seq") == "1")
            #expect(try await repository.string("SELECT CAST(floor_seq AS TEXT) AS floor_seq FROM scope_floors", column: "floor_seq") == "2")
        }
    }

    @Test func failedUpgradeRollsBackKeyIndexesAndMarkerBeforeRetry() async throws {
        try await withPersistenceDatabase(migrations: [.foundation, .nullableAccountMetadata, .membershipAuditContext]) { repository in
            let failing = ServerMigration(name: ServerMigration.snapshotCursors.name) { sql in
                try await ServerMigration.snapshotCursors.prepare(sql)
                throw SnapshotMigrationFailure()
            }
            await #expect(throws: SnapshotMigrationFailure.self) { try await repository.database.migrate([failing]) }
            let missing = try await repository.database.read { sql in
                try await sql.raw("SELECT name FROM sqlite_master WHERE name IN ('snapshot_cursor_key', 'prompts_snapshot_user', 'prompts_snapshot_group')").all().isEmpty
            }
            #expect(missing)
            #expect(try await repository.count("schema_migrations") == 3)
            try await repository.database.migrate()
            #expect(try await repository.count("snapshot_cursor_key") == 1)
            #expect(try await repository.count("schema_migrations") == 4)
        }
    }
}

private struct SnapshotMigrationFailure: Error {}
