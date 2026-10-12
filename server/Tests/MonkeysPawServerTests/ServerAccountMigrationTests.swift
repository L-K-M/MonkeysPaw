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
                INSERT INTO devices VALUES ('device', \(bind: PersistenceTestRepository.user),
                    'Device', 'hash', \(bind: PersistenceTestRepository.time), \(bind: PersistenceTestRepository.time), NULL)
                """)
            let identity = try await MetaRepository(database: repository.database).databaseID()
            try await repository.database.migrate()
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
}
