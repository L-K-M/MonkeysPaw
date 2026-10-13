import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminServiceTests {
    enum AuthorityChange: CaseIterable { case revoke, disable, demote }
    enum PasswordOperation: CaseIterable { case create, reset }

    @Test func hashLatchTimeoutIsBoundedAndAnOpenedLatchReturnsImmediately() async throws {
        let latch = LoginTestLatch()
        await #expect(throws: LoginTestLatch.WaitError.timeout) { try await latch.wait(timeout: .milliseconds(1)) }
        await latch.open()
        try await latch.wait(timeout: .zero)
    }

    @Test(arguments: [SyncAPI.UpdateUserRequest(disabled: true), .init(accountKind: .member),
                       .init(displayName: .value("Uncommitted"), password: "replacement-password",
                             disabled: true, accountKind: .member)])
    func lastActiveAdminRemovalIsForbiddenAndAtomic(request: SyncAPI.UpdateUserRequest) async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let disabled = try await fixture.user(username: "disabled-admin", kind: .admin)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: disabled.id)")
            let session = try await fixture.session(actor)
            let other = try await fixture.session(actor)
            let logs = CapturedServerLogs()
            let service = AdminUserService(accounts: fixture.accounts,
                logger: ServerLogging.makeLogger(level: .trace, sink: logs.write))
            await #expect(throws: AccountError.forbidden) {
                _ = try await service.update(id: actor.id, request: request, session: session.identity)
            }
            let unchanged = try await fixture.accounts.repository.read { accounts, devices in
                let user = try await accounts.user(id: actor.id)
                let active = try await devices.list(userID: actor.id)
                return user?.metadata == actor.metadata && user?.passwordHash == actor.passwordHash
                    && active.count == 2 && active.allSatisfy { $0.revokedAt == nil }
            }
            #expect(unchanged)
            #expect(try await fixture.sessions.authenticate(token: session.token.value) == session.identity)
            #expect(try await fixture.sessions.authenticate(token: other.token.value) == other.identity)
            #expect(try await fixture.persistence.count("audit_events") == 0)
            #expect(logs.snapshot().isEmpty)
        }
    }

    @Test(arguments: [SyncAPI.UpdateUserRequest(password: "replacement-password", disabled: true),
                       .init(password: "replacement-password", accountKind: .member)])
    func concurrentAdminRemovalsKeepOneActiveAdmin(request: SyncAPI.UpdateUserRequest) async throws {
        try await withAccountFixture { fixture in
            let first = try await fixture.user(username: "first-admin", kind: .admin)
            let second = try await fixture.user(username: "second-admin", kind: .admin)
            let firstSession = try await fixture.session(first)
            let secondSession = try await fixture.session(second)
            let firstEntered = LoginTestLatch()
            let secondEntered = LoginTestLatch()
            let release = LoginTestLatch()
            let services = [firstEntered, secondEntered].map {
                AdminUserService(accounts: .init(database: fixture.persistence.database,
                    passwords: AdminTestHasher(entered: $0, release: release), clock: fixture.clock.now))
            }
            let sessions = [firstSession, secondSession]
            let removals = Task {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    for index in services.indices {
                        group.addTask {
                            do {
                                _ = try await services[index].update(id: sessions[index].identity.userID,
                                    request: request, session: sessions[index].identity)
                                return true
                            } catch AccountError.forbidden { return false }
                        }
                    }
                    var successes = 0
                    for try await success in group { if success { successes += 1 } }
                    return successes
                }
            }
            // Both requests have read their authority before either may reach the writer.
            do {
                try await firstEntered.wait(timeout: .seconds(10))
                try await secondEntered.wait(timeout: .seconds(10))
            } catch {
                await release.open()
                removals.cancel()
                _ = try? await removals.value
                throw error
            }
            await release.open()
            #expect(try await removals.value == 1)
            let remaining = try await fixture.accounts.repository.read { accounts, devices in
                var active = 0
                for (user, session) in [(first, firstSession), (second, secondSession)] {
                    let current = try #require(await accounts.user(id: user.id))
                    if current.accountKind == .admin && current.disabledAt == nil {
                        active += 1
                        #expect(current.metadata == user.metadata && current.passwordHash == user.passwordHash)
                        #expect(try await devices.device(id: session.identity.deviceID)?.revokedAt == nil)
                    }
                }
                return active
            }
            #expect(remaining == 1)
            #expect(try await fixture.persistence.count("audit_events") == 2)
        }
    }

    @Test func auditAndSuccessLogsDescribeChangesRatherThanNoOps() async throws {
        try await withAccountFixture { fixture in
            let actor = try await fixture.user(username: "admin", kind: .admin)
            let target = try await fixture.user()
            let session = try await fixture.session(actor)
            let device = try await fixture.session(target)
            let logs = CapturedServerLogs()
            let service = AdminUserService(accounts: fixture.accounts,
                logger: ServerLogging.makeLogger(level: .trace, sink: logs.write))
            let unchanged = try await service.update(id: target.id,
                request: .init(displayName: .null, disabled: false, accountKind: .member), session: session.identity)
            #expect(unchanged == target.metadata)
            #expect(try await fixture.persistence.count("audit_events") == 0)
            #expect(logs.snapshot().isEmpty)
            #expect(try await fixture.sessions.authenticate(token: device.token.value) == device.identity)
            let disabled = try await service.update(id: target.id,
                request: .init(displayName: .value("Changed"), disabled: true), session: session.identity)
            fixture.clock.advance(60)
            #expect(try await service.update(id: target.id,
                request: .init(displayName: .value("Changed"), disabled: true), session: session.identity) == disabled)
            #expect(try await fixture.persistence.auditEvents().map(\.action) == ["user.update", "user.disable"])
            for _ in 0..<2 {
                _ = try await service.update(id: target.id, request: .init(disabled: false), session: session.identity)
            }
            // A reset to the same plaintext still changes the salted hash and revokes sessions.
            _ = try await service.update(id: target.id, request: .init(password: AccountTestFixture.password), session: session.identity)
            let actions = try await fixture.persistence.auditEvents().map(\.action)
            #expect(actions == ["user.update", "user.disable", "user.enable", "user.reset_password"])
            #expect(try logs.events().map { $0.fields["action"] } == actions)
        }
    }

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

    @Test(arguments: AuthorityChange.allCases, PasswordOperation.allCases)
    func bcryptRechecksAdminAuthorityAndDoesNotHoldTheWriter(change: AuthorityChange, operation: PasswordOperation) async throws {
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
                if operation == .create {
                    return try await service.create(.init(username: "new-user", password: AccountTestFixture.password), session: session.identity)
                }
                return try await service.update(id: target.id, request: .init(password: "replacement-password"), session: session.identity)
            }
            do {
                try await entered.wait(timeout: .seconds(10))
            } catch {
                await release.open()
                task.cancel()
                _ = try? await task.value
                throw error
            }
            switch change {
            case .revoke: try await fixture.sessions.logout(session.identity)
            case .disable: try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)")
            case .demote: try await fixture.persistence.execute("UPDATE users SET account_kind = 'member' WHERE id = \(bind: actor.id)")
            }
            await release.open()
            await #expect(throws: change == .demote ? AccountError.forbidden : AccountError.unauthorized) { _ = try await task.value }
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("audit_events") == 0)
            let unchanged = try await fixture.accounts.repository.read { accounts, _ in
                try await accounts.user(id: target.id)?.passwordHash == target.passwordHash
            }
            #expect(unchanged)
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
            do {
                try await entered.wait(timeout: .seconds(10))
            } catch {
                await release.open()
                task.cancel()
                _ = try? await task.value
                throw error
            }
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
        #expect(AuditAction.allCases.map(\.rawValue) == [
            "user.create", "user.update", "user.disable", "user.enable", "user.reset_password",
            "group.create", "group.rename", "group.delete", "membership.upsert", "membership.remove"
        ])
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
