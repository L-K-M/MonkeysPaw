import Crypto
import Foundation
import SQLKit

extension ServerMigration {
    static let snapshotCursors = ServerMigration(name: "004_snapshot_cursors") { sql in
        try await sql.raw("""
            CREATE TABLE snapshot_cursor_key (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                secret BLOB NOT NULL CHECK (typeof(secret) = 'blob' AND length(secret) = \(literal: ServerLimits.snapshotSigningKeyBytes))
            )
            """).run()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try await sql.raw("INSERT INTO snapshot_cursor_key VALUES (1, \(bind: key))").run()
        try await sql.raw("""
            CREATE INDEX prompts_snapshot_user ON prompts(owner_id, id)
            WHERE scope = 'user' AND deleted_at IS NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX prompts_snapshot_group ON prompts(group_id, id)
            WHERE scope = 'group' AND deleted_at IS NULL
            """).run()
    }
}
