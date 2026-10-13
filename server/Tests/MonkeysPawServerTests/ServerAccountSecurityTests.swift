import Crypto
import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAccountSecurityTests {
    @Test func timestampsKeepMillisecondUTCFormatAcrossConcurrentRequests() async throws {
        let date = Date(timeIntervalSince1970: 1_797_552_000.125)
        let text = "2026-12-18T00:00:00.125Z"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    #expect(ServerTimestamp.string(date) == text)
                    #expect(ServerTimestamp.date(text) == date)
                }
            }
            try await group.waitForAll()
        }
        #expect(ServerTimestamp.date("invalid") == nil)
    }

    @Test func usernamesHaveOneBoundedASCIIUniquenessRule() async throws {
        #expect(try AccountValidation.username("ALIce_1.-") == "alice_1.-")
        #expect(try AccountValidation.username("A") == "a")
        #expect(try AccountValidation.username(String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
        for invalid in ["", ".alice", "_alice", "-alice", "alice ", "a/b", "é", "a\u{0}b", String(repeating: "a", count: 65)] {
            #expect(throws: AccountError.malformedRequest) { try AccountValidation.username(invalid) }
        }
        try await withAccountFixture { fixture in
            _ = try await fixture.user(username: "Alice")
            await #expect(throws: (any Error).self) { _ = try await fixture.user(username: "aLiCe") }
            #expect(try await fixture.persistence.count("users") == 1)
        }
    }

    @Test func bcryptUsesCostTwelveRandomSaltsAndRejectsTruncationAliases() async throws {
        let passwords = BcryptPasswordHasher()
        let first = try await passwords.hash(AccountTestFixture.password)
        let second = try await passwords.hash(AccountTestFixture.password)
        let costAndSalts = first.hasPrefix("$2b$12$") && second.hasPrefix("$2b$12$") && first != second
        #expect(costAndSalts)
        #expect(try await passwords.verify(AccountTestFixture.password, hash: first))
        #expect(try await !passwords.verify("wrong-password", hash: first))
        let boundary = String(repeating: "é", count: 36)
        let boundaryHash = try await passwords.hash(boundary)
        #expect(try await passwords.verify(boundary, hash: boundaryHash))
        #expect(try await !passwords.verify(boundary + "x", hash: boundaryHash))
        for invalid in ["short", String(repeating: "a", count: 73), "twelve-chars!\u{0}suffix"] {
            await #expect(throws: AccountError.malformedRequest) { _ = try await passwords.hash(invalid) }
        }
    }

    @Test func unknownAndDisabledUsersPerformTheSameBcryptVerification() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let recorder = RecordingPasswordHasher()
            let accounts = AccountService(database: fixture.persistence.database, passwords: recorder)
            let verified = try await accounts.verifyCredentials(username: "ALICE", password: AccountTestFixture.password)
            #expect(verified.user.id == user.id)
            for username in ["missing", "INVALID USER"] {
                await #expect(throws: AccountError.unauthorized) {
                    _ = try await accounts.verifyCredentials(username: username, password: "wrong-password")
                }
            }
            try await fixture.persistence.execute("UPDATE users SET disabled_at = \(bind: user.createdAt)")
            await #expect(throws: AccountError.unauthorized) {
                _ = try await accounts.verifyCredentials(username: "alice", password: AccountTestFixture.password)
            }
            let equivalentWork = await recorder.usedHashes() == [user.passwordHash, BcryptPasswordHasher.dummyHash,
                                                                 BcryptPasswordHasher.dummyHash, user.passwordHash]
            #expect(equivalentWork)
        }
    }

    @Test func tokensUseThirtyTwoRandomBytesAndOnlySHA256IsStored() async throws {
        let tokens = (0..<256).map { _ in DeviceToken.generate() }
        let unique = Set(tokens.map(\.value)).count == tokens.count
        let correctLength = tokens.allSatisfy { token in
            let padded = token.value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
            return token.isValid && Data(base64Encoded: padded)?.count == 32
        }
        #expect(unique)
        #expect(correctLength)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let token = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let fixture = AccountTestFixture(persistence: .init(database: database))
            let user = try await fixture.user()
            let issued = try await fixture.session(user)
            let stored = try #require(await fixture.accounts.repository.read { _, devices in try await devices.device(id: issued.identity.deviceID) })
            let hashOnly = stored.tokenHash == issued.token.hash && stored.tokenHash.utf8.count == 64
            #expect(hashOnly)
            try AccountTestFixture.scan(directory, excluding: [issued.token.value, AccountTestFixture.password])
            let response = try JSONEncoder().encode(try await fixture.accounts.me(issued.identity))
            let safeResponse = !String(decoding: response, as: UTF8.self).contains("hash")
            #expect(safeResponse)
            let redacted = [String(describing: issued), String(reflecting: issued.token), String(describing: user),
                            String(reflecting: stored)].allSatisfy { !$0.contains(issued.token.value) && !$0.contains(user.passwordHash) }
            #expect(redacted)
            return issued.token
        }
        try AccountTestFixture.scan(directory, excluding: [token.value, AccountTestFixture.password])
    }

    @Test func lastSeenIsThrottledAtFiveMinutesIncludingConcurrentRequests() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let issued = try await fixture.session(user)
            try await fixture.persistence.execute("CREATE TABLE seen_updates (at TEXT)")
            try await fixture.persistence.execute("""
                CREATE TRIGGER count_seen AFTER UPDATE OF last_seen_at ON devices
                BEGIN INSERT INTO seen_updates (at) VALUES (NEW.last_seen_at); END
                """)
            _ = try await fixture.sessions.authenticate(token: issued.token.value)
            fixture.clock.advance(299)
            _ = try await fixture.sessions.authenticate(token: issued.token.value)
            #expect(try await fixture.persistence.count("seen_updates") == 0)
            fixture.clock.advance(1)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask { _ = try await fixture.sessions.authenticate(token: issued.token.value) }
                }
                try await group.waitForAll()
            }
            #expect(try await fixture.persistence.count("seen_updates") == 1)
            fixture.clock.advance(-600)
            _ = try await fixture.sessions.authenticate(token: issued.token.value)
            #expect(try await fixture.persistence.count("seen_updates") == 1)
            fixture.clock.advance(900)
            _ = try await fixture.sessions.authenticate(token: issued.token.value)
            #expect(try await fixture.persistence.count("seen_updates") == 2)
            try await fixture.persistence.execute("UPDATE devices SET last_seen_at = NULL")
            _ = try await fixture.sessions.authenticate(token: issued.token.value)
            #expect(try await fixture.persistence.count("seen_updates") == 4)
            try await fixture.persistence.execute("DROP TRIGGER count_seen")
            try await fixture.persistence.execute("DROP TABLE seen_updates")
        }
    }

    @Test func verifiedCredentialsCannotMintAfterPasswordResetOrDisable() async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let verified = try await fixture.accounts.verifyCredentials(username: user.username, password: AccountTestFixture.password)
            try await fixture.persistence.execute("UPDATE users SET password_hash = 'changed'")
            await #expect(throws: AccountError.unauthorized) { _ = try await fixture.sessions.issueSession(for: verified, deviceName: "Device") }
            try await fixture.persistence.execute("UPDATE users SET password_hash = \(bind: user.passwordHash), disabled_at = \(bind: user.createdAt)")
            await #expect(throws: AccountError.unauthorized) { _ = try await fixture.sessions.issueSession(for: verified, deviceName: "Device") }
            #expect(try await fixture.persistence.count("devices") == 0)
        }
    }

    @Test(arguments: ["revoke", "reset", "disable"])
    func changesRecheckAuthorityAfterBcryptWithoutHoldingTheWriter(action: String) async throws {
        try await withAccountFixture { fixture in
            let user = try await fixture.user()
            let current = try await fixture.session(user)
            let other = try await fixture.session(user)
            let blocking = SuspendedPasswordHasher()
            let accounts = AccountService(database: fixture.persistence.database, passwords: blocking)
            let request = SyncAPI.PasswordChangeRequest(currentPassword: AccountTestFixture.password, newPassword: "replacement-password")
            let change = Task { try await accounts.changePassword(request, session: current.identity) }
            await blocking.started.wait()
            do {
                switch action {
                case "revoke": try await fixture.sessions.logout(current.identity)
                case "reset": try await fixture.persistence.execute("UPDATE users SET password_hash = 'concurrent reset'")
                case "disable": try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at")
                default: Issue.record("Unexpected action argument: \(action)")
                }
                await blocking.release.open()
                await #expect(throws: AccountError.unauthorized) { try await change.value }
                let otherDevice = try await fixture.accounts.repository.read { _, devices in try await devices.device(id: other.identity.deviceID) }
                #expect(otherDevice?.revokedAt == nil)
            } catch {
                await blocking.release.open()
                _ = await change.result
                throw error
            }
        }
    }

}

private actor RecordingPasswordHasher: PasswordHashing {
    private var hashes: [String] = []
    func hash(_ password: String) async throws -> String { try await BcryptPasswordHasher().hash(password) }
    func verify(_ password: String, hash: String) async throws -> Bool {
        hashes.append(hash)
        return try await BcryptPasswordHasher().verify(password, hash: hash)
    }
    func usedHashes() -> [String] { hashes }
}

private struct SuspendedPasswordHasher: PasswordHashing {
    let started = AccountTestLatch()
    let release = AccountTestLatch()
    func hash(_ password: String) async throws -> String {
        await started.open()
        await release.wait()
        return try await BcryptPasswordHasher().hash(password)
    }
    func verify(_ password: String, hash: String) async throws -> Bool {
        try await BcryptPasswordHasher().verify(password, hash: hash)
    }
}

private actor AccountTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
