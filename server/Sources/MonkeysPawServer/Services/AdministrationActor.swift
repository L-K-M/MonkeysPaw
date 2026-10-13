import Foundation

/// The local database operator is explicit authority, never a fabricated HTTP session.
enum AdministrationActor: Sendable {
    case session(SessionIdentity)
    case cliOperator

    var auditActor: AuditActor {
        switch self {
        case .session(let session): return .user(session.userID)
        case .cliOperator: return .cliOperator
        }
    }

    func requireAdmin(accounts: AccountRepository.Transaction, devices: DeviceRepository) async throws {
        // Only the local CLI entry path constructs .cliOperator, never HTTP request state.
        guard case .session(let session) = self else { return }
        let user = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
        guard user.accountKind == .admin else { throw AccountError.forbidden }
    }
}
