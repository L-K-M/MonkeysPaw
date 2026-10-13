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
            let result = try await RetentionService(database: repository.database).run()
            #expect(result.revisions == 205)
            #expect(try await repository.count("prompt_revisions") == 200)
            #expect(try await repository.string("SELECT MIN(rev) AS rev FROM prompt_revisions", column: "rev") == "206")
            #expect(try await repository.string("SELECT MAX(rev) AS rev FROM prompt_revisions", column: "rev") == "405")
        }
    }
}
