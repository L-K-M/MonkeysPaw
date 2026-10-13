import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerLoginTests {
    @Test func fifthFailureLocksBothBucketsWithoutDoingWorkDuringTheLock() async throws {
        try await withLoginFixture { fixture in
            for _ in 0..<4 { await fixture.failure() }
            let before = try await fixture.buckets()
            #expect(before.account.failures == 4 && before.ip.failures == 4)
            #expect(before.account.lockedUntil == nil && before.ip.lockedUntil == nil)
            await fixture.failure(retry: 30)
            let locked = try await fixture.buckets()
            #expect(locked.account.failures == 5 && locked.ip.failures == 5)
            fixture.account.clock.advance(0.001)
            for _ in 0..<4 { await fixture.failure(retry: 30) }
            let unchanged = try await fixture.buckets()
            #expect(unchanged.account.updatedAt == locked.account.updatedAt && unchanged.ip.updatedAt == locked.ip.updatedAt)
            #expect(unchanged.account.lockedUntil == locked.account.lockedUntil && unchanged.ip.lockedUntil == locked.ip.lockedUntil)
            #expect(await fixture.hasher.usedHashes().count == 5)
            #expect(try await fixture.account.persistence.count("devices") == 0)
        }
    }

    @Test func concurrentLockedRequestsReportThePersistedDelay() async throws {
        try await withLoginFixture { fixture in
            for _ in 0..<4 { await fixture.failure() }
            await fixture.failure(retry: 30)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 { group.addTask { await fixture.failure(retry: 30) } }
            }
            #expect(await fixture.hasher.usedHashes().count == 5)
        }
    }

    @Test func delaysDoubleAfterExpiryAndSaturateAtFifteenMinutes() async throws {
        try await withLoginFixture { fixture in
            for _ in 0..<4 { await fixture.failure() }
            for delay in [Int64(30), 60, 120, 240, 480, 900, 900] {
                await fixture.failure(retry: delay)
                fixture.account.clock.advance(Double(delay) - 0.001)
                await fixture.failure(retry: 1)
                fixture.account.clock.advance(0.001)
            }
            let pair = try await fixture.buckets()
            #expect(pair.account.failures == ServerLimits.loginMaximumFailures && pair.ip.failures == ServerLimits.loginMaximumFailures)
            #expect(await fixture.hasher.usedHashes().count == 11)
        }
    }

    @Test func successfulLoginResetsOnlyItsAccountAndCannotEraseIPHistory() async throws {
        try await withLoginFixture { fixture in
            let user = try await fixture.account.user()
            for _ in 0..<4 { await fixture.failure() }
            let before = try await fixture.buckets()
            let response = try await fixture.attempt(password: AccountTestFixture.password)
            #expect(response.user == user.metadata)
            let identity = try await fixture.account.sessions.authenticate(token: response.deviceToken)
            #expect(identity.userID == user.id)
            let after = try await fixture.buckets()
            #expect(after.account.failures == 0 && after.account.lockedUntil == nil)
            #expect(after.ip.failures == 4 && after.ip.updatedAt == before.ip.updatedAt)
            #expect(try await fixture.account.persistence.count("login_account_buckets") == 0)
            await fixture.failure(ip: "198.51.100.2")
            #expect(try await fixture.buckets(ip: "198.51.100.2").account.failures == 1)
            await fixture.failure(username: "other", retry: 30)
            await fixture.failure(password: AccountTestFixture.password, retry: 30)
            let final = try await fixture.buckets()
            #expect(final.account.failures == 1 && final.ip.failures == 5)
            try await fixture.account.assertNoPlaintext([response.deviceToken, AccountTestFixture.password])
        }
    }

    @Test func rotatedUsernamesAndIPsCannotBypassIndependentBuckets() async throws {
        try await withLoginFixture { fixture in
            for index in 1...5 {
                await fixture.failure(ip: "198.51.100.\(index)",
                                      retry: index == 5 ? 30 : nil)
            }
            await fixture.failure(ip: "198.51.100.99", retry: 30)
            let ipBuckets = try await fixture.account.persistence.count("login_ip_buckets")
            #expect(ipBuckets == 5)
            for index in 1...5 {
                await fixture.failure(username: "rotated\(index)", ip: "203.0.113.1", retry: index == 5 ? 30 : nil)
            }
            await fixture.failure(username: "fresh", ip: "203.0.113.1", retry: 30)
            #expect(try await fixture.account.persistence.count("login_account_buckets") == 6)
            #expect(await fixture.hasher.usedHashes().count == 10)
            // A fresh name and a fresh address are independent of both attacks.
            await fixture.failure(username: "fresh", ip: "203.0.113.2")
        }
    }

    @Test func quietDecayStartsAfterLockExpiryAndBlockedRequestsDoNotDelayIt() async throws {
        try await withLoginFixture { fixture in
            for _ in 0..<4 { await fixture.failure() }
            fixture.account.clock.advance(899.999)
            #expect(try await fixture.buckets().account.failures == 4)
            fixture.account.clock.advance(0.001)
            await fixture.failure()
            #expect(try await fixture.buckets().account.failures == 1)
            for _ in 0..<3 { await fixture.failure() }
            await fixture.failure(retry: 30)
            fixture.account.clock.advance(29)
            await fixture.failure(retry: 1)
            fixture.account.clock.advance(900.999)
            #expect(try await fixture.buckets().account.failures == 5)
            fixture.account.clock.advance(0.001)
            let decayed = try await fixture.buckets()
            #expect(decayed.account.failures == 0 && decayed.ip.failures == 0)
            await fixture.failure()
            #expect(try await fixture.buckets().account.failures == 1)
        }
    }

    @Test func longerIndependentLockWinsAndSuccessCannotResetAnActiveIPLock() async throws {
        try await withLoginFixture { fixture in
            _ = try await fixture.account.user()
            for index in 1...5 { await fixture.failure(ip: "198.51.100.\(index)", retry: index == 5 ? 30 : nil) }
            fixture.account.clock.advance(30)
            await fixture.failure(ip: "198.51.100.6", retry: 60)
            for index in 1...5 {
                await fixture.failure(username: "rotated\(index)", ip: "203.0.113.1", retry: index == 5 ? 30 : nil)
            }
            await fixture.failure(ip: "203.0.113.1", retry: 60)
            fixture.account.clock.advance(30)
            await fixture.failure(username: "fresh", ip: "203.0.113.1", retry: 60)
            await fixture.failure(ip: "203.0.113.1", retry: 60)
            fixture.account.clock.advance(30)
            _ = try await fixture.attempt(password: AccountTestFixture.password, ip: "198.51.100.99")
            await fixture.failure(password: AccountTestFixture.password, ip: "203.0.113.1", retry: 30)
            let pair = try await fixture.buckets(ip: "203.0.113.1")
            #expect(pair.account.failures == 0 && pair.ip.failures == 6)
        }
    }

    @Test func successfulLoginsDoNotPostponeIPDecay() async throws {
        try await withLoginFixture { fixture in
            _ = try await fixture.account.user()
            for _ in 0..<4 { await fixture.failure() }
            fixture.account.clock.advance(899.999)
            _ = try await fixture.attempt(password: AccountTestFixture.password)
            #expect(try await fixture.buckets().ip.failures == 4)
            fixture.account.clock.advance(0.001)
            #expect(try await fixture.buckets().ip.failures == 0)
            await fixture.failure(username: "another")
            #expect(try await fixture.buckets(username: "another").ip.failures == 1)
        }
    }

    @Test func accountAndIPLocksAndFailureStepsSurviveDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s7-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let clock = AccountTestClock()
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let accounts = AccountTestFixture(persistence: .init(database: database))
            _ = try await accounts.user()
            let service = LoginService(accounts: .init(database: database, passwords: LoginTestHasher(), clock: clock.now),
                                       sessions: .init(database: database, clock: clock.now))
            for index in 1...5 {
                do { _ = try await service.login(.init(username: "alice", password: "wrong", deviceName: "Test"), ip: ClientIPAddress("198.51.100.1")) }
                catch {
                    if index == 5 { #expect(error as? LoginError == .limited(30)) }
                    else { #expect(error as? AccountError == .unauthorized) }
                }
            }
        }
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let hasher = LoginTestHasher()
            let service = LoginService(accounts: .init(database: database, passwords: hasher, clock: clock.now),
                                       sessions: .init(database: database, clock: clock.now))
            let wrong = SyncAPI.LoginRequest(username: "alice", password: "wrong", deviceName: "Test")
            await #expect(throws: LoginError.limited(30)) {
                _ = try await service.login(wrong, ip: ClientIPAddress("198.51.100.2"))
            }
            await #expect(throws: LoginError.limited(30)) {
                _ = try await service.login(.init(username: "other", password: "wrong", deviceName: "Test"), ip: ClientIPAddress("198.51.100.1"))
            }
            #expect(await hasher.usedHashes().isEmpty)
            clock.advance(30)
            await #expect(throws: LoginError.limited(60)) {
                _ = try await service.login(wrong, ip: ClientIPAddress("198.51.100.2"))
            }
            await #expect(throws: LoginError.limited(60)) {
                _ = try await service.login(.init(username: "other", password: "wrong", deviceName: "Test"), ip: ClientIPAddress("198.51.100.1"))
            }
            clock.advance(60)
            _ = try await service.login(.init(username: "alice", password: AccountTestFixture.password, deviceName: "Restart"), ip: ClientIPAddress("198.51.100.3"))
        }
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let pair = try await LoginRepository(database: database).read {
                try await $0.buckets(username: "alice", ip: "198.51.100.1", at: clock.now())
            }
            #expect(pair.account.failures == 0 && pair.ip.failures == 6)
            #expect(try await PersistenceTestRepository(database: database).count("devices") == 1)
        }
    }

    @Test func unknownDisabledAndWrongPasswordAccountsEachPerformOneCostTwelveVerification() async throws {
        try await withAccountFixture { account in
            let user = try await account.user()
            let hasher = LoginTestHasher(mode: .bcrypt)
            let fixture = LoginTestFixture(account: account, hasher: hasher)
            await fixture.failure()
            await fixture.failure(username: "unknown", ip: "198.51.100.2")
            try await account.persistence.execute("UPDATE users SET disabled_at = created_at")
            await fixture.failure(password: AccountTestFixture.password, ip: "198.51.100.3")
            await fixture.failure(username: "unknown", password: String(repeating: "a", count: ServerLimits.passwordMaximumBytes), ip: "198.51.100.4")
            let hashes = await hasher.usedHashes()
            let equivalent = hashes == [user.passwordHash, BcryptPasswordHasher.dummyHash, user.passwordHash, BcryptPasswordHasher.dummyHash]
                && hashes.allSatisfy { $0.hasPrefix("$2b$12$") }
            #expect(equivalent)
            #expect(try await account.persistence.count("devices") == 0)
        }
    }

    @Test func uppercaseAndOversizedLoginValuesFailBeforeBackoffOrBcrypt() async throws {
        try await withLoginFixture { fixture async throws in
            for (username, password) in [("ALICE", AccountTestFixture.password),
                                         ("alice", String(repeating: "a", count: ServerLimits.passwordMaximumBytes + 1)),
                                         ("alice", String(repeating: "é", count: ServerLimits.passwordMaximumBytes / 2) + "a")] {
                await #expect(throws: AccountError.malformedRequest) {
                    _ = try await fixture.attempt(username: username, password: password)
                }
            }
            #expect(await fixture.hasher.usedHashes().isEmpty)
            #expect(try await fixture.account.persistence.count("login_account_buckets") == 0)
            #expect(try await fixture.account.persistence.count("login_ip_buckets") == 0)
            #expect(try await fixture.account.persistence.count("devices") == 0)
        }
    }

    @Test func failureBucketsAndSuccessfulSessionResetAreAtomic() async throws {
        try await withLoginFixture { fixture in
            _ = try await fixture.account.user()
            await fixture.failure()
            try await fixture.account.persistence.execute("""
                CREATE TRIGGER reject_ip BEFORE UPDATE ON login_ip_buckets
                BEGIN SELECT RAISE(ABORT, 'secret SQL details'); END
                """)
            await #expect(throws: (any Error).self) { _ = try await fixture.attempt() }
            let pair = try await fixture.buckets()
            #expect(pair.account.failures == 1 && pair.ip.failures == 1)
            try await fixture.account.persistence.execute("DROP TRIGGER reject_ip")
            try await fixture.account.persistence.execute("""
                CREATE TRIGGER reject_reset BEFORE DELETE ON login_account_buckets
                BEGIN SELECT RAISE(ABORT, 'secret SQL details'); END
                """)
            await #expect(throws: (any Error).self) { _ = try await fixture.attempt(password: AccountTestFixture.password) }
            #expect(try await fixture.account.persistence.count("devices") == 0)
            #expect(try await fixture.buckets().account.failures == 1)
            try await fixture.account.persistence.execute("DROP TRIGGER reject_reset")
            _ = try await fixture.attempt(password: AccountTestFixture.password)
            #expect(try await fixture.buckets().account.failures == 0)
            #expect(try await fixture.account.persistence.count("devices") == 1)
        }
    }

    @Test func clockRollbackCannotClearOrShortenAnExistingLock() async throws {
        try await withLoginFixture { fixture in
            for _ in 0..<4 { await fixture.failure() }
            await fixture.failure(retry: 30)
            fixture.account.clock.advance(-3_600)
            await fixture.failure(retry: 900)
            fixture.account.clock.advance(3_600)
            await fixture.failure(retry: 30)
            fixture.account.clock.advance(30)
            await fixture.failure(retry: 60)
        }
    }

    @Test(arguments: ["reset", "disable"])
    func accountChangesDuringBcryptCannotMintASession(action: String) async throws {
        try await withAccountFixture { account in
            _ = try await account.user()
            let release = LoginTestLatch()
            let hasher = LoginTestHasher(release: release)
            let fixture = LoginTestFixture(account: account, hasher: hasher)
            let task = Task { try await fixture.attempt(password: AccountTestFixture.password) }
            await hasher.waitForVerifications(1)
            do {
                if action == "reset" { try await account.persistence.execute("UPDATE users SET password_hash = 'reset hash'") }
                else { try await account.persistence.execute("UPDATE users SET disabled_at = created_at") }
                await release.open()
                await #expect(throws: AccountError.unauthorized) { _ = try await task.value }
                let pair = try await fixture.buckets()
                #expect(pair.account.failures == 1 && pair.ip.failures == 1)
                #expect(try await account.persistence.count("devices") == 0)
            } catch {
                await release.open()
                _ = await task.result
                throw error
            }
        }
    }

    @Test func admissionBoundsWorkAndRejectsOverlappingAccountsOrIPsWithoutQueueing() async throws {
        try await withAccountFixture { account in
            let release = LoginTestLatch()
            let hasher = LoginTestHasher(release: release)
            let fixture = LoginTestFixture(account: account, hasher: hasher)
            let first = Task { try await fixture.attempt(username: "user1", ip: "198.51.100.1") }
            await hasher.waitForVerifications(1)
            await fixture.failure(username: "user1", ip: "203.0.113.1", retry: 1)
            await fixture.failure(username: "different", ip: "198.51.100.1", retry: 1)
            let tasks = [first] + (2...ServerLimits.loginConcurrentRequests).map { index in
                Task { try await fixture.attempt(username: "user\(index)", ip: "198.51.100.\(index)") }
            }
            await hasher.waitForVerifications(ServerLimits.loginConcurrentRequests)
            await fixture.failure(username: "different", ip: "203.0.113.1", retry: 1)
            #expect(await hasher.usedHashes().count == ServerLimits.loginConcurrentRequests)
            let accountBuckets = try await account.persistence.count("login_account_buckets")
            #expect(accountBuckets == 0)
            await release.open()
            for task in tasks { await #expect(throws: AccountError.unauthorized) { _ = try await task.value } }
            await fixture.failure(username: "different", ip: "203.0.113.1")
            #expect(await hasher.usedHashes().count == ServerLimits.loginConcurrentRequests + 1)
        }
    }

    @Test func cancellationReleasesAdmissionAndDoesNotIssueADeviceOrResetHistory() async throws {
        try await withAccountFixture { account in
            _ = try await account.user()
            let plain = LoginTestFixture(account: account)
            await plain.failure()
            let release = LoginTestLatch()
            let hasher = LoginTestHasher(release: release)
            let fixture = LoginTestFixture(account: account, hasher: hasher)
            let task = Task { try await fixture.attempt(password: AccountTestFixture.password) }
            await hasher.waitForVerifications(1)
            task.cancel()
            await release.open()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(try await fixture.buckets().account.failures == 1)
            #expect(try await account.persistence.count("devices") == 0)
            _ = try await fixture.attempt(password: AccountTestFixture.password)
            #expect(try await account.persistence.count("devices") == 1)
        }
    }
}
