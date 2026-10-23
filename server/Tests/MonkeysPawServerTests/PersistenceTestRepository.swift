import FluentSQLiteDriver
import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

/// Fixtures keep SQL at the repository boundary, just like production callers.
struct PersistenceTestRepository: Sendable {
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let otherUser = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let group = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    static let otherGroup = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let prompt = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    static let time = "2026-10-12T00:00:00.000Z"
    let database: ServerDatabase

    func seed() async throws {
        try await database.write { sql in
            for (id, username) in [(Self.user, "alice"), (Self.otherUser, "bob")] {
                try await sql.raw("""
                    INSERT INTO users (id, username, display_name, password_hash, account_kind, created_at)
                    VALUES (\(bind: id), \(bind: username), 'Fixture', 'fixture-hash', 'member', \(bind: Self.time))
                    """).run()
            }
            for id in [Self.group, Self.otherGroup] {
                try await sql.raw("""
                    INSERT INTO groups (id, name, created_by, created_at)
                    VALUES (\(bind: id), 'Fixture group', \(bind: Self.user), \(bind: Self.time))
                    """).run()
            }
        }
    }

    func execute(_ query: SQLQueryString) async throws {
        try await database.write { try await $0.raw(query).run() }
    }

    func count(_ table: String) async throws -> Int {
        try await database.read { sql in
            let row = try #require(await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            return try row.decode(column: "count", as: Int.self)
        }
    }

    func string(_ query: SQLQueryString, column: String) async throws -> String {
        try await database.read { sql in
            let row = try #require(await sql.raw(query).first())
            return try row.decode(column: column, as: String.self)
        }
    }

    func reject(_ query: SQLQueryString, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await execute(query)
            Issue.record("Expected a database constraint failure", sourceLocation: sourceLocation)
        } catch {
            #expect((error as? any DatabaseError)?.isConstraintFailure == true, sourceLocation: sourceLocation)
        }
    }

    func insertPrompt(
        id: String, path: String = "Example.md", scope: SyncPathValidator.Scope = .user,
        owner: String? = Self.user, group: String? = nil, deleted: String? = nil
    ) async throws {
        let checkedPath = try SyncPathValidator.validate(path, scope: scope)
        try await execute("""
            INSERT INTO prompts (id, scope, owner_id, group_id, path, path_key, content, title,
                                 rev, created_by, created_at, updated_by, updated_at, deleted_at)
            VALUES (\(bind: id), \(bind: scope.rawValue), \(bind: owner), \(bind: group),
                    \(bind: checkedPath.path), \(bind: checkedPath.pathKey), 'original', 'Fixture',
                    1, \(bind: Self.user), \(bind: Self.time), \(bind: Self.user), \(bind: Self.time), \(bind: deleted))
            """)
    }

    static func change(
        scope: String = "user", owner: String? = Self.user, group: String? = nil,
        key: String = "user:\(Self.user)", kind: String = "upsert", rev: Int = 1,
        content: String? = "original"
    ) -> SQLQueryString {
        """
        INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
        VALUES (\(bind: key), \(bind: scope), \(bind: owner), \(bind: group), \(bind: Self.prompt),
                \(bind: kind), 'Example.md', \(bind: rev), \(bind: content), \(bind: Self.time))
        """
    }

    static func revision(
        prompt: String = Self.prompt, rev: Int = 1, author: String = Self.user,
        scope: String = "user", owner: String? = Self.user, group: String? = nil
    ) -> SQLQueryString {
        """
        INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id, path, content, created_at, origin)
        VALUES (\(bind: prompt), \(bind: rev), \(bind: author), \(bind: scope), \(bind: owner), \(bind: group),
                'Example.md', 'original', \(bind: Self.time), 'manual')
        """
    }

    static func retired(
        prompt: String = Self.prompt, scope: String = "user", owner: String? = Self.user, group: String? = nil
    ) -> SQLQueryString {
        """
        INSERT INTO retired_prompt_ids (prompt_id, scope, owner_id, group_id, retired_at)
        VALUES (\(bind: prompt), \(bind: scope), \(bind: owner), \(bind: group), \(bind: Self.time))
        """
    }
}

func withPersistenceDatabase(
    migrations: [ServerMigration] = ServerMigration.current,
    _ operation: @Sendable (PersistenceTestRepository) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s5-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
    let database = try await ServerDatabase.open(configuration: configuration)
    do {
        try await database.migrate(migrations)
        try await operation(PersistenceTestRepository(database: database))
        await database.shutdown()
    } catch {
        await database.shutdown()
        throw error
    }
}
