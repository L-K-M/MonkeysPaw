import Foundation
import MonkeysPawCore

/// §26 S1/S5: the server persists opaque encrypted documents under an
/// account-scoped revision; it never inspects or decrypts the payload.
struct ProviderSettingsService: Sendable {
    private let repository: ProviderSettingsRepository
    private let clock: @Sendable () -> Date

    init(database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        repository = ProviderSettingsRepository(database: database)
        self.clock = clock
    }

    func document(session: SessionIdentity) async throws -> SyncAPI.ProviderSettingsDocument {
        try await repository.read { settings, accounts, devices in
            let user = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard let record = try await settings.record(userID: user.id) else {
                return .init(rev: 0, document: nil, updatedAt: nil)
            }
            return .init(rev: record.rev, document: record.document, updatedAt: record.updatedAt)
        }
    }

    func put(_ request: SyncAPI.PutProviderSettingsRequest, session: SessionIdentity) async throws -> SyncAPI.ProviderSettingsResponse {
        try AccountValidation.dto(request)
        return try await repository.write { settings, accounts, devices in
            let user = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let record = try await settings.upsert(userID: user.id, document: request.document,
                                                   at: ServerTimestamp.string(clock()))
            return .init(rev: record.rev)
        }
    }
}
