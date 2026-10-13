import Foundation
import MonkeysPawCore

/// The executable composes the same services as HTTP without accessing repositories.
public struct OperatorAdminService: Sendable {
    private let admin: AdminUserService
    private let groups: GroupService
    private let invites: InviteService

    public init(database: ServerDatabase, configuration: ServerConfiguration) {
        let accounts = AccountService(database: database)
        // CLI stdout contains only explicit command output; durable audits remain mandatory.
        admin = AdminUserService(accounts: accounts, logger: ServerLogging.logger(level: .critical))
        groups = GroupService(database: database)
        invites = InviteService(accounts: accounts, sessions: SessionService(database: database), publicURL: configuration.publicURL)
    }

    public func addUser(username: String, password: String, kind: SyncAPI.AccountKind, displayName: String?) async throws -> SyncAPI.User {
        try await admin.create(.init(username: username, password: password,
                                     displayName: displayName.map { .value($0) } ?? .omitted, accountKind: kind), actor: .cliOperator)
    }

    public func disableUser(id: String) async throws -> SyncAPI.User {
        try await admin.update(id: id, request: .init(disabled: true), actor: .cliOperator)
    }

    public func resetPassword(id: String, password: String) async throws -> SyncAPI.User {
        try await admin.update(id: id, request: .init(password: password), actor: .cliOperator)
    }

    public func addGroup(name: String, ownerID: String) async throws -> SyncAPI.Group {
        try await groups.create(.init(name: name), ownerID: ownerID)
    }

    public func addMember(groupID: String, userID: String, role: SyncAPI.Role) async throws -> SyncAPI.Member {
        try await groups.upsertMember(id: groupID, userID: userID, request: .init(role: role), actor: .cliOperator)
    }

    public func createInvite(issuerID: String, groupID: String?, role: SyncAPI.Role?, expiresIn: Int64?) async throws -> OperatorInvite {
        let target: InviteRecord.Target
        switch (groupID, role) {
        case (nil, nil): target = .account
        case (.some(let id), .some(let role)): target = .group(groupID: id, role: role)
        default: throw AccountError.malformedRequest
        }
        let secret = try await invites.createOperator(target: target, issuerID: issuerID, expiresIn: expiresIn)
        return .init(secret: secret.link ?? secret.token.value, expiresAt: secret.expiresAt, groupID: groupID, role: role)
    }
}

/// Encode only for explicit one-time output, never for diagnostics or reflection.
public struct OperatorInvite: Sendable, Encodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let secret: String
    public let expiresAt: String
    public let groupID: String?
    public let role: SyncAPI.Role?
    public var description: String { "OperatorInvite(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private enum CodingKeys: String, CodingKey {
        case secret, role
        case expiresAt = "expires_at"
        case groupID = "group_id"
    }
}

public enum OperatorCommandError: Error, CustomStringConvertible {
    case invalidInput, notFound, forbidden, passwordInput, failed

    /// Do not expose DTO, SQL, filesystem or parser errors, which can carry secrets.
    public init(sanitizing error: any Error) {
        switch error as? AccountError {
        case .malformedRequest: self = .invalidInput
        case .notFound: self = .notFound
        case .forbidden, .unauthorized: self = .forbidden
        case nil: self = (error as? Self) ?? .failed
        }
    }

    public var description: String {
        switch self {
        case .invalidInput: return "Invalid administration input."
        case .notFound: return "User or group not found."
        case .forbidden: return "Operation violates an administration rule."
        case .passwordInput: return "Password input is missing, unreadable, or invalid."
        case .failed: return "Administration command failed."
        }
    }
}
