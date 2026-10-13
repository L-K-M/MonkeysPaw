import Foundation

/// Data-only descriptions for the JSON Schema 2020-12 exporter (§19 B2).
/// UTF-8 byte bounds and cross-field rules require documented `x-` annotations
/// in addition to standard JSON Schema keywords; they are enforced by Codable.
public indirect enum SyncAPISchema: Equatable, Sendable {
    case string(SyncAPIString = .init())
    case integer(minimum: Int64, maximum: Int64 = .max)
    case boolean
    case null
    case array(items: SyncAPISchema, minimum: Int = 0, maximum: Int? = nil, unique: Bool = false)
    case object(fields: [SyncAPIField], minimumProperties: Int = 0, rules: [SyncAPIRule] = [])
    case map(keys: SyncAPIString, values: SyncAPISchema)
    case oneOf([SyncAPISchema])
    case reference(String)
}

public struct SyncAPIString: Equatable, Sendable {
    public enum Format: String, Sendable {
        case ulid
        case uuid
        case utcMilliseconds = "utc-milliseconds"
        case scopeKey = "scope-key"
    }

    public let minimumLength: Int
    public let maximumLength: Int?
    public let maximumUTF8Bytes: Int?
    public let pattern: String?
    public let allowedValues: [String]?
    public let format: Format?

    public init(minimumLength: Int = 0, maximumLength: Int? = nil, maximumUTF8Bytes: Int? = nil,
                pattern: String? = nil, allowedValues: [String]? = nil, format: Format? = nil) {
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.pattern = pattern
        self.allowedValues = allowedValues
        self.format = format
    }
}

public struct SyncAPIField: Equatable, Sendable {
    public let name: String
    public let schema: SyncAPISchema
    public let required: Bool

    public init(_ name: String, _ schema: SyncAPISchema, required: Bool = true) {
        self.name = name
        self.schema = schema
        self.required = required
    }
}

/// These relations cannot be expressed by standard JSON Schema alone.
public enum SyncAPIRule: Equatable, Sendable {
    case groupScopeKey
    case syncPage
    case pullItemBudget
}

public struct SyncAPIDescription: Equatable, Sendable {
    public let name: String
    public let schema: SyncAPISchema

    public init(name: String, schema: SyncAPISchema) {
        self.name = name
        self.schema = schema
    }
}

public protocol SyncAPIDTO: Codable, Sendable {
    static var schemaName: String { get }
    static var schema: SyncAPISchema { get }
}

public extension SyncAPIDTO {
    static var schemaName: String { String(describing: Self.self) }
}

public enum SyncAPI {}

extension SyncAPISchema {
    static let ulid: Self = .string(.init(format: .ulid))
    static let uuid: Self = .string(.init(format: .uuid))
    static let timestamp: Self = .string(.init(format: .utcMilliseconds))
    static let scopeKey: Self = .string(.init(format: .scopeKey))
    static let cursor: Self = .string(.init(minimumLength: 1))
    static let token: Self = .string(.init(pattern: "^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$"))
    static let name: Self = .string(.init(minimumLength: 1, maximumLength: 255))
    static let displayName: Self = .string(.init(maximumLength: 255))
    // §19 B7: requests (including login) and metadata require lowercase ASCII.
    static let username: Self = .string(.init(minimumLength: 1, maximumLength: 64,
                                            pattern: "^[a-z0-9][a-z0-9._-]{0,63}$"))
    static let password: Self = .string(.init(minimumLength: 12, maximumLength: Limits.maxPasswordBytes,
                                            maximumUTF8Bytes: Limits.maxPasswordBytes))
    static let suppliedPassword: Self = .string(.init(minimumLength: 1, maximumLength: Limits.maxPasswordBytes,
                                                    maximumUTF8Bytes: Limits.maxPasswordBytes))
    static let content: Self = .string(.init(maximumUTF8Bytes: Limits.maxPromptBytes))
    // Wire bounds only; SyncPathValidator owns full path rules and normalization (§8.4).
    static let path: Self = .string(.init(minimumLength: 1, maximumLength: Limits.maxPathBytes,
                                        maximumUTF8Bytes: Limits.maxPathBytes))
    static let rev: Self = .integer(minimum: 1)
    static let baseRev: Self = .integer(minimum: 0)
    static let seq: Self = .integer(minimum: 0)
    static let inviteTTL: Self = .integer(minimum: 1, maximum: 7 * 24 * 60 * 60)

    static func constant(_ value: String) -> Self { .string(.init(allowedValues: [value])) }
    static func nullable(_ schema: Self) -> Self { .oneOf([.null, schema]) }

    static func scoped(_ fields: [SyncAPIField]) -> Self {
        .oneOf([
            .object(fields: fields + [.init("scope", .constant("user"))]),
            .object(fields: fields + [.init("scope", .constant("group")), .init("group_id", .ulid)])
        ])
    }
}
