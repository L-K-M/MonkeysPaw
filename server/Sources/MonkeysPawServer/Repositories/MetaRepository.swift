import Foundation
import SQLKit

struct MetaRepository: Sendable {
    let database: ServerDatabase

    func databaseID() async throws -> UUID {
        try await database.read { sql in
            guard let row = try await sql.raw("SELECT database_id FROM meta WHERE singleton = 1").first(),
                  let id = try UUID(uuidString: row.decode(column: "database_id", as: String.self)) else {
                throw PersistenceError.missingDatabaseID
            }
            return id
        }
    }
}
