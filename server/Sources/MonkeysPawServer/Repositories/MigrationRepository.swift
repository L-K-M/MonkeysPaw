import Foundation
import SQLKit

struct MigrationRepository: Sendable {
    let database: ServerDatabase

    func apply(_ migrations: [ServerMigration]) async throws {
        for migration in migrations {
            try await database.write { sql in
                try await sql.raw("""
                    CREATE TABLE IF NOT EXISTS schema_migrations (
                        name TEXT PRIMARY KEY NOT NULL,
                        applied_at TEXT NOT NULL
                    )
                    """).run()
                guard try await sql.raw("SELECT name FROM schema_migrations WHERE name = \(bind: migration.name)").first() == nil else {
                    return
                }

                try await migration.prepare(sql)
                try await sql.raw("""
                    INSERT INTO schema_migrations (name, applied_at)
                    VALUES (\(bind: migration.name), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                    """).run()
            }
        }
    }
}
