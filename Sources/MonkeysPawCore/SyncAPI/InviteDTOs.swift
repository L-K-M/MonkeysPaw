import Foundation

extension SyncAPI {
    public enum InviteTarget: Equatable, Sendable {
        case account
        case group(groupID: String, role: InviteRole)

        var object: [String: APIValue] {
            switch self {
            case .account: return [:]
            case .group(let id, let role): return ["group_id": .string(id), "role": .string(role.rawValue)]
            }
        }

        init(object: [String: APIValue]) throws {
            if object["group_id"] == nil { self = .account; return }
            self = .group(groupID: try object.string("group_id"), role: try object.rawEnum("role"))
        }

        static func schema(fields: [SyncAPIField]) -> SyncAPISchema {
            .oneOf([
                .object(fields: fields),
                .object(fields: fields + [.init("group_id", .ulid), .init("role", .reference("InviteRole"))])
            ])
        }
    }

    public struct AdminInviteRequest: APIObjectDTO, Equatable {
        public let target: InviteTarget
        /// Seconds; absent uses the server's seven-day default.
        public let expiresIn: Int64?

        public init(target: InviteTarget, expiresIn: Int64? = nil) {
            self.target = target
            self.expiresIn = expiresIn
        }

        public static let schema = InviteTarget.schema(fields: [.init("expires_in", .inviteTTL, required: false)])

        init(object: [String: APIValue]) throws {
            target = try InviteTarget(object: object)
            expiresIn = try object["expires_in"].map { _ in try object.integer("expires_in") }
        }

        var object: [String: APIValue] {
            var result = target.object
            if let expiresIn { result["expires_in"] = .integer(expiresIn) }
            return result
        }
    }

    public struct InviteResponse: APIObjectDTO, Equatable {
        public let inviteToken: String
        public let expiresAt: String
        public let target: InviteTarget

        public init(inviteToken: String, expiresAt: String, target: InviteTarget) {
            self.inviteToken = inviteToken
            self.expiresAt = expiresAt
            self.target = target
        }

        public static let schema = InviteTarget.schema(fields: [.init("invite_token", .token), .init("expires_at", .timestamp)])

        init(object: [String: APIValue]) throws {
            inviteToken = try object.string("invite_token")
            expiresAt = try object.string("expires_at")
            target = try InviteTarget(object: object)
        }

        var object: [String: APIValue] {
            target.object.merging(["invite_token": .string(inviteToken), "expires_at": .string(expiresAt)]) { _, value in value }
        }
    }
}
