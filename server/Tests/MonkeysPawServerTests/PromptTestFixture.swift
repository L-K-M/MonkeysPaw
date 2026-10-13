import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

func promptContent(id: String = PersistenceTestRepository.prompt, metadata: String = "title: Example\n", body: String = "Original body\n") -> String {
    "---\nid: \(id)\n" + metadata + "---\n" + body
}

extension GroupTestFixture {
    var prompts: PromptService { .init(database: persistence.database, clock: account.clock.now) }
    var promptRepository: PromptRepository { .init(database: persistence.database) }

    func writePrompt(
        id: String = Self.livePrompt, baseRev: Int64 = 0, scope: SyncAPI.PromptScope = .user,
        path: String = "Example.md", content: String? = nil, origin: SyncAPI.WriteOrigin? = nil,
        session: SessionIdentity
    ) async throws -> SyncAPI.WriteResponse {
        try await prompts.put(id: id, request: .init(baseRev: baseRev, scope: scope, path: path,
                                                   content: content ?? promptContent(id: id), origin: origin), session: session)
    }

    /// Seed S12's deletion shape without exposing a delete endpoint in S11.
    func tombstonePrompt(id: String = Self.livePrompt, actorID: String) async throws {
        let at = ServerTimestamp.string(account.clock.now())
        try await persistence.database.write { sql in
            try await sql.raw("""
                INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id, path, content, created_at, origin)
                SELECT id, rev + 1, \(bind: actorID), scope, owner_id, group_id, path, content, \(bind: at), 'delete'
                FROM prompts WHERE id = \(bind: id)
                """).run()
            try await sql.raw("""
                INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
                SELECT CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END,
                       scope, owner_id, group_id, id, 'delete', path, rev + 1, NULL, \(bind: at)
                FROM prompts WHERE id = \(bind: id)
                """).run()
            try await sql.raw("""
                UPDATE prompts SET rev = rev + 1, updated_by = \(bind: actorID), updated_at = \(bind: at), deleted_at = \(bind: at)
                WHERE id = \(bind: id)
                """).run()
            try await sql.raw("""
                INSERT INTO retired_prompt_ids (prompt_id, scope, owner_id, group_id, retired_at)
                SELECT id, scope, owner_id, group_id, deleted_at FROM prompts WHERE id = \(bind: id)
                """).run()
        }
    }

    /// Historical moves are fixtures here; S12 owns transfer permission and events.
    func movePrompt(
        id: String = Self.livePrompt, identity: PromptOwnership, actorID: String,
        path: String = "Example.md", content: String? = nil
    ) async throws {
        let at = ServerTimestamp.string(account.clock.now())
        let checked = try SyncPathValidator.validate(path, scope: identity.scope == .user ? .user : .group)
        try await persistence.database.write { sql in
            try await sql.raw("""
                UPDATE prompts SET scope = \(bind: identity.scopeName), owner_id = \(bind: identity.ownerID),
                    group_id = \(bind: identity.groupID), path = \(bind: checked.path), path_key = \(bind: checked.pathKey),
                    content = COALESCE(\(bind: content), content), rev = rev + 1, updated_by = \(bind: actorID), updated_at = \(bind: at)
                WHERE id = \(bind: id)
                """).run()
            try await sql.raw("""
                INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id, path, content, created_at, origin)
                SELECT id, rev, \(bind: actorID), scope, owner_id, group_id, path, content, \(bind: at), 'move'
                FROM prompts WHERE id = \(bind: id)
                """).run()
        }
    }
}

enum PromptHTTPTest {
    static func headers(_ session: IssuedSession) -> HTTPFields {
        [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
    }

    static func success<T: Decodable>(_ response: TestResponse, as type: T.Type) throws -> T {
        #expect(response.status == .ok)
        return try JSONDecoder().decode(type, from: Data(response.body.readableBytesView))
    }

    static func error(_ response: TestResponse, _ expected: SyncAPI.ErrorResponse) throws {
        #expect(response.status.code == expected.httpStatus)
        let decoded = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
        #expect(decoded == expected)
    }
}

struct PromptStorageState: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let rows: [String: [String]]
    var description: String { "PromptStorageState(<redacted>)" }
    var debugDescription: String { description }
}

extension PersistenceTestRepository {
    func promptStorageState() async throws -> PromptStorageState {
        try await database.read { sql in
            let tables: [(String, [String])] = [
                ("prompts", ["id", "scope", "owner_id", "group_id", "path", "path_key", "content", "title", "rev",
                             "created_by", "created_at", "updated_by", "updated_at", "deleted_at"]),
                ("prompt_revisions", ["prompt_id", "rev", "author_id", "scope", "owner_id", "group_id", "path", "content", "created_at", "origin"]),
                ("changes", ["seq", "scope_key", "scope", "owner_id", "group_id", "prompt_id", "kind", "path", "rev", "content", "at"]),
                ("scope_heads", ["scope_key", "head_seq"]),
                ("retired_prompt_ids", ["prompt_id", "scope", "owner_id", "group_id", "retired_at"]),
                ("sqlite_sequence", ["name", "seq"])
            ]
            var rows: [String: [String]] = [:]
            for (table, columns) in tables {
                // Only fixture-owned column names enter this SQL expression.
                let projection = columns.map { "quote(\($0))" }.joined(separator: " || '|' || ")
                rows[table] = try await sql.raw("""
                    SELECT \(unsafeRaw: projection) AS state FROM \(ident: table) ORDER BY state
                    """).all().map { try $0.decode(column: "state", as: String.self) }
            }
            return .init(rows: rows)
        }
    }
}
