import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

// Race/rollback tests skip bcrypt; HTTP registration separately exercises cost 12.
actor InviteTestHasher: PasswordHashing {
    private let entered: LoginTestLatch?
    private let release: LoginTestLatch?
    private var count = 0

    init(entered: LoginTestLatch? = nil, release: LoginTestLatch? = nil) {
        self.entered = entered
        self.release = release
    }

    func hash(_ password: String) async throws -> String {
        count += 1
        await entered?.open()
        await release?.wait()
        return "invite-fixture-hash"
    }

    func verify(_ password: String, hash: String) async throws -> Bool {
        Issue.record("Invite redemption must not verify an account password")
        return false
    }

    func hashes() -> Int { count }
}

extension GroupTestFixture {
    func inviteService(
        passwords: any PasswordHashing = InviteTestHasher(),
        publicURL: String? = "https://sync.example.test:8443/paw?value=a+b&next=%2F",
        auditWrite: @escaping @Sendable (AuditRepository, AuditEvent) async throws -> Void = { try await $0.insert($1) }
    ) -> InviteService {
        .init(accounts: .init(database: persistence.database, passwords: passwords, clock: account.clock.now),
              sessions: account.sessions, publicURL: publicURL, auditWrite: auditWrite)
    }
}

extension PersistenceTestRepository {
    func storedInvite(_ token: String) async throws -> InviteRecord {
        let hash = DeviceToken(value: token).hash
        return try await InviteRepository(database: database).read { invites, _ in
            try #require(await invites.invite(tokenHash: hash))
        }
    }
}
