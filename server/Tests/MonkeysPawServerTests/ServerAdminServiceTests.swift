import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminServiceTests {
    @Test func failedAuditInsertRollsBackCreationAndCombinedPatchIncludingRevocations() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let session = try await fixture.session(actor)
            let targetSession = try await fixture.session(target)
            let otherDevice = try await fixture.session(target)
            try await fixture.persistence.seedAccountData(target)
            let failing = AdminUserService(accounts: fixture.accounts) { audit, event in
                try await audit.insert(event)
                if event.action == .userCreate || event.action == .userDisable { throw InjectedAuditError.failure }
            }
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failing.create(.init(username: "rollback", password: AccountTestFixture.password), session: session.identity)
            }
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("audit_events") == 0)
            let request = SyncAPI.UpdateUserRequest(displayName: .value("Uncommitted"), password: "replacement-password",
                                                    disabled: true, accountKind: .admin)
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failing.update(id: target.id, request: request, session: session.identity)
            }
            let preserved = try await fixture.accounts.repository.read { accounts, devices in
                let user = try await accounts.user(id: target.id)
                let ownDevices = try await devices.list(userID: target.id)
                return user?.metadata == target.metadata && user?.passwordHash == target.passwordHash
                    && ownDevices.allSatisfy { $0.revokedAt == nil }
            }
            #expect(preserved)
            #expect(try await fixture.persistence.count("audit_events") == 0)
            #expect(try await fixture.persistence.count("prompts") == 1)
            #expect(try await fixture.persistence.count("memberships") == 1)
            #expect(try await fixture.sessions.authenticate(token: targetSession.token.value) == targetSession.identity)
            #expect(try await fixture.sessions.authenticate(token: otherDevice.token.value) == otherDevice.identity)
            let service = AdminUserService(accounts: fixture.accounts)
            let committed = try await service.update(id: target.id, request: request, session: session.identity)
            #expect(committed.displayName == "Uncommitted" && committed.accountKind == .admin && committed.disabledAt != nil)
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["user.update", "user.reset_password", "user.disable"])
            #expect(Set(events.map(\.id)).count == 3)
            for event in events {
                #expect(event.actorID == actor.id && event.targetID == target.id)
                #expect(event.at == ServerTimestamp.string(fixture.clock.now()))
                #expect(ULID(event.id)?.rawValue == event.id)
            }
            try await fixture.assertNoPlaintext([AccountTestFixture.password, "replacement-password", targetSession.token.value])
        }
    }

    @Test(arguments: ["revoke", "disable", "demote"])
    func bcryptRechecksAdminAuthorityAndDoesNotHoldTheWriter(change: String) async throws {
        for operation in ["create", "reset"] {
            try await withAccountFixture { fixture in
                let actor = try await fixture.user(username: "admin", kind: .admin)
                let target = try await fixture.user()
                let session = try await fixture.session(actor)
                let entered = LoginTestLatch()
                let release = LoginTestLatch()
                let hasher = AdminTestHasher(entered: entered, release: release)
                let accounts = AccountService(database: fixture.persistence.database, passwords: hasher, clock: fixture.clock.now)
                let service = AdminUserService(accounts: accounts)
                let task = Task {
                    if operation == "create" {
                        return try await service.create(.init(username: "new-user", password: AccountTestFixture.password), session: session.identity)
                    }
                    return try await service.update(id: target.id, request: .init(password: "replacement-password"), session: session.identity)
                }
                await entered.wait()
                switch change {
                case "revoke": try await fixture.sessions.logout(session.identity)
                case "disable": try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)")
                default: try await fixture.persistence.execute("UPDATE users SET account_kind = 'member' WHERE id = \(bind: actor.id)")
                }
                await release.open()
                await #expect(throws: change == "demote" ? AccountError.forbidden : AccountError.unauthorized) { _ = try await task.value }
                #expect(try await fixture.persistence.count("users") == 2)
                #expect(try await fixture.persistence.count("audit_events") == 0)
                let unchanged = try await fixture.accounts.repository.read { accounts, _ in
                    try await accounts.user(id: target.id)?.passwordHash == target.passwordHash
                }
                #expect(unchanged)
            }
        }
    }

    @Test func omittedPatchFieldsPreserveConcurrentTargetChanges() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let session = try await fixture.session(actor)
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let service = AdminUserService(accounts: .init(database: fixture.persistence.database,
                passwords: AdminTestHasher(entered: entered, release: release), clock: fixture.clock.now))
            let task = Task {
                try await service.update(id: target.id, request: .init(password: "replacement-password"), session: session.identity)
            }
            await entered.wait()
            let newer = try await AdminUserService(accounts: fixture.accounts).update(id: target.id,
                request: .init(displayName: .value("Newer metadata"), disabled: true, accountKind: .admin), session: session.identity)
            await release.open()
            let result = try await task.value
            #expect(result == newer)
            let changed = try await fixture.accounts.repository.read { accounts, _ in
                try await accounts.user(id: target.id)?.passwordHash != target.passwordHash
            }
            #expect(changed)
        }
    }

    @Test func membersCannotStartBcryptAndConcurrentCanonicalCreatesHaveOneWinner() async throws {
        try await withAccountFixture { fixture in
            let member = try await fixture.user()
            let session = try await fixture.session(member)
            let hasher = AdminTestHasher()
            let service = AdminUserService(accounts: .init(database: fixture.persistence.database, passwords: hasher))
            await #expect(throws: AccountError.forbidden) {
                _ = try await service.create(.init(username: "denied", password: AccountTestFixture.password), session: session.identity)
            }
            await #expect(throws: AccountError.forbidden) {
                _ = try await service.update(id: member.id, request: .init(password: "replacement-password"), session: session.identity)
            }
            #expect(await hasher.hashes() == 0)
            let admin = try await fixture.user(username: "admin", kind: .admin)
            let adminSession = try await fixture.session(admin)
            let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
                for username in ["race", "race"] {
                    group.addTask {
                        do {
                            _ = try await service.create(.init(username: username, password: AccountTestFixture.password), session: adminSession.identity)
                            return true
                        } catch AccountError.malformedRequest { return false }
                    }
                }
                var count = 0
                for try await success in group { if success { count += 1 } }
                return count
            }
            #expect(successes == 1)
            #expect(try await fixture.persistence.count("users") == 3)
            #expect(try await fixture.persistence.count("audit_events") == 1)
        }
    }

    @Test func auditHasStableActionsUTCAndAnExplicitOperatorActor() async throws {
        #expect(AuditAction.allCases.map(\.rawValue) == ["user.create", "user.update", "user.disable", "user.enable", "user.reset_password"])
        try await withAccountFixture { fixture in
            let target = try await fixture.user()
            let event = try AuditEvent(actor: .cliOperator, action: .userCreate, targetID: target.id, at: fixture.clock.now())
            try await fixture.accounts.repository.writeAudited { _, _, audit in try await audit.insert(event) }
            let stored = try #require(await fixture.persistence.auditEvents().first)
            #expect(stored.actorID == nil && stored.targetID == target.id && stored.at == event.at)
            #expect(event.at.hasSuffix(".000Z"))
            #expect(throws: (any Error).self) {
                _ = try AuditEvent(actor: .cliOperator, action: .userCreate, targetID: "credential-sentinel", at: fixture.clock.now())
            }
        }
    }
}
