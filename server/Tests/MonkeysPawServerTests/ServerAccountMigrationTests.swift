import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

struct ServerAccountMigrationTests {
    @Test func nullableDisplayNamesPreserveExistingIdentitiesAndReferences() async throws {
        try await withPersistenceDatabase(migrations: [.foundation]) { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt)
            try await repository.execute(PersistenceTestRepository.revision())
            try await repository.execute("""
                INSERT INTO devices (id, user_id, name, token_hash, created_at, last_seen_at, revoked_at)
                VALUES ('device', \(bind: PersistenceTestRepository.user),
                    'Device', 'hash', \(bind: PersistenceTestRepository.time), \(bind: PersistenceTestRepository.time), NULL)
                """)
            let identity = try await MetaRepository(database: repository.database).databaseID()
            let accounts = AccountRepository(database: repository.database)
            let original = try #require(await accounts.read { accounts, _ in try await accounts.user(id: PersistenceTestRepository.user) })
            try await repository.database.migrate()
            let migrated = try #require(await accounts.read { accounts, _ in try await accounts.user(id: PersistenceTestRepository.user) })
            #expect(migrated.metadata == original.metadata)
            let keepsHash = migrated.passwordHash == original.passwordHash
            #expect(keepsHash)
            #expect(try await repository.string("SELECT last_seen_at FROM devices", column: "last_seen_at") == PersistenceTestRepository.time)
            try await repository.execute("UPDATE users SET display_name = NULL")
            try await repository.execute("UPDATE devices SET last_seen_at = NULL")
            try await repository.database.migrate()
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            #expect(try await repository.count("users") == 2)
            #expect(try await repository.count("groups") == 2)
            #expect(try await repository.count("prompts") == 1)
            #expect(try await repository.count("prompt_revisions") == 1)
            #expect(try await repository.count("devices") == 1)
            let violations = try await repository.database.read { try await $0.raw("PRAGMA foreign_key_check").all().count }
            #expect(violations == 0)
        }
    }

    @Test func failedUpgradeRollsBackRebuiltTablesAndCanRetry() async throws {
        try await withPersistenceDatabase(migrations: [.foundation]) { repository in
            try await repository.seed()
            let failing = ServerMigration(name: ServerMigration.nullableAccountMetadata.name) { sql in
                try await ServerMigration.nullableAccountMetadata.prepare(sql)
                throw UpgradeFailure()
            }
            await #expect(throws: UpgradeFailure.self) { try await repository.database.migrate([failing]) }
            #expect(try await repository.count("schema_migrations") == 1)
            #expect(try await repository.count("users") == 2)
            #expect(try await repository.count("groups") == 2)
            await repository.reject("UPDATE users SET display_name = NULL")
            try await repository.database.migrate()
            try await repository.execute("UPDATE users SET display_name = NULL")
            #expect(try await repository.count("schema_migrations") == ServerMigration.current.count)
        }
    }
}

private struct UpgradeFailure: Error {}
