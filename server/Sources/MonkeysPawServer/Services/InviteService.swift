import Foundation
import MonkeysPawCore

struct IssuedInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let response: SyncAPI.InviteResponse
    let link: String?
    var description: String { "IssuedInvite(<redacted>)" }
    var debugDescription: String { description }
}

struct InviteSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: DeviceToken
    let expiresAt: String
    let link: String?
    var description: String { "InviteSecret(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct InviteService: Sendable {
    private let repository: InviteRepository
    private let passwords: any PasswordHashing
    private let sessions: SessionService
    private let clock: @Sendable () -> Date
    private let publicURL: String?
    private let auditWrite: @Sendable (AuditRepository, AuditEvent) async throws -> Void

    init(
        accounts: AccountService, sessions: SessionService, publicURL: String? = nil,
        auditWrite: @escaping @Sendable (AuditRepository, AuditEvent) async throws -> Void = { try await $0.insert($1) }
    ) {
        repository = InviteRepository(database: accounts.repository.database)
        passwords = accounts.passwords
        clock = accounts.clock
        self.sessions = sessions
        self.publicURL = publicURL
        self.auditWrite = auditWrite
    }

    func createGroup(id: String, request: SyncAPI.GroupInviteRequest, session: SessionIdentity) async throws -> IssuedInvite {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(request)
        let target = SyncAPI.InviteTarget.group(groupID: id, role: request.role)
        let secret = try await create(target: Self.storedTarget(target), expiresIn: request.expiresIn, authority: .ownerOrAdmin(session))
        return .init(response: .init(inviteToken: secret.token.value, expiresAt: secret.expiresAt, target: target), link: secret.link)
    }

    func createAdmin(_ request: SyncAPI.AdminInviteRequest, session: SessionIdentity) async throws -> IssuedInvite {
        try AccountValidation.dto(request)
        let secret = try await create(target: Self.storedTarget(request.target), expiresIn: request.expiresIn, authority: .admin(session))
        return .init(response: .init(inviteToken: secret.token.value, expiresAt: secret.expiresAt, target: request.target), link: secret.link)
    }

    func createOperator(target: InviteRecord.Target, issuerID: String, expiresIn: Int64?) async throws -> InviteSecret {
        try AccountValidation.dto(SyncAPI.IDPath(id: issuerID))
        return try await create(target: target, expiresIn: expiresIn, authority: .cliOperator(issuerID: issuerID))
    }

    func register(_ request: SyncAPI.RegisterRequest) async throws -> IssuedSession {
        try AccountValidation.dto(request)
        let username = try AccountValidation.username(request.username)
        try AccountValidation.newPassword(request.password)
        let tokenHash = DeviceToken(value: request.inviteToken).hash
        // Invalid invites do no bcrypt work; the writer rechecks after hashing.
        try await repository.read { invites, groups in
            let invite = try await Self.requireInvite(tokenHash: tokenHash, at: clock(), invites: invites)
            if case .group(let id, _) = invite.target {
                guard try await groups.group(id: id) != nil else { throw AccountError.notFound }
            }
        }
        let hash = try await passwords.hash(request.password)
        return try await repository.write { invites, accounts, devices, groups, audit in
            let now = clock()
            let invite = try await Self.requireInvite(tokenHash: tokenHash, at: now, invites: invites)
            if case .group(let id, _) = invite.target {
                guard try await groups.group(id: id) != nil else { throw AccountError.notFound }
            }
            let timestamp = ServerTimestamp.string(now)
            try await invites.consume(tokenHash: tokenHash, at: timestamp)
            guard try await accounts.user(username: username) == nil else { throw AccountError.malformedRequest }
            let user = try AccountRecord(id: ServerTimestamp.id(at: now), username: username, displayName: nil,
                                         passwordHash: hash, accountKind: .member, createdAt: timestamp, disabledAt: nil)
            try await accounts.insert(user)
            try await auditWrite(audit, AuditEvent(actor: .user(invite.createdBy), action: .userCreate, targetID: user.id, at: now))
            let groupID: String?
            switch invite.target {
            case .account: groupID = nil
            case .group(let id, let role):
                groupID = id
                try await groups.upsertMember(groupID: id, userID: user.id, role: role, at: timestamp)
                try await auditWrite(audit, AuditEvent(actor: .user(invite.createdBy), action: .membershipUpsert,
                                                      targetID: user.id, groupID: id, at: now))
            }
            let issued = try await sessions.issueSession(for: VerifiedAccount(user: user), deviceName: request.deviceName,
                                                        accounts: accounts, devices: devices)
            try await auditWrite(audit, AuditEvent(actor: .user(user.id), action: .inviteConsume, targetID: user.id, groupID: groupID, at: now))
            return issued
        }
    }

    func join(_ request: SyncAPI.JoinGroupRequest, session: SessionIdentity) async throws -> SyncAPI.GroupMembership {
        try AccountValidation.dto(request)
        let tokenHash = DeviceToken(value: request.inviteToken).hash
        return try await repository.write { invites, accounts, devices, groups, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let now = clock()
            let invite = try await Self.requireInvite(tokenHash: tokenHash, at: now, invites: invites)
            guard case .group(let id, let role) = invite.target else { throw AccountError.malformedRequest }
            guard let group = try await groups.group(id: id) else { throw AccountError.notFound }
            let current = try await groups.member(groupID: id, userID: actor.id)
            if actor.accountKind == .admin {
                guard let current, Self.rank(role) <= Self.rank(current.role) else { throw AccountError.forbidden }
            }
            // Joining never demotes an existing member, including the last owner.
            let effectiveRole = current.map { Self.rank($0.role) > Self.rank(role) ? $0.role : role } ?? role
            try await invites.consume(tokenHash: tokenHash, at: ServerTimestamp.string(now))
            try await groups.upsertMember(groupID: id, userID: actor.id, role: effectiveRole,
                                          at: current?.joinedAt ?? ServerTimestamp.string(now))
            try await auditWrite(audit, AuditEvent(actor: .user(invite.createdBy), action: .membershipUpsert,
                                                  targetID: actor.id, groupID: id, at: now))
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .inviteConsume, targetID: actor.id, groupID: id, at: now))
            return .init(groupID: id, name: group.name, role: effectiveRole)
        }
    }

    private enum Authority: Sendable {
        case ownerOrAdmin(SessionIdentity)
        case admin(SessionIdentity)
        case cliOperator(issuerID: String)
    }

    private static func storedTarget(_ target: SyncAPI.InviteTarget) -> InviteRecord.Target {
        switch target {
        case .account: return .account
        case .group(let id, let role): return .group(groupID: id, role: role == .editor ? .editor : .viewer)
        }
    }

    private func create(
        target: InviteRecord.Target, expiresIn: Int64?, authority: Authority
    ) async throws -> InviteSecret {
        if let expiresIn, !(1...ServerLimits.inviteMaximumLifetimeSeconds).contains(expiresIn) {
            throw AccountError.malformedRequest
        }
        if case .group(let id, _) = target { try AccountValidation.dto(SyncAPI.IDPath(id: id)) }

        return try await repository.write { invites, accounts, devices, groups, audit in
            let issuer: AccountRecord
            let actor: AuditActor
            switch authority {
            case .ownerOrAdmin(let session):
                issuer = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
                actor = .user(issuer.id)
            case .admin(let session):
                issuer = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
                guard issuer.accountKind == .admin else { throw AccountError.forbidden }
                actor = .user(issuer.id)
            case .cliOperator(let issuerID):
                guard let user = try await accounts.user(id: issuerID) else { throw AccountError.notFound }
                guard user.disabledAt == nil, user.accountKind == .admin else { throw AccountError.forbidden }
                issuer = user
                actor = .cliOperator
            }
            let groupID: String?
            switch target {
            case .account: groupID = nil
            case .group(let id, _):
                guard try await groups.group(id: id) != nil else { throw AccountError.notFound }
                if issuer.accountKind != .admin {
                    guard let member = try await groups.member(groupID: id, userID: issuer.id) else { throw AccountError.notFound }
                    guard member.role == .owner else { throw AccountError.forbidden }
                }
                groupID = id
            }
            let now = clock()
            let expiresAt = ServerTimestamp.string(now.addingTimeInterval(TimeInterval(expiresIn ?? ServerLimits.inviteMaximumLifetimeSeconds)))
            // Invites use the same 32-byte CSPRNG/base64url/SHA-256 primitive as devices.
            let token = DeviceToken.generate()
            let link = try publicURL.map { try InviteLink.make(publicURL: $0, token: token.value) }
            try await invites.insert(.init(tokenHash: token.hash, target: target, createdBy: issuer.id, expiresAt: expiresAt, consumedAt: nil))
            try await auditWrite(audit, AuditEvent(actor: actor, action: .inviteCreate,
                                                  targetID: groupID ?? issuer.id, groupID: groupID, at: now))
            return .init(token: token, expiresAt: expiresAt, link: link)
        }
    }

    private static func requireInvite(
        tokenHash: String, at now: Date, invites: InviteRepository.Transaction
    ) async throws -> InviteRecord {
        guard let invite = try await invites.invite(tokenHash: tokenHash), invite.consumedAt == nil else { throw AccountError.malformedRequest }
        guard let expiry = ServerTimestamp.date(invite.expiresAt) else { throw PersistenceError.invalidAccountRecord }
        guard expiry > now else { throw AccountError.malformedRequest }
        return invite
    }

    private static func rank(_ role: SyncAPI.Role) -> Int {
        switch role {
        case .viewer: return 0
        case .editor: return 1
        case .owner: return 2
        }
    }
}
