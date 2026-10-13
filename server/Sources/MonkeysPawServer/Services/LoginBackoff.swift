import Foundation
import MonkeysPawCore

enum LoginError: Error, Equatable {
    case rateLimited(SyncAPI.RetryAfter)
}

struct LoginBucket: Sendable {
    let failures: Int
    let lockedUntil: Date?
    let updatedAt: Date

    func decayed(at now: Date) -> Self {
        let quietSince = max(updatedAt, lockedUntil ?? updatedAt)
        guard now.timeIntervalSince(quietSince) >= ServerLimits.loginDecayInterval else { return self }
        return Self(failures: 0, lockedUntil: nil, updatedAt: now)
    }

    func retrySeconds(at now: Date) -> Int64 {
        guard let lockedUntil, lockedUntil > now else { return 0 }
        return Int64(min(ServerLimits.loginMaximumLock, max(1, ceil(lockedUntil.timeIntervalSince(now)))))
    }

    func failed(at now: Date) -> Self {
        let failures = min(self.failures + 1, ServerLimits.loginMaximumFailures)
        let timestamp = max(now, updatedAt)
        guard failures >= ServerLimits.loginFreeAttempts else {
            return Self(failures: failures, lockedUntil: nil, updatedAt: timestamp)
        }
        let delay = min(ServerLimits.loginMaximumLock,
                        ServerLimits.loginInitialLock * Double(1 << (failures - ServerLimits.loginFreeAttempts)))
        return Self(failures: failures, lockedUntil: timestamp.addingTimeInterval(delay), updatedAt: timestamp)
    }
}

/// Reject rather than queue bcrypt work. Keeping both keys occupied through
/// completion prevents parallel attempts from outrunning persisted failures.
actor LoginAdmission {
    enum AdmissionError: Error { case busy }
    private var accounts: Set<String> = []
    private var ips: Set<String> = []

    func run<T: Sendable>(
        username: String, ip: String, operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard accounts.count < ServerLimits.loginConcurrentRequests,
              !accounts.contains(username), !ips.contains(ip) else {
            throw AdmissionError.busy
        }
        accounts.insert(username)
        ips.insert(ip)
        defer {
            accounts.remove(username)
            ips.remove(ip)
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
