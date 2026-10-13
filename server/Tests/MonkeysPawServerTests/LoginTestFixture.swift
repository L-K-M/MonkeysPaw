import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

actor LoginTestLatch {
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

actor LoginTestHasher: PasswordHashing {
    enum Mode: Sendable { case stub, bcrypt }
    private let mode: Mode
    private let release: LoginTestLatch?
    private var hashes: [String] = []
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []

    init(mode: Mode = .stub, release: LoginTestLatch? = nil) {
        self.mode = mode
        self.release = release
    }

    func hash(_ password: String) async throws -> String {
        Issue.record("Login must never hash a password")
        return "unused"
    }

    func verify(_ password: String, hash: String) async throws -> Bool {
        hashes.append(hash)
        let ready = starts.filter { $0.0 <= hashes.count }
        starts.removeAll { $0.0 <= hashes.count }
        ready.forEach { $0.1.resume() }
        await release?.wait()
        switch mode {
        case .bcrypt: return try await BcryptPasswordHasher().verify(password, hash: hash)
        case .stub:
            return AccountValidation.usablePassword(password) && password == AccountTestFixture.password
                && hash != BcryptPasswordHasher.dummyHash
        }
    }

    func usedHashes() -> [String] { hashes }

    func waitForVerifications(_ count: Int) async {
        guard hashes.count < count else { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }
}

struct LoginTestFixture: Sendable {
    let account: AccountTestFixture
    let hasher: LoginTestHasher
    let login: LoginService

    init(account: AccountTestFixture, hasher: LoginTestHasher = .init()) {
        self.account = account
        self.hasher = hasher
        login = .init(accounts: .init(database: account.persistence.database, passwords: hasher, clock: account.clock.now),
                      sessions: account.sessions)
    }

    func buckets(username: String = "alice", ip: String = "198.51.100.1") async throws -> (account: LoginBucket, ip: LoginBucket) {
        try await LoginRepository(database: account.persistence.database).read {
            try await $0.buckets(username: username, ip: ip, at: account.clock.now())
        }
    }

    func attempt(username: String = "alice", password: String = "wrong", ip: String = "198.51.100.1") async throws -> SyncAPI.AuthResponse {
        try await login.login(.init(username: username, password: password, deviceName: "Login test"), ip: ClientIPAddress(ip))
    }

    func failure(
        username: String = "alice", password: String = "wrong", ip: String = "198.51.100.1",
        retry: Int64? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await attempt(username: username, password: password, ip: ip)
            Issue.record("Expected failed login", sourceLocation: sourceLocation)
        } catch {
            if let retry {
                #expect(error as? LoginError == .rateLimited(.init(seconds: retry)), sourceLocation: sourceLocation)
            } else {
                #expect(error as? AccountError == .unauthorized, sourceLocation: sourceLocation)
            }
        }
    }
}

func withLoginFixture(_ operation: @Sendable (LoginTestFixture) async throws -> Void) async throws {
    try await withAccountFixture { try await operation(LoginTestFixture(account: $0)) }
}
