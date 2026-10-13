import Foundation
import MonkeysPawCore

struct VerifiedAccount: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let user: AccountRecord
    var description: String { "VerifiedAccount(<redacted>)" }
    var debugDescription: String { description }
}

struct AccountService: Sendable {
    let repository: AccountRepository
    let passwords: any PasswordHashing
    let clock: @Sendable () -> Date

    init(
        database: ServerDatabase, passwords: any PasswordHashing = BcryptPasswordHasher(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        repository = AccountRepository(database: database)
        self.passwords = passwords
        self.clock = clock
    }

    @discardableResult
    func bootstrap(_ configuration: BootstrapConfiguration) async throws -> Bool {
        guard try await !repository.read({ accounts, _ in try await accounts.hasUsers() }) else { return false }
        let credentials = try configuration.credentials()
        let username = try AccountValidation.username(credentials.username)
        let hash = try await passwords.hash(credentials.password)
        return try await repository.write { accounts, _ in
            guard try await !accounts.hasUsers() else { return false }
            let now = clock()
            try await accounts.insert(.init(
                id: ServerTimestamp.id(at: now), username: username, displayName: nil,
                passwordHash: hash, accountKind: .admin, createdAt: ServerTimestamp.string(now), disabledAt: nil
            ))
            return true
        }
    }

    /// S7 applies persistent backoff before this work and issues a session only
    /// after a successful check. Unknown and disabled accounts also do bcrypt.
    func verifyCredentials(username: String, password: String) async throws -> VerifiedAccount {
        let normalized = try? AccountValidation.username(username)
        let user: AccountRecord? = try await repository.read { accounts, _ in
            guard let normalized else { return nil }
            return try await accounts.user(username: normalized)
        }
        let matches = try await passwords.verify(password, hash: user?.passwordHash ?? BcryptPasswordHasher.dummyHash)
        guard matches, let user, user.disabledAt == nil else { throw AccountError.unauthorized }
        return VerifiedAccount(user: user)
    }

    func me(_ session: SessionIdentity) async throws -> SyncAPI.MeResponse {
        try await repository.read { accounts, devices in
            let user = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let groups = try await accounts.groups(userID: user.id)
            let ownDevices = try await devices.list(userID: user.id)
            return .init(user: user.metadata, groups: groups,
                         devices: ownDevices.map { $0.metadata(currentDeviceID: session.deviceID) })
        }
    }

    func changePassword(_ request: SyncAPI.PasswordChangeRequest, session: SessionIdentity) async throws {
        try AccountValidation.dto(request)
        try AccountValidation.newPassword(request.newPassword)
        let before = try await repository.read { accounts, devices in
            try await SessionService.requireSession(session, accounts: accounts, devices: devices)
        }
        guard try await passwords.verify(request.currentPassword, hash: before.passwordHash) else {
            throw AccountError.unauthorized
        }
        // Bcrypt work stays outside the serial writer; check its source again inside.
        let hash = try await passwords.hash(request.newPassword)
        try await repository.write { accounts, devices in
            let current = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard current.passwordHash == before.passwordHash else { throw AccountError.unauthorized }
            try await accounts.changePassword(userID: current.id, hash: hash)
            try await devices.revokeOthers(userID: current.id, keeping: session.deviceID, at: ServerTimestamp.string(clock()))
        }
    }
}

/// The executable sees only the composition API, never repository internals.
public func bootstrapAccounts(database: ServerDatabase, configuration: BootstrapConfiguration) async throws {
    try await AccountService(database: database).bootstrap(configuration)
}
