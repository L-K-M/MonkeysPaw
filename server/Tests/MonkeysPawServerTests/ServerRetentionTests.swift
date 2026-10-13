import Foundation
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerRetentionTests {
    @Test func oldChangesPurgeAndQuietScopesKeepHeadPlusOneFloor() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.execute(PersistenceTestRepository.change())
            try await repository.execute(PersistenceTestRepository.change())
            let now = try #require(ServerTimestamp.date(PersistenceTestRepository.time)).addingTimeInterval(91 * 24 * 60 * 60)
            let result = try await RetentionService(database: repository.database, clock: { now }).run()
            #expect(result.changes == 2 && result.floors == 1)
            #expect(try await repository.count("changes") == 0)
            #expect(try await repository.string("SELECT head_seq FROM scope_heads", column: "head_seq") == "2")
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == "3")
            #expect(try await RetentionService(database: repository.database, clock: { now }).run() == RetentionCounts())
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == "3")
        }
    }

    @Test func storedRevisionsKeepOnlyTheNewestTwoHundred() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt)
            try await repository.database.write { sql in
                for rev in 1...405 {
                    try await sql.raw(PersistenceTestRepository.revision(rev: rev)).run()
                }
                try await sql.raw("UPDATE prompts SET rev = 405").run()
            }
            let logs = CapturedServerLogs()
            let result = try await RetentionService(database: repository.database,
                logger: ServerLogging.makeLogger(level: .info, sink: logs.write)).run()
            #expect(result.revisions == 205)
            #expect(try await repository.count("prompt_revisions") == 200)
            #expect(try await repository.string("SELECT MIN(rev) AS rev FROM prompt_revisions", column: "rev") == "206")
            #expect(try await repository.string("SELECT MAX(rev) AS rev FROM prompt_revisions", column: "rev") == "405")
            #expect(try logs.events().map { $0.fields["revisions_pruned"] } == ["100", "100", "5"])
            #expect(try await repository.string("SELECT rev FROM prompts", column: "rev") == "405")
        }
    }

    @Test func floorFailureRollsBackAllPurgedRowsAndEarlierScopeRaises() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let user = "user:\(PersistenceTestRepository.user)"
            let group = "group:\(PersistenceTestRepository.group)"
            try await repository.execute(PersistenceTestRepository.change())
            try await repository.execute(PersistenceTestRepository.change(scope: "group", owner: nil,
                group: PersistenceTestRepository.group, key: group))
            for key in [user, group] { try await repository.execute("INSERT INTO scope_floors VALUES (\(bind: key), 1)") }
            let before = try await repository.promptStorageState()
            // Group sorts first; fail after its floor has been raised and both rows deleted.
            try await repository.execute("""
                CREATE TRIGGER retention_floor_failure AFTER UPDATE ON scope_floors
                WHEN NEW.scope_key = \(literal: user)
                BEGIN SELECT RAISE(ABORT, 'retention failure sentinel'); END
                """)
            let maintenance = RetentionRepository(database: repository.database)
            await #expect(throws: (any Error).self) { _ = try await maintenance.purgeChanges(before: "2027-01-12T00:00:00.000Z") }
            #expect(try await repository.promptStorageState() == before)
            #expect(try await repository.string("SELECT MIN(floor_seq) AS floor_seq FROM scope_floors", column: "floor_seq") == "1")
            #expect(try await repository.string("SELECT MAX(floor_seq) AS floor_seq FROM scope_floors", column: "floor_seq") == "1")
            try await repository.execute("DROP TRIGGER retention_floor_failure")
            let result = try await maintenance.purgeChanges(before: "2027-01-12T00:00:00.000Z")
            #expect(result.changes == 2 && result.floors == 2)
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors WHERE scope_key = \(bind: user)", column: "floor_seq") == "2")
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors WHERE scope_key = \(bind: group)", column: "floor_seq") == "3")
        }
    }

    @Test func changeBatchesStayBoundedAndNeverLowerAnExistingFloor() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let count = ServerLimits.retentionBatchSize * 2 + 5
            try await repository.database.write { sql in
                for _ in 0..<count { try await sql.raw(PersistenceTestRepository.change()).run() }
                try await sql.raw("INSERT INTO scope_floors VALUES (\(bind: "user:\(PersistenceTestRepository.user)"), \(bind: count + 1))").run()
            }
            let maintenance = RetentionRepository(database: repository.database)
            for expected in [100, 100, 5, 0] {
                let batch = try await maintenance.purgeChanges(before: "2027-01-12T00:00:00.000Z")
                #expect(batch.changes == expected && batch.floors == 0)
                #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == String(count + 1))
                #expect(try await repository.string("SELECT head_seq FROM scope_heads", column: "head_seq") == String(count))
            }
            #expect(try await repository.count("changes") == 0)
        }
    }

    @Test func cutoffIsStrictForBothFeedRowsAndTombstones() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            let cutoff = try #require(ServerTimestamp.date(PersistenceTestRepository.time))
            let older = ServerTimestamp.string(cutoff.addingTimeInterval(-1))
            let now = cutoff.addingTimeInterval(TimeInterval(ServerLimits.changeRetentionDays * 24 * 60 * 60))
            let key = "user:\(PersistenceTestRepository.user)"
            for at in [older, PersistenceTestRepository.time, ServerTimestamp.string(cutoff.addingTimeInterval(1))] {
                _ = try await repository.retentionChange(key: key, owner: PersistenceTestRepository.user, at: at)
            }
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt, path: "Old.md", deleted: older)
            try await repository.insertPrompt(id: GroupTestFixture.tombstone, path: "Boundary.md", deleted: PersistenceTestRepository.time)
            let result = try await RetentionService(database: repository.database, clock: { now }).run()
            #expect(result.changes == 1 && result.floors == 1 && result.tombstones == 1)
            #expect(try await repository.count("changes") == 2)
            #expect(try await repository.count("prompts") == 1)
            #expect(try await repository.string("SELECT id FROM prompts", column: "id") == GroupTestFixture.tombstone)
            #expect(try await repository.string("SELECT floor_seq FROM scope_floors", column: "floor_seq") == "2")
            #expect(try await repository.count("retired_prompt_ids") == 1)
        }
    }

    @Test func tombstoneHistoryDrainsBeforeItsHeadAndRetirementSurvives() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt, deleted: PersistenceTestRepository.time)
            try await repository.database.write { sql in
                for rev in 1...205 { try await sql.raw(PersistenceTestRepository.revision(rev: rev)).run() }
                try await sql.raw("UPDATE prompts SET rev = 205").run()
            }
            let maintenance = RetentionRepository(database: repository.database)
            for (revisions, tombstones) in [(100, 0), (100, 0), (5, 1)] {
                let batch = try await maintenance.purgeTombstone(before: "2027-01-12T00:00:00.000Z")
                #expect(batch.revisions == revisions && batch.tombstones == tombstones)
                #expect(try await repository.count("retired_prompt_ids") == 1)
                #expect(try await repository.count("prompts") == 1 - tombstones)
            }
            #expect(try await repository.count("prompt_revisions") == 0)
            await repository.reject("""
                INSERT INTO prompts (id, scope, owner_id, path, path_key, content, title, rev, created_by, created_at, updated_by, updated_at)
                VALUES (\(bind: PersistenceTestRepository.prompt), 'user', \(bind: PersistenceTestRepository.user),
                    'Revived.md', 'revived.md', 'revived', 'Fixture', 1, \(bind: PersistenceTestRepository.user),
                    \(bind: PersistenceTestRepository.time), \(bind: PersistenceTestRepository.user), \(bind: PersistenceTestRepository.time))
                """)
        }
    }

    @Test func tombstoneFailureRollsBackHistoryHeadAndRetirementTogether() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt, deleted: PersistenceTestRepository.time)
            try await repository.execute(PersistenceTestRepository.revision())
            let before = try await repository.promptStorageState()
            try await repository.execute("""
                CREATE TRIGGER retention_head_failure BEFORE DELETE ON prompts
                BEGIN SELECT RAISE(ABORT, 'retention failure sentinel'); END
                """)
            let maintenance = RetentionRepository(database: repository.database)
            await #expect(throws: (any Error).self) { _ = try await maintenance.purgeTombstone(before: "2027-01-12T00:00:00.000Z") }
            #expect(try await repository.promptStorageState() == before)
            try await repository.execute("DROP TRIGGER retention_head_failure")
            #expect(try await maintenance.purgeTombstone(before: "2027-01-12T00:00:00.000Z") == RetentionCounts(tombstones: 1, revisions: 1))
        }
    }

    @Test func revisionCapUsesStoredRowsRatherThanSubtractingFromTheHead() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.insertPrompt(id: PersistenceTestRepository.prompt)
            try await repository.database.write { sql in
                for rev in Array(1...105) + Array(400...499) {
                    try await sql.raw(PersistenceTestRepository.revision(rev: rev)).run()
                }
                try await sql.raw("UPDATE prompts SET rev = 499").run()
            }
            #expect(try await RetentionService(database: repository.database).run().revisions == 5)
            #expect(try await repository.count("prompt_revisions") == 200)
            #expect(try await repository.string("SELECT MIN(rev) AS rev FROM prompt_revisions", column: "rev") == "6")
            #expect(try await repository.string("SELECT MAX(rev) AS rev FROM prompt_revisions", column: "rev") == "499")
        }
    }
}

extension PersistenceTestRepository {
    func retentionChange(key: String, owner: String, at: String) async throws -> Int64 {
        try await database.write { sql in
            let row = try #require(await sql.raw("""
                INSERT INTO changes (scope_key, scope, owner_id, prompt_id, kind, path, rev, content, at)
                VALUES (\(bind: key), 'user', \(bind: owner), \(bind: Self.prompt), 'upsert', 'Example.md', 1, 'old payload', \(bind: at))
                RETURNING seq
                """).first())
            return try row.decode(column: "seq", as: Int64.self)
        }
    }
}
