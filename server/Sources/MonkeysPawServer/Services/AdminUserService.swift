import Foundation
import Logging
import MonkeysPawCore

struct AdminUserService: Sendable {
    private let repository: AccountRepository
    private let passwords: any PasswordHashing
    private let clock: @Sendable () -> Date
    private let logger: Logger
    private let auditWrite: @Sendable (AuditRepository, AuditEvent) async throws -> Void

    init(
        accounts: AccountService, logger: Logger = ServerLogging.logger(),
        auditWrite: @escaping @Sendable (AuditRepository, AuditEvent) async throws -> Void = { try await $0.insert($1) }
    ) {
        repository = accounts.repository
        passwords = accounts.passwords
        clock = accounts.clock
        self.logger = logger
        self.auditWrite = auditWrite
    }

    func create(_ request: SyncAPI.CreateUserRequest, session: SessionIdentity) async throws -> SyncAPI.User {
        try await create(request, actor: .session(session))
    }

    func create(_ request: SyncAPI.CreateUserRequest, actor: AdministrationActor) async throws -> SyncAPI.User {
        try AccountValidation.dto(request)
        let username = try AccountValidation.username(request.username)
        try AccountValidation.newPassword(request.password)
        try await repository.read { accounts, devices in
            try await actor.requireAdmin(accounts: accounts, devices: devices)
        }
        // Reject non-admins before bcrypt; recheck authority after it completes.
        let hash = try await passwords.hash(request.password)
        let user = try await repository.writeAudited { accounts, devices, audit in
            try await actor.requireAdmin(accounts: accounts, devices: devices)
            // §8.3 retains the S1 malformed_request envelope for duplicate usernames.
            guard try await accounts.user(username: username) == nil else { throw AccountError.malformedRequest }
            let now = clock()
            let user = try AccountRecord(
                id: ServerTimestamp.id(at: now), username: username,
                displayName: Self.displayName(request.displayName, keeping: nil), passwordHash: hash,
                accountKind: request.accountKind ?? .member, createdAt: ServerTimestamp.string(now), disabledAt: nil
            )
            try await accounts.insert(user)
            try await auditWrite(audit, AuditEvent(actor: actor.auditActor, action: .userCreate, targetID: user.id, at: now))
            return user.metadata
        }
        log(.userCreate, actorID: actor.auditActor.userID ?? "operator", targetID: user.id)
        return user
    }

    func update(id: String, request: SyncAPI.UpdateUserRequest, session: SessionIdentity) async throws -> SyncAPI.User {
        try await update(id: id, request: request, actor: .session(session))
    }

    func update(id: String, request: SyncAPI.UpdateUserRequest, actor: AdministrationActor) async throws -> SyncAPI.User {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(request)
        if let password = request.password { try AccountValidation.newPassword(password) }
        try await repository.read { accounts, devices in
            try await actor.requireAdmin(accounts: accounts, devices: devices)
            guard try await accounts.user(id: id) != nil else { throw AccountError.notFound }
        }
        let hash: String?
        if let password = request.password { hash = try await passwords.hash(password) } else { hash = nil }
        let (user, actions) = try await repository.writeAudited { accounts, devices, audit in
            try await actor.requireAdmin(accounts: accounts, devices: devices)
            guard let current = try await accounts.user(id: id) else { throw AccountError.notFound }
            let now = clock()
            let timestamp = ServerTimestamp.string(now)
            let disabledAt: String?
            if let disabled = request.disabled {
                disabledAt = disabled ? current.disabledAt ?? timestamp : nil
            } else {
                disabledAt = current.disabledAt
            }
            let updated = AccountRecord(
                id: current.id, username: current.username,
                displayName: Self.displayName(request.displayName, keeping: current.displayName),
                passwordHash: hash ?? current.passwordHash, accountKind: request.accountKind ?? current.accountKind,
                createdAt: current.createdAt, disabledAt: disabledAt
            )
            if current.accountKind == .admin && current.disabledAt == nil,
               updated.accountKind != .admin || updated.disabledAt != nil {
                guard try await accounts.hasActiveAdmin(excluding: id) else { throw AccountError.forbidden }
            }
            let actions = Self.actions(from: current, to: updated)
            if !actions.isEmpty { try await accounts.update(updated) }
            if hash != nil || request.disabled == true {
                try await devices.revokeAll(userID: id, at: timestamp)
            }
            for action in actions {
                try await auditWrite(audit, AuditEvent(actor: actor.auditActor, action: action, targetID: id, at: now))
            }
            return (updated.metadata, actions)
        }
        for action in actions { log(action, actorID: actor.auditActor.userID ?? "operator", targetID: id) }
        return user
    }

    private func log(_ action: AuditAction, actorID: String, targetID: String) {
        logger.info("Account mutation committed", metadata: [
            "action": .string(action.rawValue), "actor_id": .string(actorID), "target_id": .string(targetID)
        ])
    }

    private static func displayName(_ value: SyncAPI.OptionalValue<String>, keeping current: String?) -> String? {
        switch value {
        case .omitted: return current
        case .null: return nil
        case .value(let name): return name
        }
    }

    private static func actions(from current: AccountRecord, to updated: AccountRecord) -> [AuditAction] {
        var actions: [AuditAction] = []
        if updated.displayName != current.displayName || updated.accountKind != current.accountKind { actions.append(.userUpdate) }
        if updated.passwordHash != current.passwordHash { actions.append(.userResetPassword) }
        switch (current.disabledAt, updated.disabledAt) {
        case (nil, .some): actions.append(.userDisable)
        case (.some, nil): actions.append(.userEnable)
        default: break
        }
        return actions
    }
}
