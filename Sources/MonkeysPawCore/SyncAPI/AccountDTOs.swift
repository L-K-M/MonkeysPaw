import Foundation

extension SyncAPI {
    public struct HealthResponse: APIObjectDTO, Equatable {
        public let status: String
        public let version: String

        public init(status: String, version: String) {
            self.status = status
            self.version = version
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("status", .constant("ok")),
            .init("version", .string(.init(minimumLength: 1)))
        ])

        init(object: [String: APIValue]) throws {
            status = try object.string("status")
            version = try object.string("version")
        }

        var object: [String: APIValue] {
            return ["status": .string(status), "version": .string(version)]
        }
    }

    public struct EmptyResponse: APIObjectDTO, Equatable {

        public init() {
        }

        public static let schema: SyncAPISchema = .object(fields: [

        ])

        init(object: [String: APIValue]) throws {
        }

        var object: [String: APIValue] {
            [:]
        }
    }

    public struct IDPath: APIObjectDTO, Equatable {
        public let id: String

        public init(id: String) {
            self.id = id
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
        }

        var object: [String: APIValue] {
            return ["id": .string(id)]
        }
    }

    public struct MemberPath: APIObjectDTO, Equatable {
        public let id: String
        public let userID: String

        public init(id: String, userID: String) {
            self.id = id
            self.userID = userID
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("user_id", .ulid)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            userID = try object.string("user_id")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "user_id": .string(userID)]
        }
    }

    public struct RevisionPath: APIObjectDTO, Equatable {
        public let id: String
        public let rev: Int64

        public init(id: String, rev: Int64) {
            self.id = id
            self.rev = rev
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("rev", .rev)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            rev = try object.integer("rev")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "rev": .integer(rev)]
        }
    }

    public struct LoginRequest: APIObjectDTO, Equatable {
        public let username: String
        public let password: String
        public let deviceName: String

        public init(username: String, password: String, deviceName: String) {
            self.username = username
            self.password = password
            self.deviceName = deviceName
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("username", .username),
            .init("password", .suppliedPassword),
            .init("device_name", .name)
        ])

        init(object: [String: APIValue]) throws {
            username = try object.string("username")
            password = try object.string("password")
            deviceName = try object.string("device_name")
        }

        var object: [String: APIValue] {
            return ["username": .string(username), "password": .string(password), "device_name": .string(deviceName)]
        }
    }

    public struct RegisterRequest: APIObjectDTO, Equatable {
        public let inviteToken: String
        public let username: String
        public let password: String
        public let deviceName: String

        public init(inviteToken: String, username: String, password: String, deviceName: String) {
            self.inviteToken = inviteToken
            self.username = username
            self.password = password
            self.deviceName = deviceName
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("invite_token", .token),
            .init("username", .username),
            .init("password", .password),
            .init("device_name", .name)
        ])

        init(object: [String: APIValue]) throws {
            inviteToken = try object.string("invite_token")
            username = try object.string("username")
            password = try object.string("password")
            deviceName = try object.string("device_name")
        }

        var object: [String: APIValue] {
            return ["invite_token": .string(inviteToken), "username": .string(username), "password": .string(password), "device_name": .string(deviceName)]
        }
    }

    public struct PasswordChangeRequest: APIObjectDTO, Equatable {
        public let currentPassword: String
        public let newPassword: String

        public init(currentPassword: String, newPassword: String) {
            self.currentPassword = currentPassword
            self.newPassword = newPassword
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("current_password", .suppliedPassword),
            .init("new_password", .password)
        ])

        init(object: [String: APIValue]) throws {
            currentPassword = try object.string("current_password")
            newPassword = try object.string("new_password")
        }

        var object: [String: APIValue] {
            return ["current_password": .string(currentPassword), "new_password": .string(newPassword)]
        }
    }

    public struct User: APIObjectDTO, Equatable {
        public let id: String
        public let username: String
        public let displayName: String?
        public let accountKind: AccountKind
        public let createdAt: String
        public let disabledAt: String?

        public init(id: String, username: String, displayName: String?, accountKind: AccountKind, createdAt: String, disabledAt: String?) {
            self.id = id
            self.username = username
            self.displayName = displayName
            self.accountKind = accountKind
            self.createdAt = createdAt
            self.disabledAt = disabledAt
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("username", .username),
            .init("display_name", .nullable(.displayName)),
            .init("account_kind", .reference("AccountKind")),
            .init("created_at", .timestamp),
            .init("disabled_at", .nullable(.timestamp))
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            username = try object.string("username")
            displayName = try object.optionalString("display_name")
            accountKind = try object.rawEnum("account_kind")
            createdAt = try object.string("created_at")
            disabledAt = try object.optionalString("disabled_at")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "username": .string(username), "display_name": .nullableString(displayName), "account_kind": .string(accountKind.rawValue), "created_at": .string(createdAt), "disabled_at": .nullableString(disabledAt)]
        }
    }

    public struct AuthResponse: APIObjectDTO, Equatable {
        public let deviceToken: String
        public let user: User

        public init(deviceToken: String, user: User) {
            self.deviceToken = deviceToken
            self.user = user
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("device_token", .token),
            .init("user", .reference("User"))
        ])

        init(object: [String: APIValue]) throws {
            deviceToken = try object.string("device_token")
            user = try object.dto("user")
        }

        var object: [String: APIValue] {
            return ["device_token": .string(deviceToken), "user": .dto(user)]
        }
    }

    public struct Device: APIObjectDTO, Equatable {
        public let id: String
        public let name: String
        public let createdAt: String
        public let lastSeenAt: String?
        public let revokedAt: String?
        public let isCurrent: Bool

        public init(id: String, name: String, createdAt: String, lastSeenAt: String?, revokedAt: String?, isCurrent: Bool) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.revokedAt = revokedAt
            self.isCurrent = isCurrent
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("id", .ulid),
            .init("name", .name),
            .init("created_at", .timestamp),
            .init("last_seen_at", .nullable(.timestamp)),
            .init("revoked_at", .nullable(.timestamp)),
            .init("is_current", .boolean)
        ])

        init(object: [String: APIValue]) throws {
            id = try object.string("id")
            name = try object.string("name")
            createdAt = try object.string("created_at")
            lastSeenAt = try object.optionalString("last_seen_at")
            revokedAt = try object.optionalString("revoked_at")
            isCurrent = try object.boolean("is_current")
        }

        var object: [String: APIValue] {
            return ["id": .string(id), "name": .string(name), "created_at": .string(createdAt), "last_seen_at": .nullableString(lastSeenAt), "revoked_at": .nullableString(revokedAt), "is_current": .boolean(isCurrent)]
        }
    }

    public struct MeResponse: APIObjectDTO, Equatable {
        public let user: User
        public let groups: [GroupMembership]
        public let devices: [Device]

        public init(user: User, groups: [GroupMembership], devices: [Device]) {
            self.user = user
            self.groups = groups
            self.devices = devices
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("user", .reference("User")),
            .init("groups", .array(items: .reference("GroupMembership"))),
            .init("devices", .array(items: .reference("Device")))
        ])

        init(object: [String: APIValue]) throws {
            user = try object.dto("user")
            groups = try object.dtos("groups")
            devices = try object.dtos("devices")
        }

        var object: [String: APIValue] {
            return ["user": .dto(user), "groups": .dtos(groups), "devices": .dtos(devices)]
        }
    }

    public struct CreateUserRequest: APIObjectDTO, Equatable {
        public let username: String
        public let password: String
        public let displayName: OptionalValue<String>
        public let accountKind: AccountKind?

        public init(username: String, password: String, displayName: OptionalValue<String> = .omitted, accountKind: AccountKind? = nil) {
            self.username = username
            self.password = password
            self.displayName = displayName
            self.accountKind = accountKind
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("username", .username),
            .init("password", .password),
            .init("display_name", .nullable(.displayName), required: false),
            .init("account_kind", .reference("AccountKind"), required: false)
        ])

        init(object: [String: APIValue]) throws {
            username = try object.string("username")
            password = try object.string("password")
            displayName = try object.patchString("display_name")
            accountKind = try object["account_kind"].map { _ in try object.rawEnum("account_kind") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["username": .string(username), "password": .string(password)]
            result.setPatch("display_name", displayName)
            if let accountKind { result["account_kind"] = .string(accountKind.rawValue) }
            return result
        }
    }

    public struct UpdateUserRequest: APIObjectDTO, Equatable {
        public let displayName: OptionalValue<String>
        public let password: String?
        public let disabled: Bool?
        public let accountKind: AccountKind?

        public init(displayName: OptionalValue<String> = .omitted, password: String? = nil, disabled: Bool? = nil, accountKind: AccountKind? = nil) {
            self.displayName = displayName
            self.password = password
            self.disabled = disabled
            self.accountKind = accountKind
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("display_name", .nullable(.displayName), required: false),
            .init("password", .password, required: false),
            .init("disabled", .boolean, required: false),
            .init("account_kind", .reference("AccountKind"), required: false)
        ], minimumProperties: 1)

        init(object: [String: APIValue]) throws {
            displayName = try object.patchString("display_name")
            password = try object["password"].map { _ in try object.string("password") }
            disabled = try object["disabled"].map { _ in try object.boolean("disabled") }
            accountKind = try object["account_kind"].map { _ in try object.rawEnum("account_kind") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = [:]
            result.setPatch("display_name", displayName)
            if let password { result["password"] = .string(password) }
            if let disabled { result["disabled"] = .boolean(disabled) }
            if let accountKind { result["account_kind"] = .string(accountKind.rawValue) }
            return result
        }
    }

}
