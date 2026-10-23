import SQLKit

extension ServerMigration {
    /// §26 S1: one encrypted provider-settings document per account. The server
    /// stores opaque ciphertext and enforces only the wire bound.
    static let providerSettings = ServerMigration(name: "006_provider_settings") { sql in
        try await sql.raw("""
            CREATE TABLE provider_settings (
                user_id TEXT PRIMARY KEY NOT NULL REFERENCES users(id),
                rev INTEGER NOT NULL CHECK (rev >= 1),
                document TEXT NOT NULL CHECK (
                    length(document) >= 1 AND length(document) <= 349600
                    AND document NOT GLOB '*[^A-Za-z0-9_-]*'),
                updated_at TEXT NOT NULL
            )
            """).run()
    }
}
