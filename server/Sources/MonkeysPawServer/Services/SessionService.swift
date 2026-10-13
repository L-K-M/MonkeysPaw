import Foundation
import MonkeysPawCore

struct SessionIdentity: Sendable, Equatable {
    let userID: String
    let deviceID: String
}

struct IssuedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let token: DeviceToken
    let user: SyncAPI.User
    let identity: SessionIdentity
    var description: String { "IssuedSession(<redacted>)" }
    var debugDescription: String { description }
    var response: SyncAPI.AuthResponse { .init(deviceToken: token.value, user: user) }
}

struct SessionService: Sendable {
    let repository: AccountRepository
    let clock: @Sendable () -> Date

    init(database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        repository = AccountRepository(database: database)
        self.clock = clock
    }

    /// Rechecking the verified hash prevents login racing a password reset.
    func issueSession(for verified: VerifiedAccount, deviceName: String) async throws -> IssuedSession {
        guard (1...255).contains(deviceName.unicodeScalars.count) else { throw AccountError.malformedRequest }
        let token = DeviceToken.generate()
        return try await repository.write { accounts, devices in
            guard let current = try await accounts.user(id: verified.user.id), current.disabledAt == nil,
                  current.passwordHash == verified.user.passwordHash else { throw AccountError.unauthorized }
            let now = clock()
            let id = try ServerTimestamp.id(at: now)
            let timestamp = ServerTimestamp.string(now)
            try await devices.insert(.init(id: id, userID: current.id, name: deviceName, tokenHash: token.hash,
                                           createdAt: timestamp, lastSeenAt: timestamp, revokedAt: nil))
            return IssuedSession(token: token, user: current.metadata,
                                 identity: .init(userID: current.id, deviceID: id))
        }
    }

    func authenticate(token value: String) async throws -> SessionIdentity {
        let token = DeviceToken(value: value)
        guard token.isValid else { throw AccountError.unauthorized }
        let device = try await repository.read { accounts, devices in
            try await Self.resolve(tokenHash: token.hash, accounts: accounts, devices: devices)
        }
        let identity = SessionIdentity(userID: device.userID, deviceID: device.id)
        if try needsSeenUpdate(device, at: clock()) {
            try await repository.write { accounts, devices in
                let current = try await Self.resolve(tokenHash: token.hash, accounts: accounts, devices: devices)
                let now = clock()
                guard try needsSeenUpdate(current, at: now) else { return }
                try await devices.markSeen(id: current.id, at: ServerTimestamp.string(now),
                                          cutoff: ServerTimestamp.string(now.addingTimeInterval(-ServerLimits.deviceSeenUpdateInterval)))
            }
        }
        return identity
    }

    func logout(_ session: SessionIdentity) async throws {
        try await revokeDevice(id: session.deviceID, session: session)
    }

    func revokeDevice(id: String, session: SessionIdentity) async throws {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try await repository.write { accounts, devices in
            _ = try await Self.requireSession(session, accounts: accounts, devices: devices)
            guard let target = try await devices.device(id: id), target.userID == session.userID else {
                throw AccountError.notFound
            }
            try await devices.revoke(id: target.id, userID: session.userID, at: ServerTimestamp.string(clock()))
        }
    }

    /// Every service calls this within the transaction that owns its mutation.
    static func requireSession(
        _ identity: SessionIdentity, accounts: AccountRepository.Transaction, devices: DeviceRepository
    ) async throws -> AccountRecord {
        guard let device = try await devices.device(id: identity.deviceID), device.userID == identity.userID,
              device.revokedAt == nil, let user = try await accounts.user(id: identity.userID),
              user.disabledAt == nil else { throw AccountError.unauthorized }
        return user
    }

    private static func resolve(
        tokenHash: String, accounts: AccountRepository.Transaction, devices: DeviceRepository
    ) async throws -> DeviceRecord {
        guard let device = try await devices.device(tokenHash: tokenHash), device.revokedAt == nil,
              let user = try await accounts.user(id: device.userID), user.disabledAt == nil else {
            throw AccountError.unauthorized
        }
        return device
    }

    private func needsSeenUpdate(_ device: DeviceRecord, at now: Date) throws -> Bool {
        guard let value = device.lastSeenAt else { return true }
        guard let seen = ServerTimestamp.date(value) else { throw PersistenceError.invalidAccountRecord }
        return now.timeIntervalSince(seen) >= ServerLimits.deviceSeenUpdateInterval
    }
}
