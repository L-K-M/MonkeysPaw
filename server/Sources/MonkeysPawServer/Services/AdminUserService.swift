import Foundation
import MonkeysPawCore

struct AdminUserService: Sendable {
    private let repository: AccountRepository
    private let passwords: any PasswordHashing
    private let clock: @Sendable () -> Date
    private let auditWrite: @Sendable (AuditRepository, AuditEvent) async throws -> Void

    init(
        accounts: AccountService,
        auditWrite: @escaping @Sendable (AuditRepository, AuditEvent) async throws -> Void = { try await $0.insert($1) }
    ) {
        repository = accounts.repository
        passwords = accounts.passwords
        clock = accounts.clock
        self.auditWrite = auditWrite
    }

    func create(_ request: SyncAPI.CreateUserRequest, session: SessionIdentity) async throws -> SyncAPI.User {
        try AccountValidation.dto(request)
        let username = try AccountValidation.username(request.username)
        try AccountValidation.newPassword(request.password)
        try await repository.read { accounts, devices in
            _ = try await Self.requireAdmin(session, accounts: accounts, devices: devices)
        }
        // Reject non-admins before bcrypt; recheck authority after it completes.
        let hash = try await passwords.hash(request.password)
        return try await repository.writeAudited { accounts, devices, audit in
            let actor = try await Self.requireAdmin(session, accounts: accounts, devices: devices)
            guard try await accounts.user(username: username) == nil else { throw AccountError.malformedRequest }
            let now = clock()
            let user = try AccountRecord(
                id: ServerTimestamp.id(at: now), username: username,
                displayName: Self.displayName(request.displayName, keeping: nil), passwordHash: hash,
                accountKind: request.accountKind ?? .member, createdAt: ServerTimestamp.string(now), disabledAt: nil
            )
            try await accounts.insert(user)
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .userCreate, targetID: user.id, at: now))
            return user.metadata
        }
    }

    func update(id: String, request: SyncAPI.UpdateUserRequest, session: SessionIdentity) async throws -> SyncAPI.User {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(request)
        if let password = request.password { try AccountValidation.newPassword(password) }
        try await repository.read { accounts, devices in
            _ = try await Self.requireAdmin(session, accounts: accounts, devices: devices)
            guard try await accounts.user(id: id) != nil else { throw AccountError.notFound }
        }
        let hash: String?
        if let password = request.password { hash = try await passwords.hash(password) } else { hash = nil }
        let actions = Self.actions(for: request)
        return try await repository.writeAudited { accounts, devices, audit in
            let actor = try await Self.requireAdmin(session, accounts: accounts, devices: devices)
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
            try await accounts.update(updated)
            if hash != nil || request.disabled == true {
                try await devices.revokeAll(userID: id, at: timestamp)
            }
            for action in actions {
                try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: action, targetID: id, at: now))
            }
            return updated.metadata
        }
    }

    private static func requireAdmin(
        _ session: SessionIdentity, accounts: AccountRepository.Transaction, devices: DeviceRepository
    ) async throws -> AccountRecord {
        let user = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
        guard user.accountKind == .admin else { throw AccountError.forbidden }
        return user
    }

    private static func displayName(_ value: SyncAPI.OptionalValue<String>, keeping current: String?) -> String? {
        switch value {
        case .omitted: return current
        case .null: return nil
        case .value(let name): return name
        }
    }

    private static func actions(for request: SyncAPI.UpdateUserRequest) -> [AuditAction] {
        var actions: [AuditAction] = []
        if request.displayName != .omitted || request.accountKind != nil { actions.append(.userUpdate) }
        if request.password != nil { actions.append(.userResetPassword) }
        if let disabled = request.disabled { actions.append(disabled ? .userDisable : .userEnable) }
        return actions
    }
}
