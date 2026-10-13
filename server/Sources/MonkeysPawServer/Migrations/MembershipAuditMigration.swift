import SQLKit

extension ServerMigration {
    /// A membership target is a user; retain the group as separate ID metadata.
    static let membershipAuditContext = ServerMigration(name: "003_membership_audit_context") { sql in
        try await sql.raw("ALTER TABLE audit_events ADD COLUMN group_id TEXT REFERENCES groups(id)").run()
    }
}
