import Foundation

extension SyncAPI {
    public struct Group: APIObjectDTO, Equatable {
        public let id: String
        public let name: String
        public let createdBy: String
        public let createdAt: String

        public init(id: String, name: String, createdBy: String, createdAt: String) {
            self.id = id
            self.name = name
            self.createdBy = createdBy
            self.createdAt = createdAt
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("name", .name),
            .init("created_by", .ulid),
            .init("created_at", .timestamp)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            name = try object.string("name")
            createdBy = try object.string("created_by")
            createdAt = try object.string("created_at")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "name": .string(name), "created_by": .string(createdBy), "created_at": .string(createdAt)]
        }
    }

    public struct GroupMembership: APIObjectDTO, Equatable {
        public let groupID: String
        public let name: String
        public let role: Role

        public init(groupID: String, name: String, role: Role) {
            self.groupID = groupID
            self.name = name
            self.role = role
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("group_id", .ulid),
            .init("name", .name),
            .init("role", .reference("Role"))
        ])

        init(object: [String: APIValue]) throws {
            groupID = try object.string("group_id")
            name = try object.string("name")
            role = try object.rawEnum("role")
        }

        var object: [String: APIValue] {
            return ["group_id": .string(groupID), "name": .string(name), "role": .string(role.rawValue)]
        }
    }

    public struct CreateGroupRequest: APIObjectDTO, Equatable {
        public let name: String

        public init(name: String) {
            self.name = name
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("name", .name)
        ])

        init(object: [String: APIValue]) throws {
            name = try object.string("name")
        }

        var object: [String: APIValue] {
            return ["name": .string(name)]
        }
    }

    public struct RenameGroupRequest: APIObjectDTO, Equatable {
        public let name: String

        public init(name: String) {
            self.name = name
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("name", .name)
        ])

        init(object: [String: APIValue]) throws {
            name = try object.string("name")
        }

        var object: [String: APIValue] {
            return ["name": .string(name)]
        }
    }

    public struct Member: APIObjectDTO, Equatable {
        public let userID: String
        public let username: String
        public let displayName: String?
        public let role: Role
        public let joinedAt: String

        public init(userID: String, username: String, displayName: String?, role: Role, joinedAt: String) {
            self.userID = userID
            self.username = username
            self.displayName = displayName
            self.role = role
            self.joinedAt = joinedAt
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("user_id", .ulid),
            .init("username", .storedUsername),
            .init("display_name", .nullable(.displayName)),
            .init("role", .reference("Role")),
            .init("joined_at", .timestamp)
        ])

        init(object: [String: APIValue]) throws {
            userID = try object.string("user_id")
            username = try object.string("username")
            displayName = try object.optionalString("display_name")
            role = try object.rawEnum("role")
            joinedAt = try object.string("joined_at")
        }

        var object: [String: APIValue] {
            return ["user_id": .string(userID), "username": .string(username), "display_name": .nullableString(displayName), "role": .string(role.rawValue), "joined_at": .string(joinedAt)]
        }
    }

    public struct MembersResponse: APIObjectDTO, Equatable {
        public let members: [Member]

        public init(members: [Member]) {
            self.members = members
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("members", .array(items: .reference("Member")))
        ])

        init(object: [String: APIValue]) throws {
            members = try object.dtos("members")
        }

        var object: [String: APIValue] {
            return ["members": .dtos(members)]
        }
    }

    public struct MembershipRequest: APIObjectDTO, Equatable {
        public let role: Role

        public init(role: Role) {
            self.role = role
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("role", .reference("Role"))
        ])

        init(object: [String: APIValue]) throws {
            role = try object.rawEnum("role")
        }

        var object: [String: APIValue] {
            return ["role": .string(role.rawValue)]
        }
    }

    public struct GroupInviteRequest: APIObjectDTO, Equatable {
        public let role: InviteRole
        public let expiresIn: Int64?

        public init(role: InviteRole, expiresIn: Int64? = nil) {
            self.role = role
            self.expiresIn = expiresIn
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("role", .reference("InviteRole")),
            .init("expires_in", .inviteTTL, required: false)
        ])

        init(object: [String: APIValue]) throws {
            role = try object.rawEnum("role")
            expiresIn = try object["expires_in"].map { _ in try object.integer("expires_in") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["role": .string(role.rawValue)]
            if let expiresIn { result["expires_in"] = .integer(expiresIn) }
            return result
        }
    }

    public struct JoinGroupRequest: APIObjectDTO, Equatable {
        public let inviteToken: String

        public init(inviteToken: String) {
            self.inviteToken = inviteToken
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("invite_token", .token)
        ])

        init(object: [String: APIValue]) throws {
            inviteToken = try object.string("invite_token")
        }

        var object: [String: APIValue] {
            return ["invite_token": .string(inviteToken)]
        }
    }

}
