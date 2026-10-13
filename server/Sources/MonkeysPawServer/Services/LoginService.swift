import Foundation
import MonkeysPawCore

struct LoginService: Sendable {
    private let accounts: AccountService
    private let sessions: SessionService
    private let repository: LoginRepository
    private let admission = LoginAdmission()

    init(accounts: AccountService, sessions: SessionService) {
        self.accounts = accounts
        self.sessions = sessions
        repository = LoginRepository(database: accounts.repository.database)
    }

    func login(_ request: SyncAPI.LoginRequest, ip: ClientIPAddress) async throws -> SyncAPI.AuthResponse {
        try AccountValidation.dto(request)
        let username = try AccountValidation.username(request.username)
        do {
            return try await admission.run(username: username, ip: ip.value) {
                try await attempt(request, username: username, ip: ip.value)
            }
        } catch LoginAdmission.AdmissionError.busy {
            // A durable lock takes precedence over the transient admission delay.
            let retry = try await retrySeconds(username: username, ip: ip.value)
            throw LoginError.rateLimited(try .init(seconds: max(1, retry)))
        }
    }

    private func retrySeconds(username: String, ip: String) async throws -> Int64 {
        try await repository.read { buckets in
            let now = accounts.clock()
            let pair = try await buckets.buckets(username: username, ip: ip, at: now)
            return max(pair.account.retrySeconds(at: now), pair.ip.retrySeconds(at: now))
        }
    }

    private func attempt(_ request: SyncAPI.LoginRequest, username: String, ip: String) async throws -> SyncAPI.AuthResponse {
        let retry = try await retrySeconds(username: username, ip: ip)
        guard retry == 0 else { throw LoginError.rateLimited(try .init(seconds: retry)) }

        do {
            // Exactly one bcrypt verification; no hashing or retry on this path.
            let verified = try await accounts.verifyCredentials(username: username, password: request.password)
            return try await repository.write { buckets, accountRecords, devices in
                let now = accounts.clock()
                let pair = try await buckets.buckets(username: username, ip: ip, at: now)
                let retry = max(pair.account.retrySeconds(at: now), pair.ip.retrySeconds(at: now))
                guard retry == 0 else { throw LoginError.rateLimited(try .init(seconds: retry)) }
                let issued = try await sessions.issueSession(for: verified, deviceName: request.deviceName,
                                                            accounts: accountRecords, devices: devices)
                try await buckets.resetAccount(username: username)
                return issued.response
            }
        } catch AccountError.unauthorized {
            let retry = try await repository.write { buckets, _, _ in
                let now = accounts.clock()
                let pair = try await buckets.buckets(username: username, ip: ip, at: now)
                let retry = max(pair.account.retrySeconds(at: now), pair.ip.retrySeconds(at: now))
                guard retry == 0 else { return retry }
                let account = pair.account.failed(at: now)
                let address = pair.ip.failed(at: now)
                try await buckets.recordFailure(username: username, ip: ip, account: account, address: address)
                return max(account.retrySeconds(at: now), address.retrySeconds(at: now))
            }
            // Throw after committing so a failed login cannot roll back history.
            if retry > 0 { throw LoginError.rateLimited(try .init(seconds: retry)) }
            throw AccountError.unauthorized
        }
    }
}
