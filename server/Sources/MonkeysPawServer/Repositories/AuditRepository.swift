import Foundation
import MonkeysPawCore
import SQLKit

enum AuditAction: String, Sendable, CaseIterable {
    case userCreate = "user.create"
    case userUpdate = "user.update"
    case userDisable = "user.disable"
    case userEnable = "user.enable"
    case userResetPassword = "user.reset_password"
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
    let at: String

    init(actor: AuditActor, action: AuditAction, targetID: String, at date: Date) throws {
        if let id = actor.userID { try AccountValidation.dto(SyncAPI.IDPath(id: id)) }
        try AccountValidation.dto(SyncAPI.IDPath(id: targetID))
        id = try ServerTimestamp.id(at: date)
        self.actor = actor
        self.action = action
        self.targetID = targetID
        at = ServerTimestamp.string(date)
    }
}

/// Reuse the mutation's SQL session; an audit insert never opens its own write.
struct AuditRepository: Sendable {
    let sql: any SQLDatabase

    func insert(_ event: AuditEvent) async throws {
        try await sql.raw("""
            INSERT INTO audit_events (id, actor_id, action, target, at)
            VALUES (\(bind: event.id), \(bind: event.actor.userID), \(bind: event.action.rawValue),
                    \(bind: event.targetID), \(bind: event.at))
            """).run()
    }
}
