import SQLKit

extension ServerMigration {
    static let retentionIndexes = ServerMigration(name: "005_retention_indexes") { sql in
        try await sql.raw("CREATE INDEX changes_retention ON changes(at, seq)").run()
        try await sql.raw("""
            CREATE INDEX prompts_retention_tombstones ON prompts(deleted_at, id) WHERE deleted_at IS NOT NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX prompts_retention_revisions ON prompts(id) WHERE rev > \(literal: ServerLimits.revisionsPerPrompt)
            """).run()
    }
}
