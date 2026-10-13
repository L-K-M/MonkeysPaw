import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

// NSLock protects the injected synchronous clock used from concurrent services.
final class AccountTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_797_552_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value.addTimeInterval(seconds)
    }
}

struct AccountTestFixture: Sendable {
    static let password = "account-test-password"
    let persistence: PersistenceTestRepository
    let clock = AccountTestClock()
    var accounts: AccountService { .init(database: persistence.database, clock: clock.now) }
    var sessions: SessionService { .init(database: persistence.database, clock: clock.now) }

    func user(username: String = "Alice", kind: SyncAPI.AccountKind = .member) async throws -> AccountRecord {
        let hash = try await BcryptPasswordHasher().hash(Self.password)
        let user = try AccountRecord(id: ServerTimestamp.id(at: clock.now()), username: AccountValidation.username(username),
                                     displayName: nil, passwordHash: hash, accountKind: kind,
                                     createdAt: ServerTimestamp.string(clock.now()), disabledAt: nil)
        try await accounts.repository.write { accounts, _ in try await accounts.insert(user) }
        return user
    }

    /// Mint sessions only in tests; the S7 HTTP login route owns backoff.
    func session(_ user: AccountRecord, name: String = "Test device") async throws -> IssuedSession {
        try await sessions.issueSession(for: VerifiedAccount(user: user), deviceName: name)
    }

    func assertNoPlaintext(_ secrets: [String]) async throws {
        let path = try await persistence.string("PRAGMA database_list", column: "file")
        try Self.scan(URL(fileURLWithPath: path).deletingLastPathComponent(), excluding: secrets)
    }

    static func scan(_ directory: URL, excluding secrets: [String]) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            let containsNoPlaintext = secrets.allSatisfy { bytes.range(of: Data($0.utf8)) == nil }
            #expect(containsNoPlaintext)
        }
    }
}

func withAccountFixture(_ operation: @Sendable (AccountTestFixture) async throws -> Void) async throws {
    try await withPersistenceDatabase { try await operation(AccountTestFixture(persistence: $0)) }
}
