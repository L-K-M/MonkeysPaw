import SQLKit

extension ServerMigration {
    /// S1 distinguishes an absent display name from an explicitly empty name.
    static let nullableAccountMetadata = ServerMigration(name: "002_nullable_account_metadata") { sql in
        // Defer references while rebuilding the parent, then verify before commit.
        // No user identity or referenced row is deleted from the resulting database.
        try await sql.raw("PRAGMA defer_foreign_keys = ON").run()
        try await sql.raw("CREATE TEMP TABLE account_metadata_copy AS SELECT * FROM users").run()
        try await sql.raw("DROP TABLE users").run()
        try await sql.raw("""
            CREATE TABLE users (
                id TEXT PRIMARY KEY NOT NULL,
                username TEXT NOT NULL UNIQUE CHECK (
                    length(CAST(username AS BLOB)) BETWEEN 1 AND \(literal: ServerLimits.usernameMaxBytes)
                    AND instr(username, char(0)) = 0 AND username NOT GLOB '*[^a-z0-9_.-]*'),
                display_name TEXT,
                password_hash TEXT NOT NULL,
                account_kind TEXT NOT NULL CHECK (account_kind IN ('member', 'admin')),
                created_at TEXT NOT NULL,
                disabled_at TEXT
            )
            """).run()
        try await sql.raw("INSERT INTO users SELECT * FROM account_metadata_copy").run()
        try await sql.raw("DROP TABLE account_metadata_copy").run()
        try await sql.raw("CREATE TEMP TABLE device_metadata_copy AS SELECT * FROM devices").run()
        try await sql.raw("DROP TABLE devices").run()
        try await sql.raw("""
            CREATE TABLE devices (
                id TEXT PRIMARY KEY NOT NULL,
                user_id TEXT NOT NULL REFERENCES users(id),
                name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                last_seen_at TEXT,
                revoked_at TEXT
            )
            """).run()
        try await sql.raw("INSERT INTO devices SELECT * FROM device_metadata_copy").run()
        try await sql.raw("DROP TABLE device_metadata_copy").run()
        guard try await sql.raw("PRAGMA foreign_key_check").all().isEmpty else {
            throw PersistenceError.invalidAccountRecord
        }
    }
}
