import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

struct ServerSnapshotRestoreTests {
    @Test func reopeningKeepsTheManifestAndAuthenticatesItsContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s14-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let state = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let fixture = GroupTestFixture(account: .init(persistence: .init(database: database)))
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let prompts = try await fixture.seedSnapshot(identity: .user(ownerID: user.id), author: user, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            return (clock: fixture.account.clock, session: session.identity, first: first, prompts: prompts)
        }
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let feed = SyncFeedService(database: database, clock: state.clock.now)
            let response = try await feed.pull(request: state.first.continuation, session: state.session)
            #expect(response.databaseID == state.first.databaseID)
            #expect(response.scopes[0].mode == .snapshot && !response.scopes[0].hasMore)
            #expect(response.scopes[0].cursor == String(state.first.scopes[0].head))
            #expect(response.scopes[0].items == [.upsert(seq: state.first.scopes[0].head, prompt: state.prompts[200])])
        }
    }

    @Test func restoringAnOlderDatabaseResnapshotsLowerRevisionsAndHeadsWithoutClearingFloors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s14-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let backup = directory.appendingPathComponent("offline-backup.db")
        let state = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let fixture = GroupTestFixture(account: .init(persistence: .init(database: database)))
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            _ = try await fixture.writePrompt(session: session.identity)
            let key = "user:\(user.id)"
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            try await database.write { sql in
                try await sql.raw("DELETE FROM changes").run()
                try await sql.raw("INSERT INTO scope_floors VALUES (\(bind: key), 2)").run()
            }
            return (clock: fixture.account.clock, session: session.identity, first: first, key: key)
        }
        // Copy only after shutdown; this fixture never copies a live WAL database.
        try FileManager.default.copyItem(atPath: configuration.databasePath, toPath: backup.path)
        let newer = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let prompts = PromptService(database: database, clock: state.clock.now)
            let id = GroupTestFixture.livePrompt
            _ = try await prompts.put(id: id, request: .init(baseRev: 1, scope: .user, path: "Example.md",
                                                            content: promptContent(id: id, body: "Newer revision\n")), session: state.session)
            return try await SyncFeedService(database: database, clock: state.clock.now)
                .pull(request: .init(databaseID: nil, cursors: [:]), session: state.session)
        }
        #expect(newer.scopes[0].head == 2)
        // Both database instances are closed before replacing the fixture database.
        for suffix in ["", "-wal", "-shm"] {
            let path = configuration.databasePath + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        try FileManager.default.copyItem(atPath: backup.path, toPath: configuration.databasePath)
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let identity = UUID().uuidString
            try await database.write { sql in
                try await sql.raw("DELETE FROM snapshots").run()
                try await sql.raw("UPDATE meta SET database_id = \(bind: identity)").run()
            }
            let feed = SyncFeedService(database: database, clock: state.clock.now)
            let restored = try await feed.pull(request: newer.continuation, session: state.session)
            #expect(restored.databaseID == identity.lowercased() && restored.databaseID != newer.databaseID)
            #expect(restored.scopes == state.first.scopes)
            // Above-head alone also triggers a snapshot, even with the new UUID.
            let aboveHead = SyncAPI.PullRequest(databaseID: restored.databaseID, cursors: [state.key: "2"])
            #expect(try await feed.pull(request: aboveHead, session: state.session).scopes == state.first.scopes)
            let current = try await feed.pull(request: restored.continuation, session: state.session)
            #expect(current.scopes[0].mode == .delta && current.scopes[0].head == 1 && current.scopes[0].items.isEmpty)
            let persistence = PersistenceTestRepository(database: database)
            #expect(try await persistence.string("SELECT CAST(floor_seq AS TEXT) AS floor FROM scope_floors", column: "floor") == "2")
        }
    }
}
