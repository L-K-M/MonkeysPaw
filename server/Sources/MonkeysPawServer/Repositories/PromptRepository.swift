import MonkeysPawCore
import SQLKit

/// Unlike the wire scope, a private identity names its actual owner.
enum PromptOwnership: Sendable, Equatable {
    case user(ownerID: String)
    case group(groupID: String)

    init(scope: SyncAPI.PromptScope, userID: String) {
        switch scope {
        case .user: self = .user(ownerID: userID)
        case .group(let id): self = .group(groupID: id)
        }
    }

    fileprivate init(row: any SQLRow) throws {
        let owner = try row.decode(column: "owner_id", as: String?.self)
        let group = try row.decode(column: "group_id", as: String?.self)
        switch try row.decode(column: "scope", as: String.self) {
        case "user" where group == nil:
            guard let owner else { throw PromptPersistenceError.invalidRecord }
            self = .user(ownerID: owner)
        case "group" where owner == nil:
            guard let group else { throw PromptPersistenceError.invalidRecord }
            self = .group(groupID: group)
        default: throw PromptPersistenceError.invalidRecord
        }
    }

    var scope: SyncAPI.PromptScope {
        switch self {
        case .user: return .user
        case .group(let id): return .group(groupID: id)
        }
    }
    var scopeName: String {
        switch self {
        case .user: return "user"
        case .group: return "group"
        }
    }
    var ownerID: String? {
        if case .user(let id) = self { return id }
        return nil
    }
    var groupID: String? {
        if case .group(let id) = self { return id }
        return nil
    }
    var key: String {
        switch self {
        case .user(let id): return "user:\(id)"
        case .group(let id): return "group:\(id)"
        }
    }
}

struct PromptRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let identity: PromptOwnership
    let path: String
    let pathKey: String
    let content: String
    let title: String
    let rev: Int64
    let createdBy: String
    let createdAt: String
    let updatedBy: String
    let updatedAt: String
    let deletedAt: String?

    var description: String { "PromptRecord(<redacted>)" }
    var debugDescription: String { description }
    var prompt: SyncAPI.Prompt { .init(id: id, rev: rev, scope: identity.scope, path: path, content: content) }
    var conflictHead: SyncAPI.ConflictHead { .init(rev: rev, scope: identity.scope, path: path, content: content) }
    var existing: SyncAPI.ExistingPrompt { .init(id: id, rev: rev, content: content) }
}

private extension PromptRecord {
    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: String.self)
        identity = try PromptOwnership(row: row)
        path = try row.decode(column: "path", as: String.self)
        pathKey = try row.decode(column: "path_key", as: String.self)
        content = try row.decode(column: "content", as: String.self)
        title = try row.decode(column: "title", as: String.self)
        rev = try row.decode(column: "rev", as: Int64.self)
        createdBy = try row.decode(column: "created_by", as: String.self)
        createdAt = try row.decode(column: "created_at", as: String.self)
        updatedBy = try row.decode(column: "updated_by", as: String.self)
        updatedAt = try row.decode(column: "updated_at", as: String.self)
        deletedAt = try row.decode(column: "deleted_at", as: String?.self)
    }
}

struct PromptRepository: Sendable {
    let database: ServerDatabase

    func read<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository, GroupRepository.Transaction) async throws -> T
    ) async throws -> T {
        try await database.read {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0),
                                DeviceRepository(sql: $0), GroupRepository.Transaction(sql: $0))
        }
    }

    func write<T: Sendable>(
        _ operation: @escaping @Sendable (Transaction, AccountRepository.Transaction, DeviceRepository, GroupRepository.Transaction) async throws -> T
    ) async throws -> T {
        try await database.write {
            try await operation(Transaction(sql: $0), AccountRepository.Transaction(sql: $0),
                                DeviceRepository(sql: $0), GroupRepository.Transaction(sql: $0))
        }
    }

    struct Transaction: Sendable {
        private let sql: any SQLDatabase

        init(sql: any SQLDatabase) { self.sql = sql }

        func head(id: String) async throws -> PromptRecord? {
            try await sql.raw("""
                SELECT id, scope, owner_id, group_id, path, path_key, content, title, rev,
                       created_by, created_at, updated_by, updated_at, deleted_at
                FROM prompts WHERE id = \(bind: id)
                """).first().map(PromptRecord.init(row:))
        }

        func retiredIdentity(id: String) async throws -> PromptOwnership? {
            try await sql.raw("""
                SELECT scope, owner_id, group_id FROM retired_prompt_ids WHERE prompt_id = \(bind: id)
                """).first().map(PromptOwnership.init(row:))
        }

        func livePrompt(identity: PromptOwnership, pathKey: String, excludingID: String) async throws -> PromptRecord? {
            let owner: SQLQueryString
            switch identity {
            case .user(let id): owner = "scope = 'user' AND owner_id = \(bind: id)"
            case .group(let id): owner = "scope = 'group' AND group_id = \(bind: id)"
            }
            return try await sql.raw("""
                SELECT id, scope, owner_id, group_id, path, path_key, content, title, rev,
                       created_by, created_at, updated_by, updated_at, deleted_at
                FROM prompts WHERE \(owner) AND path_key = \(bind: pathKey)
                    AND deleted_at IS NULL AND id != \(bind: excludingID)
                """).first().map(PromptRecord.init(row:))
        }

        func insert(_ head: PromptRecord) async throws {
            try await sql.raw("""
                INSERT INTO prompts (id, scope, owner_id, group_id, path, path_key, content, title, rev,
                                     created_by, created_at, updated_by, updated_at)
                VALUES (\(bind: head.id), \(bind: head.identity.scopeName), \(bind: head.identity.ownerID),
                        \(bind: head.identity.groupID), \(bind: head.path), \(bind: head.pathKey),
                        \(bind: head.content), \(bind: head.title), \(bind: head.rev), \(bind: head.createdBy),
                        \(bind: head.createdAt), \(bind: head.updatedBy), \(bind: head.updatedAt))
                """).run()
        }

        func update(_ head: PromptRecord, baseRev: Int64) async throws {
            guard try await sql.raw("""
                UPDATE prompts SET path = \(bind: head.path), path_key = \(bind: head.pathKey),
                    content = \(bind: head.content), title = \(bind: head.title), rev = rev + 1,
                    updated_by = \(bind: head.updatedBy), updated_at = \(bind: head.updatedAt)
                WHERE id = \(bind: head.id) AND rev = \(bind: baseRev) AND deleted_at IS NULL
                RETURNING id
                """).first() != nil else { throw PromptPersistenceError.casFailed }
        }

        func appendRevision(_ head: PromptRecord, origin: SyncAPI.RevisionOrigin) async throws {
            try await sql.raw("""
                INSERT INTO prompt_revisions (prompt_id, rev, author_id, scope, owner_id, group_id,
                                              path, content, created_at, origin)
                VALUES (\(bind: head.id), \(bind: head.rev), \(bind: head.updatedBy), \(bind: head.identity.scopeName),
                        \(bind: head.identity.ownerID), \(bind: head.identity.groupID), \(bind: head.path),
                        \(bind: head.content), \(bind: head.updatedAt), \(bind: origin.rawValue))
                """).run()
        }

        func appendUpsert(_ head: PromptRecord) async throws -> Int64 {
            guard let row = try await sql.raw("""
                INSERT INTO changes (scope_key, scope, owner_id, group_id, prompt_id, kind, path, rev, content, at)
                VALUES (\(bind: head.identity.key), \(bind: head.identity.scopeName), \(bind: head.identity.ownerID),
                        \(bind: head.identity.groupID), \(bind: head.id), 'upsert', \(bind: head.path),
                        \(bind: head.rev), \(bind: head.content), \(bind: head.updatedAt))
                RETURNING seq
                """).first() else { throw PromptPersistenceError.invalidRecord }
            return try row.decode(column: "seq", as: Int64.self)
        }

        /// A later move back into the same scope must not expose its earlier era.
        func historyBoundary(head: PromptRecord, readerID: String) async throws -> Int64 {
            if head.createdBy == readerID { return 0 }
            guard let row = try await sql.raw("""
                SELECT COALESCE(MAX(rev), 0) AS boundary FROM prompt_revisions
                WHERE prompt_id = \(bind: head.id) AND NOT (
                    scope = \(bind: head.identity.scopeName) AND owner_id IS \(bind: head.identity.ownerID)
                    AND group_id IS \(bind: head.identity.groupID))
                """).first() else { throw PromptPersistenceError.invalidRecord }
            return try row.decode(column: "boundary", as: Int64.self)
        }

        func revisions(id: String, after boundary: Int64) async throws -> [SyncAPI.RevisionSummary] {
            try await sql.raw("""
                SELECT rev, author_id, created_at, origin, scope, owner_id, group_id, path
                FROM prompt_revisions WHERE prompt_id = \(bind: id) AND rev > \(bind: boundary)
                ORDER BY rev DESC LIMIT \(literal: ServerLimits.revisionsPerPrompt)
                """).all().map(Self.summary(row:))
        }

        func revision(id: String, rev: Int64, after boundary: Int64) async throws -> SyncAPI.Revision? {
            guard let row = try await sql.raw("""
                SELECT rev, author_id, created_at, origin, scope, owner_id, group_id, path, content
                FROM prompt_revisions WHERE prompt_id = \(bind: id) AND rev = \(bind: rev) AND rev > \(bind: boundary)
                """).first() else { return nil }
            let summary = try Self.summary(row: row)
            return try .init(id: id, rev: summary.rev, authorID: summary.authorID, createdAt: summary.createdAt,
                             origin: summary.origin, scope: summary.scope, path: summary.path,
                             content: row.decode(column: "content", as: String.self))
        }

        private static func summary(row: any SQLRow) throws -> SyncAPI.RevisionSummary {
            guard let origin = try SyncAPI.RevisionOrigin(rawValue: row.decode(column: "origin", as: String.self)) else {
                throw PromptPersistenceError.invalidRecord
            }
            return try .init(rev: row.decode(column: "rev", as: Int64.self), authorID: row.decode(column: "author_id", as: String.self),
                             createdAt: row.decode(column: "created_at", as: String.self), origin: origin,
                             scope: PromptOwnership(row: row).scope, path: row.decode(column: "path", as: String.self))
        }
    }
}

enum PromptPersistenceError: Error {
    case invalidRecord
    case casFailed
    case revisionExhausted
}
