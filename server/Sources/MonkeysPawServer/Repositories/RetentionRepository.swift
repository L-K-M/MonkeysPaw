import SQLKit

struct RetentionRepository: Sendable {
    private let database: ServerDatabase

    init(database: ServerDatabase) { self.database = database }

    func purgeChanges(before cutoff: String) async throws -> RetentionCounts {
        try await database.write { sql in
            let rows = try await sql.raw("""
                DELETE FROM changes WHERE seq IN (
                    SELECT seq FROM changes WHERE at < \(bind: cutoff)
                    ORDER BY at, seq LIMIT \(literal: ServerLimits.retentionBatchSize)
                ) RETURNING scope_key, seq
                """).all()
            var highest: [String: Int64] = [:]
            for row in rows {
                let key = try row.decode(column: "scope_key", as: String.self)
                highest[key] = max(highest[key] ?? 0, try row.decode(column: "seq", as: Int64.self))
            }

            var floors = 0
            for (key, seq) in highest.sorted(by: { $0.key < $1.key }) {
                // A quiet scope still has its durable head after its last event is gone.
                floors += try await sql.raw("""
                    INSERT INTO scope_floors (scope_key, floor_seq)
                    SELECT scope_key, CASE WHEN EXISTS (SELECT 1 FROM changes WHERE scope_key = \(bind: key))
                        THEN \(bind: seq) + 1 ELSE head_seq + 1 END
                    FROM scope_heads WHERE scope_key = \(bind: key)
                    ON CONFLICT (scope_key) DO UPDATE SET floor_seq = excluded.floor_seq
                        WHERE excluded.floor_seq > scope_floors.floor_seq
                    RETURNING scope_key
                    """).all().count
            }
            return RetentionCounts(changes: rows.count, floors: floors)
        }
    }

    func purgeTombstone(before cutoff: String) async throws -> RetentionCounts {
        try await database.write { sql in
            guard let row = try await sql.raw("""
                SELECT id FROM prompts WHERE deleted_at < \(bind: cutoff)
                ORDER BY deleted_at, id LIMIT 1
                """).first() else { return RetentionCounts() }
            let id = try row.decode(column: "id", as: String.self)
            try await sql.raw("""
                INSERT INTO retired_prompt_ids (prompt_id, scope, owner_id, group_id, retired_at)
                SELECT id, scope, owner_id, group_id, deleted_at FROM prompts WHERE id = \(bind: id)
                    AND NOT EXISTS (SELECT 1 FROM retired_prompt_ids WHERE prompt_id = \(bind: id))
                """).run()
            let revisions = try await sql.raw("""
                DELETE FROM prompt_revisions WHERE prompt_id = \(bind: id) AND rev IN (
                    SELECT rev FROM prompt_revisions WHERE prompt_id = \(bind: id)
                    ORDER BY rev LIMIT \(literal: ServerLimits.retentionBatchSize)
                ) RETURNING rev
                """).all().count
            // Drain history first so ON DELETE CASCADE cannot do unbounded writer work.
            let tombstones = try await sql.raw("""
                DELETE FROM prompts WHERE id = \(bind: id)
                    AND NOT EXISTS (SELECT 1 FROM prompt_revisions WHERE prompt_id = \(bind: id))
                RETURNING id
                """).all().count
            return RetentionCounts(tombstones: tombstones, revisions: revisions)
        }
    }

    func revisionPromptIDs(after id: String) async throws -> [String] {
        try await database.read { sql in
            try await sql.raw("""
                SELECT id FROM prompts WHERE rev > \(literal: ServerLimits.revisionsPerPrompt) AND id > \(bind: id)
                ORDER BY id LIMIT \(literal: ServerLimits.retentionBatchSize)
                """).all().map { try $0.decode(column: "id", as: String.self) }
        }
    }

    func pruneRevisions(id: String) async throws -> RetentionCounts {
        try await database.write { sql in
            // The actual 200th newest row handles gaps left by earlier maintenance.
            let revisions = try await sql.raw("""
                DELETE FROM prompt_revisions WHERE prompt_id = \(bind: id) AND rev IN (
                    SELECT rev FROM prompt_revisions WHERE prompt_id = \(bind: id) AND rev < (
                        SELECT rev FROM prompt_revisions WHERE prompt_id = \(bind: id)
                        ORDER BY rev DESC LIMIT 1 OFFSET \(literal: ServerLimits.revisionsPerPrompt - 1)
                    ) ORDER BY rev LIMIT \(literal: ServerLimits.retentionBatchSize)
                ) RETURNING rev
                """).all().count
            return RetentionCounts(revisions: revisions)
        }
    }
}
