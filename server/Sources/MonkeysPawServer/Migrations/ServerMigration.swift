import Foundation
import SQLKit

struct ServerMigration: Sendable {
    let name: String
    let prepare: @Sendable (any SQLDatabase) async throws -> Void

    static let current: [ServerMigration] = [.foundation, .nullableAccountMetadata, .membershipAuditContext]

    static let foundation = ServerMigration(name: "001_persistence_foundation") { sql in
        for statement in FoundationSchema.statements {
            try await sql.raw(statement).run()
        }
        try await sql.raw("INSERT INTO meta (singleton, database_id) VALUES (1, \(bind: UUID().uuidString))").run()
    }
}
