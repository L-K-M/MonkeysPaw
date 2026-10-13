import Foundation
import MonkeysPawCore
import SQLKit

enum AuditAction: String, Sendable, CaseIterable {
    case userCreate = "user.create"
    case userUpdate = "user.update"
    case userDisable = "user.disable"
    case userEnable = "user.enable"
    case userResetPassword = "user.reset_password"
    case groupCreate = "group.create"
    case groupRename = "group.rename"
    case groupDelete = "group.delete"
    case membershipUpsert = "membership.upsert"
    case membershipRemove = "membership.remove"
    case inviteCreate = "invite.create"
    case inviteConsume = "invite.consume"
}

enum AuditActor: Sendable, Equatable {
    case user(String)
    case cliOperator

    var userID: String? {
        switch self {
        case .user(let id): return id
        case .cliOperator: return nil
        }
    }
}

struct AuditEvent: Sendable, Equatable {
    let id: String
    let actor: AuditActor
    let action: AuditAction
    let targetID: String
    let groupID: String?
    let at: String

    init(actor: AuditActor, action: AuditAction, targetID: String, groupID: String? = nil, at date: Date) throws {
        if let id = actor.userID { try AccountValidation.dto(SyncAPI.IDPath(id: id)) }
        try AccountValidation.dto(SyncAPI.IDPath(id: targetID))
        if let groupID { try AccountValidation.dto(SyncAPI.IDPath(id: groupID)) }
        id = try ServerTimestamp.id(at: date)
        self.actor = actor
        self.action = action
        self.targetID = targetID
        self.groupID = groupID
        at = ServerTimestamp.string(date)
    }
}

/// Reuse the mutation's SQL session; an audit insert never opens its own write.
struct AuditRepository: Sendable {
    let sql: any SQLDatabase

    func insert(_ event: AuditEvent) async throws {
        try await sql.raw("""
            INSERT INTO audit_events (id, actor_id, action, target, group_id, at)
            VALUES (\(bind: event.id), \(bind: event.actor.userID), \(bind: event.action.rawValue),
                    \(bind: event.targetID), \(bind: event.groupID), \(bind: event.at))
            """).run()
    }
}
