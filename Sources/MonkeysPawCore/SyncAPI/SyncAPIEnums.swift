import Foundation

extension SyncAPI {
    /// Patch presence is separate from a nullable value (§19 B2/B9).
    public enum OptionalValue<Value: Sendable>: Sendable {
        case omitted
        case null
        case value(Value)
    }

    public enum AccountKind: String, SyncAPIDTO, CaseIterable {
        case member, admin
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum Role: String, SyncAPIDTO, CaseIterable {
        case owner, editor, viewer
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    /// HTTP invites never grant owner; the CLI's owner exception is separate.
    public enum InviteRole: String, SyncAPIDTO, CaseIterable {
        case editor, viewer
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum WriteOrigin: String, SyncAPIDTO, CaseIterable {
        case edit, llm, restore
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum RevisionOrigin: String, SyncAPIDTO, CaseIterable {
        case edit, llm, restore, move, delete
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum Mode: String, SyncAPIDTO, CaseIterable {
        case delta, snapshot
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum Severity: String, SyncAPIDTO, CaseIterable {
        case error, warning
        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    public enum PromptScope: APIObjectDTO, Equatable {
        case `private`
        case group(groupID: String)

        public static let schema: SyncAPISchema = .scoped([])

        init(object: [String: APIValue]) throws {
            switch try object.string("scope") {
            case "private": self = .private
            case "group": self = .group(groupID: try object.string("group_id"))
            default: throw APIContractError.invalidValue
            }
        }

        var object: [String: APIValue] {
            switch self {
            case .private: return ["scope": .string("private")]
            case .group(let id): return ["scope": .string("group"), "group_id": .string(id)]
            }
        }
    }
}

extension SyncAPI.OptionalValue: Equatable where Value: Equatable {}

extension Dictionary where Key == String, Value == APIValue {
    var scopeFields: Self { filter { ["scope", "group_id"].contains($0.key) } }

    func patchString(_ key: String) throws -> SyncAPI.OptionalValue<String> {
        guard let value = self[key] else { return .omitted }
        if value == .null { return .null }
        return .value(try string(key))
    }

    mutating func setPatch(_ key: String, _ value: SyncAPI.OptionalValue<String>) {
        switch value {
        case .omitted: break
        case .null: self[key] = .null
        case .value(let text): self[key] = .string(text)
        }
    }
}
