import Foundation

extension SyncAPI {
    public struct Prompt: APIObjectDTO, Equatable {
        public let id: String
        public let rev: Int64
        public let scope: PromptScope
        public let path: String
        public let content: String

        public init(id: String, rev: Int64, scope: PromptScope, path: String, content: String) {
            self.id = id
            self.rev = rev
            self.scope = scope
            self.path = path
            self.content = content
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("id", .ulid),
            .init("rev", .rev),
            .init("path", .path),
            .init("content", .content)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            rev = try object.integer("rev")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
            content = try object.string("content")
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["id": .string(id), "rev": .integer(rev), "path": .string(path), "content": .string(content)]
            result.merge(scope.object) { _, value in value }
            return result
        }
    }

    public struct PutPromptRequest: APIObjectDTO, Equatable {
        public let baseRev: Int64
        public let scope: PromptScope
        public let path: String
        public let content: String
        public let origin: WriteOrigin?

        public init(baseRev: Int64, scope: PromptScope, path: String, content: String, origin: WriteOrigin? = nil) {
            self.baseRev = baseRev
            self.scope = scope
            self.path = path
            self.content = content
            self.origin = origin
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("base_rev", .baseRev),
            .init("path", .path),
            .init("content", .content),
            .init("origin", .reference("WriteOrigin"), required: false)
        ])

        init(object: [String: APIValue]) throws {
            baseRev = try object.integer("base_rev")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
            content = try object.string("content")
            origin = try object["origin"].map { _ in try object.rawEnum("origin") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["base_rev": .integer(baseRev), "path": .string(path), "content": .string(content)]
            result.merge(scope.object) { _, value in value }
            if let origin { result["origin"] = .string(origin.rawValue) }
            return result
        }
    }

    public struct DeletePromptQuery: APIObjectDTO, Equatable {
        public let baseRev: Int64

        public init(baseRev: Int64) {
            self.baseRev = baseRev
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("base_rev", .rev)
        ])

        init(object: [String: APIValue]) throws {
            baseRev = try object.integer("base_rev")
        }

        var object: [String: APIValue] {
            return ["base_rev": .integer(baseRev)]
        }
    }

    public struct MovePromptRequest: APIObjectDTO, Equatable {
        public let baseRev: Int64
        public let scope: PromptScope
        public let path: String

        public init(baseRev: Int64, scope: PromptScope, path: String) {
            self.baseRev = baseRev
            self.scope = scope
            self.path = path
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("base_rev", .rev),
            .init("path", .path)
        ])

        init(object: [String: APIValue]) throws {
            baseRev = try object.integer("base_rev")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["base_rev": .integer(baseRev), "path": .string(path)]
            result.merge(scope.object) { _, value in value }
            return result
        }
    }

    public struct WriteResponse: APIObjectDTO, Equatable {
        public let rev: Int64
        public let seq: Int64
        public let warnings: [Issue]?

        public init(rev: Int64, seq: Int64, warnings: [Issue]? = nil) {
            self.rev = rev
            self.seq = seq
            self.warnings = warnings
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("rev", .rev),
            .init("seq", .integer(minimum: 1)),
            .init("warnings", .array(items: Issue.schema(severity: .warning)), required: false)
        ])

        init(object: [String: APIValue]) throws {
            rev = try object.integer("rev")
            seq = try object.integer("seq")
            warnings = try object["warnings"].map { _ in try object.dtos("warnings") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["rev": .integer(rev), "seq": .integer(seq)]
            if let warnings { result["warnings"] = .dtos(warnings) }
            return result
        }
    }

    public struct ConflictHead: APIObjectDTO, Equatable {
        public let rev: Int64
        public let scope: PromptScope
        public let path: String
        public let content: String

        public init(rev: Int64, scope: PromptScope, path: String, content: String) {
            self.rev = rev
            self.scope = scope
            self.path = path
            self.content = content
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("rev", .rev),
            .init("path", .path),
            .init("content", .content)
        ])

        init(object: [String: APIValue]) throws {
            rev = try object.integer("rev")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
            content = try object.string("content")
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["rev": .integer(rev), "path": .string(path), "content": .string(content)]
            result.merge(scope.object) { _, value in value }
            return result
        }
    }

    public struct ExistingPrompt: APIObjectDTO, Equatable {
        public let id: String
        public let rev: Int64
        public let content: String

        public init(id: String, rev: Int64, content: String) {
            self.id = id
            self.rev = rev
            self.content = content
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("rev", .rev),
            .init("content", .content)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            rev = try object.integer("rev")
            content = try object.string("content")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "rev": .integer(rev), "content": .string(content)]
        }
    }

    public struct RevisionSummary: APIObjectDTO, Equatable {
        public let rev: Int64
        public let authorID: String
        public let createdAt: String
        public let origin: RevisionOrigin
        public let scope: PromptScope
        public let path: String

        public init(rev: Int64, authorID: String, createdAt: String, origin: RevisionOrigin, scope: PromptScope, path: String) {
            self.rev = rev
            self.authorID = authorID
            self.createdAt = createdAt
            self.origin = origin
            self.scope = scope
            self.path = path
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("rev", .rev),
            .init("author_id", .ulid),
            .init("created_at", .timestamp),
            .init("origin", .reference("RevisionOrigin")),
            .init("path", .path)
        ])

        init(object: [String: APIValue]) throws {
            rev = try object.integer("rev")
            authorID = try object.string("author_id")
            createdAt = try object.string("created_at")
            origin = try object.rawEnum("origin")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["rev": .integer(rev), "author_id": .string(authorID), "created_at": .string(createdAt), "origin": .string(origin.rawValue), "path": .string(path)]
            result.merge(scope.object) { _, value in value }
            return result
        }
    }

    public struct RevisionsResponse: APIObjectDTO, Equatable {
        public let revisions: [RevisionSummary]

        public init(revisions: [RevisionSummary]) {
            self.revisions = revisions
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("revisions", .array(items: .reference("RevisionSummary"), maximum: 200))
        ])

        init(object: [String: APIValue]) throws {
            revisions = try object.dtos("revisions")
        }

        var object: [String: APIValue] {
            return ["revisions": .dtos(revisions)]
        }
    }

    public struct Revision: APIObjectDTO, Equatable {
        public let id: String
        public let rev: Int64
        public let authorID: String
        public let createdAt: String
        public let origin: RevisionOrigin
        public let scope: PromptScope
        public let path: String
        public let content: String

        public init(id: String, rev: Int64, authorID: String, createdAt: String, origin: RevisionOrigin, scope: PromptScope, path: String, content: String) {
            self.id = id
            self.rev = rev
            self.authorID = authorID
            self.createdAt = createdAt
            self.origin = origin
            self.scope = scope
            self.path = path
            self.content = content
        }

        public static let schema: SyncAPISchema = .scoped([
            .init("id", .ulid),
            .init("rev", .rev),
            .init("author_id", .ulid),
            .init("created_at", .timestamp),
            .init("origin", .reference("RevisionOrigin")),
            .init("path", .path),
            .init("content", .content)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            rev = try object.integer("rev")
            authorID = try object.string("author_id")
            createdAt = try object.string("created_at")
            origin = try object.rawEnum("origin")
            scope = try PromptScope(object: object.scopeFields)
            path = try object.string("path")
            content = try object.string("content")
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["id": .string(id), "rev": .integer(rev), "author_id": .string(authorID), "created_at": .string(createdAt), "origin": .string(origin.rawValue), "path": .string(path), "content": .string(content)]
            result.merge(scope.object) { _, value in value }
            return result
        }
    }

    public struct FeedPrompt: APIObjectDTO, Equatable {
        public let id: String
        public let rev: Int64
        public let path: String
        public let content: String

        public init(id: String, rev: Int64, path: String, content: String) {
            self.id = id
            self.rev = rev
            self.path = path
            self.content = content
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("rev", .rev),
            .init("path", .path),
            .init("content", .content)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            rev = try object.integer("rev")
            path = try object.string("path")
            content = try object.string("content")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "rev": .integer(rev), "path": .string(path), "content": .string(content)]
        }
    }

}
