import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

struct ServerGroupMigrationTests {
    @Test(arguments: [[ServerMigration.foundation], [.foundation, .nullableAccountMetadata]])
    func auditUpgradePreservesAccountEventsAndDatabaseIdentity(migrations: [ServerMigration]) async throws {
        try await withPersistenceDatabase(migrations: migrations) { repository in
            try await repository.seed()
            try await repository.execute("""
                INSERT INTO audit_events (id, actor_id, action, target, at)
                VALUES ('original', NULL, 'user.create', \(bind: PersistenceTestRepository.user), \(bind: PersistenceTestRepository.time))
                """)
            #expect(try await repository.count("schema_migrations") == migrations.count)
            let hasGroupColumn = try await repository.database.read { sql in
                try await sql.raw("PRAGMA table_info(audit_events)").all().contains {
                    try $0.decode(column: "name", as: String.self) == "group_id"
                }
            }
            #expect(!hasGroupColumn)
            let identity = try await MetaRepository(database: repository.database).databaseID()
            try await repository.database.migrate()
            try await repository.database.migrate()
            #expect(try await MetaRepository(database: repository.database).databaseID() == identity)
            #expect(try await repository.count("schema_migrations") == ServerMigration.current.count)
            let original = try #require(await repository.auditEvents().first)
            #expect(original.id == "original" && original.actorID == nil && original.groupID == nil)
            #expect(original.action == "user.create" && original.targetID == PersistenceTestRepository.user)
            #expect(original.at == PersistenceTestRepository.time)
            let date = try #require(ServerTimestamp.date(PersistenceTestRepository.time))
            let event = try AuditEvent(actor: .user(PersistenceTestRepository.user), action: .userUpdate,
                                       targetID: PersistenceTestRepository.otherUser, groupID: PersistenceTestRepository.group,
                                       at: date)
            try await AccountRepository(database: repository.database).writeAudited { _, _, audit in try await audit.insert(event) }
            #expect(try await repository.auditEvents().last?.groupID == PersistenceTestRepository.group)
            #expect(throws: AccountError.malformedRequest) {
                _ = try AuditEvent(actor: .cliOperator, action: .userUpdate, targetID: PersistenceTestRepository.user,
                                   groupID: "invalid", at: Date())
            }
            await repository.reject("UPDATE audit_events SET group_id = 'missing'")
        }
    }

    @Test func failedAuditUpgradeRollsBackColumnAndMarkerAndCanRetry() async throws {
        try await withPersistenceDatabase(migrations: [.foundation, .nullableAccountMetadata]) { repository in
            let failing = ServerMigration(name: ServerMigration.membershipAuditContext.name) { sql in
                try await ServerMigration.membershipAuditContext.prepare(sql)
                throw InjectedAuditError.failure
            }
            await #expect(throws: InjectedAuditError.failure) { try await repository.database.migrate([failing]) }
            #expect(try await repository.count("schema_migrations") == 2)
            let hasGroupColumn = try await repository.database.read { sql in
                try await sql.raw("PRAGMA table_info(audit_events)").all().contains {
                    try $0.decode(column: "name", as: String.self) == "group_id"
                }
            }
            #expect(!hasGroupColumn)
            try await repository.database.migrate()
            #expect(try await repository.count("schema_migrations") == ServerMigration.current.count)
        }
    }
}
