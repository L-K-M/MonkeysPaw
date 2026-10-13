import Foundation
import MonkeysPawCore

struct GroupService: Sendable {
    private let repository: GroupRepository
    private let clock: @Sendable () -> Date
    private let auditWrite: @Sendable (AuditRepository, AuditEvent) async throws -> Void

    init(
        database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() },
        auditWrite: @escaping @Sendable (AuditRepository, AuditEvent) async throws -> Void = { try await $0.insert($1) }
    ) {
        repository = GroupRepository(database: database)
        self.clock = clock
        self.auditWrite = auditWrite
    }

    func create(_ request: SyncAPI.CreateGroupRequest, session: SessionIdentity) async throws -> SyncAPI.Group {
        try AccountValidation.dto(request)
        return try await repository.write { groups, accounts, devices, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let now = clock()
            let group = try SyncAPI.Group(id: ServerTimestamp.id(at: now), name: request.name,
                                          createdBy: actor.id, createdAt: ServerTimestamp.string(now))
            try await groups.insert(group)
            // New-group creation is the sole automatic-owner exception for admins.
            try await groups.upsertMember(groupID: group.id, userID: actor.id, role: .owner, at: group.createdAt)
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .groupCreate, targetID: group.id, at: now))
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .membershipUpsert, targetID: actor.id, groupID: group.id, at: now))
            return group
        }
    }

    func rename(id: String, request: SyncAPI.RenameGroupRequest, session: SessionIdentity) async throws -> SyncAPI.Group {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(request)
        return try await repository.write { groups, accounts, devices, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let group = try await Self.requireGroup(id: id, actor: actor, groups: groups, access: .manage)
            try await groups.rename(id: id, name: request.name)
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .groupRename, targetID: id, at: clock()))
            return .init(id: group.id, name: request.name, createdBy: group.createdBy, createdAt: group.createdAt)
        }
    }

    func delete(id: String, session: SessionIdentity) async throws {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try await repository.write { groups, accounts, devices, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            _ = try await Self.requireGroup(id: id, actor: actor, groups: groups, access: .manage)
            let members = try await groups.members(groupID: id)
            let now = clock()
            try await groups.delete(id: id, actorID: actor.id, at: ServerTimestamp.string(now))
            for member in members {
                try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .membershipRemove,
                                                      targetID: member.userID, groupID: id, at: now))
            }
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .groupDelete, targetID: id, at: now))
        }
    }

    func members(id: String, session: SessionIdentity) async throws -> SyncAPI.MembersResponse {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        return try await repository.read { groups, accounts, devices in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            _ = try await Self.requireGroup(id: id, actor: actor, groups: groups, access: .inspect)
            return try await .init(members: groups.members(groupID: id))
        }
    }

    func upsertMember(
        id: String, userID: String, request: SyncAPI.MembershipRequest, session: SessionIdentity
    ) async throws -> SyncAPI.Member {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(SyncAPI.IDPath(id: userID))
        try AccountValidation.dto(request)
        return try await repository.write { groups, accounts, devices, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            _ = try await Self.requireGroup(id: id, actor: actor, groups: groups, access: .manage)
            let current = try await groups.member(groupID: id, userID: userID)
            if actor.id == userID, actor.accountKind == .admin {
                guard let current, Self.rank(request.role) <= Self.rank(current.role) else { throw AccountError.forbidden }
            }
            guard let user = try await accounts.user(id: userID) else { throw AccountError.notFound }
            if current?.role == .owner && request.role != .owner {
                try await Self.requireAnotherOwner(groupID: id, groups: groups)
            }
            let now = clock()
            let joinedAt = current?.joinedAt ?? ServerTimestamp.string(now)
            try await groups.upsertMember(groupID: id, userID: userID, role: request.role, at: joinedAt)
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .membershipUpsert, targetID: userID, groupID: id, at: now))
            return .init(userID: user.id, username: user.username, displayName: user.displayName, role: request.role, joinedAt: joinedAt)
        }
    }

    func removeMember(id: String, userID: String, session: SessionIdentity) async throws {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(SyncAPI.IDPath(id: userID))
        try await repository.write { groups, accounts, devices, audit in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            _ = try await Self.requireGroup(id: id, actor: actor, groups: groups, access: .manage)
            guard let current = try await groups.member(groupID: id, userID: userID) else { throw AccountError.notFound }
            if current.role == .owner { try await Self.requireAnotherOwner(groupID: id, groups: groups) }
            try await groups.removeMember(groupID: id, userID: userID)
            try await auditWrite(audit, AuditEvent(actor: .user(actor.id), action: .membershipRemove, targetID: userID, groupID: id, at: clock()))
        }
    }

    private enum Access { case inspect, manage }

    private static func requireGroup(
        id: String, actor: AccountRecord, groups: GroupRepository.Transaction, access: Access
    ) async throws -> SyncAPI.Group {
        guard let group = try await groups.group(id: id) else { throw AccountError.notFound }
        if actor.accountKind == .admin { return group }
        guard let member = try await groups.member(groupID: id, userID: actor.id) else { throw AccountError.notFound }
        if access == .manage && member.role != .owner { throw AccountError.forbidden }
        return group
    }

    private static func requireAnotherOwner(groupID: String, groups: GroupRepository.Transaction) async throws {
        guard try await groups.ownerCount(groupID: groupID) > 1 else { throw AccountError.forbidden }
    }

    private static func rank(_ role: SyncAPI.Role) -> Int {
        switch role {
        case .viewer: return 0
        case .editor: return 1
        case .owner: return 2
        }
    }
}
