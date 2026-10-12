import Foundation

extension SyncAPI {
    public enum FailureCode: String, SyncAPIDTO, CaseIterable {
        case unauthorized
        case forbidden
        case notFound = "not_found"
        case malformedRequest = "malformed_request"
        case envelopeTooLarge = "envelope_too_large"
        case rateLimited = "rate_limited"
        case internalError = "internal_error"

        public var httpStatus: Int {
            switch self {
            case .unauthorized: return 401
            case .forbidden: return 403
            case .notFound: return 404
            case .malformedRequest: return 400
            case .envelopeTooLarge: return 413
            case .rateLimited: return 429
            case .internalError: return 500
            }
        }

        public static let schema: SyncAPISchema = .string(.init(allowedValues: allCases.map(\.rawValue)))
    }

    /// Status is transport metadata; no stack trace, credential or tool error
    /// text is part of an envelope (§19 B3/B13/B17).
    public enum ErrorResponse: APIObjectDTO, Equatable {
        case conflict(head: ConflictHead)
        case pathTaken(existing: ExistingPrompt)
        case deleted
        case validation(issues: [Issue])
        case failure(FailureCode)
        case snapshotExpired(scopes: [String])

        public var httpStatus: Int {
            switch self {
            case .conflict, .pathTaken, .snapshotExpired: return 409
            case .deleted: return 410
            case .validation: return 422
            case .failure(let code): return code.httpStatus
            }
        }

        public static let schema: SyncAPISchema = .oneOf([
            .object(fields: [.init("code", .constant("conflict")), .init("head", .reference("ConflictHead"))]),
            .object(fields: [.init("code", .constant("path_taken")), .init("existing", .reference("ExistingPrompt"))]),
            .object(fields: [.init("code", .constant("deleted"))]),
            .object(fields: [.init("issues", .array(items: Issue.schema(severity: .error), minimum: 1))]),
            .object(fields: [.init("code", .reference("FailureCode"))]),
            .object(fields: [.init("code", .constant("snapshot_expired")), .init("scopes", .array(items: .scopeKey, minimum: 1, unique: true))])
        ])

        init(object: [String: APIValue]) throws {
            if object["issues"] != nil { self = .validation(issues: try object.dtos("issues")); return }
            switch try object.string("code") {
            case "conflict": self = .conflict(head: try object.dto("head"))
            case "path_taken": self = .pathTaken(existing: try object.dto("existing"))
            case "deleted": self = .deleted
            case "snapshot_expired":
                self = .snapshotExpired(scopes: try object.array("scopes").map {
                    guard case .string(let key) = $0 else { throw APIContractError.invalidValue }
                    return key
                })
            default: self = .failure(try object.rawEnum("code"))
            }
        }

        var object: [String: APIValue] {
            switch self {
            case .conflict(let head): return ["code": .string("conflict"), "head": .dto(head)]
            case .pathTaken(let existing): return ["code": .string("path_taken"), "existing": .dto(existing)]
            case .deleted: return ["code": .string("deleted")]
            case .validation(let issues): return ["issues": .dtos(issues)]
            case .failure(let code): return ["code": .string(code.rawValue)]
            case .snapshotExpired(let scopes): return ["code": .string("snapshot_expired"), "scopes": .array(scopes.map(APIValue.string))]
            }
        }
    }

    /// A 429 requires this HTTP header, in whole seconds (§19 B3/B8).
    /// Codable represents the header value as a JSON integer for schema tooling.
    public struct RetryAfter: SyncAPIDTO, Equatable {
        public let seconds: Int64
        public var headerValue: String { String(seconds) }
        public static let schema: SyncAPISchema = .integer(minimum: 1, maximum: 15 * 60)

        public init(seconds: Int64) { self.seconds = seconds }

        public init(headerValue: String) throws {
            guard let seconds = Int64(headerValue), String(seconds) == headerValue else { throw APIContractError.invalidValue }
            try Self.schema.validate(.integer(seconds))
            self.seconds = seconds
        }

        public init(from decoder: Decoder) throws {
            let value = try APIValue(from: decoder)
            do {
                try Self.schema.validate(value)
                guard case .integer(let seconds) = value else { throw APIContractError.invalidValue }
                self.seconds = seconds
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Invalid RetryAfter contract."))
            }
        }

        public func encode(to encoder: Encoder) throws {
            let value = APIValue.integer(seconds)
            try Self.schema.validate(value)
            try value.encode(to: encoder)
        }
    }
}
