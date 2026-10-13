import Foundation

extension SyncAPI {
    public struct PullRequest: APIObjectDTO, Equatable {
        /// Explicit null on first sync; restore detection compares this UUID.
        public let databaseID: String?
        public let cursors: [String: String]

        public init(databaseID: String?, cursors: [String: String]) {
            self.databaseID = databaseID
            self.cursors = cursors
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("database_id", .nullable(.uuid)),
            .init("cursors", .map(keys: .init(format: .scopeKey), values: .cursor))
        ])

        init(object: [String: APIValue]) throws {
            databaseID = try object.optionalString("database_id")
            guard case .object(let map) = object["cursors"] else { throw APIContractError.invalidValue }
            cursors = try map.mapValues {
                guard case .string(let cursor) = $0 else { throw APIContractError.invalidValue }
                return cursor
            }
        }

        var object: [String: APIValue] {
            ["database_id": .nullableString(databaseID), "cursors": .object(cursors.mapValues(APIValue.string))]
        }
    }

    public enum FeedItem: APIObjectDTO, Equatable {
        case upsert(seq: Int64, prompt: FeedPrompt)
        case delete(seq: Int64, id: String)
        case moveOut(seq: Int64, id: String)

        public var seq: Int64 {
            switch self {
            case .upsert(let seq, _), .delete(let seq, _), .moveOut(let seq, _): return seq
            }
        }

        public static let schema: SyncAPISchema = .oneOf([
            .object(fields: [.init("seq", .integer(minimum: 1)), .init("kind", .constant("upsert")), .init("prompt", .reference("FeedPrompt"))]),
            .object(fields: [.init("seq", .integer(minimum: 1)), .init("kind", .constant("delete")), .init("id", .ulid)]),
            .object(fields: [.init("seq", .integer(minimum: 1)), .init("kind", .constant("move_out")), .init("id", .ulid)])
        ])

        init(object: [String: APIValue]) throws {
            let seq = try object.integer("seq")
            switch try object.string("kind") {
            case "upsert": self = .upsert(seq: seq, prompt: try object.dto("prompt"))
            case "delete": self = .delete(seq: seq, id: try object.string("id"))
            case "move_out": self = .moveOut(seq: seq, id: try object.string("id"))
            default: throw APIContractError.invalidValue
            }
        }

        var object: [String: APIValue] {
            switch self {
            case .upsert(let seq, let prompt): return ["seq": .integer(seq), "kind": .string("upsert"), "prompt": .dto(prompt)]
            case .delete(let seq, let id): return ["seq": .integer(seq), "kind": .string("delete"), "id": .string(id)]
            case .moveOut(let seq, let id): return ["seq": .integer(seq), "kind": .string("move_out"), "id": .string(id)]
            }
        }
    }

    public enum ScopeIdentity: APIObjectDTO, Equatable {
        case user(userID: String)
        case group(groupID: String, name: String, role: Role)

        public var key: String {
            switch self {
            case .user(let id): return "user:" + id
            case .group(let id, _, _): return "group:" + id
            }
        }

        public static let schema: SyncAPISchema = schema(fields: [])

        static func schema(fields: [SyncAPIField], rules: [SyncAPIRule] = []) -> SyncAPISchema {
            .oneOf([
                .object(fields: fields + [.init("key", .string(.init(pattern: "^user:[0-7][0-9A-HJKMNP-TV-Z]{25}$"))), .init("kind", .constant("user"))], rules: rules),
                .object(fields: fields + [.init("key", .string(.init(pattern: "^group:[0-7][0-9A-HJKMNP-TV-Z]{25}$"))), .init("kind", .constant("group")), .init("group_id", .ulid),
                                         .init("name", .name), .init("role", .reference("Role"))], rules: rules + [.groupScopeKey])
            ])
        }

        init(object: [String: APIValue]) throws {
            switch try object.string("kind") {
            case "user": self = .user(userID: String(try object.string("key").dropFirst(5)))
            case "group": self = .group(groupID: try object.string("group_id"), name: try object.string("name"), role: try object.rawEnum("role"))
            default: throw APIContractError.invalidValue
            }
        }

        var object: [String: APIValue] {
            switch self {
            case .user: return ["key": .string(key), "kind": .string("user")]
            case .group(let id, let name, let role):
                return ["key": .string(key), "kind": .string("group"), "group_id": .string(id), "name": .string(name), "role": .string(role.rawValue)]
            }
        }
    }

    public struct SyncScope: APIObjectDTO, Equatable {
        public let identity: ScopeIdentity
        public let mode: Mode
        public let head: Int64
        /// Opaque even for snapshots; only the server interprets its spelling.
        public let cursor: String
        public let hasMore: Bool
        public let items: [FeedItem]

        public init(identity: ScopeIdentity, mode: Mode, head: Int64, cursor: String, hasMore: Bool, items: [FeedItem]) {
            self.identity = identity
            self.mode = mode
            self.head = head
            self.cursor = cursor
            self.hasMore = hasMore
            self.items = items
        }

        public static let schema = ScopeIdentity.schema(fields: [
            .init("mode", .reference("Mode")), .init("head", .seq), .init("cursor", .cursor),
            .init("has_more", .boolean), .init("items", .array(items: .reference("FeedItem"), maximum: 200))
        ], rules: [.syncPage])

        init(object: [String: APIValue]) throws {
            identity = try ScopeIdentity(object: object)
            mode = try object.rawEnum("mode")
            head = try object.integer("head")
            cursor = try object.string("cursor")
            hasMore = try object.boolean("has_more")
            items = try object.dtos("items")
        }

        var object: [String: APIValue] {
            identity.object.merging(["mode": .string(mode.rawValue), "head": .integer(head), "cursor": .string(cursor),
                                     "has_more": .boolean(hasMore), "items": .dtos(items)]) { _, value in value }
        }
    }

    public struct PullResponse: APIObjectDTO, Equatable {
        public let databaseID: String
        public let scopes: [SyncScope]
        public let removed: [String]

        public init(databaseID: String, scopes: [SyncScope], removed: [String]) {
            self.databaseID = databaseID
            self.scopes = scopes
            self.removed = removed
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("database_id", .uuid), .init("scopes", .array(items: .reference("SyncScope"), minimum: 1)),
            .init("removed", .array(items: .scopeKey, unique: true))
        ], rules: [.pullItemBudget])

        init(object: [String: APIValue]) throws {
            databaseID = try object.string("database_id")
            scopes = try object.dtos("scopes")
            removed = try object.array("removed").map {
                guard case .string(let key) = $0 else { throw APIContractError.invalidValue }
                return key
            }
        }

        var object: [String: APIValue] {
            ["database_id": .string(databaseID), "scopes": .dtos(scopes), "removed": .array(removed.map(APIValue.string))]
        }
    }
}

extension SyncAPIRule {
    func validate(_ object: [String: APIValue]) throws {
        switch self {
        case .groupScopeKey:
            guard try object.string("key") == "group:" + object.string("group_id") else { throw APIContractError.invalidValue }
        case .syncPage:
            let head = try object.integer("head"), snapshot = try object.string("mode") == "snapshot"
            for item in try object.dtos("items", as: SyncAPI.FeedItem.self) {
                guard item.seq <= head else { throw APIContractError.invalidValue }
                if snapshot {
                    guard case .upsert = item, item.seq == head else { throw APIContractError.invalidValue }
                } else {
                    guard item.seq > 0 else { throw APIContractError.invalidValue }
                }
            }
        case .pullItemBudget:
            let scopes = try object.dtos("scopes", as: SyncAPI.SyncScope.self)
            let keys = scopes.map { $0.identity.key }
            let removed = try object.array("removed")
            let userCount = scopes.filter { if case .user = $0.identity { return true }; return false }.count
            guard scopes.reduce(0, { $0 + $1.items.count }) <= 200, Set(keys).count == keys.count,
                  userCount == 1, !keys.contains(where: { removed.contains(.string($0)) }) else { throw APIContractError.invalidValue }
        }
    }
}
