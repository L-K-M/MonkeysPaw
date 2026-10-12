#if os(Linux)
import Foundation
import MonkeysPawCore

/// Synchronous port for background service work, never the GLib main thread.
/// Environment overrides are read-only; mutations still reach persisted values
/// so ProviderSettingsService can compensate beneath an override (B23).
final class LinuxSecretStore: SecretStore {
    private enum Lookup { case found(SecretValue), absent, toolMissing }

    // secret-tool's stdin reader has an 8 KiB buffer and truncates larger input.
    private static let secretToolInputCap = 8_191
    private let runner: LinuxToolRunner
    private let file: LinuxSecretFile
    private let timeout: Duration
    private let lock = NSLock()
    private let service = AppIdentity.linuxAppID

    init(paths: LinuxPaths, runner: LinuxToolRunner = LinuxToolRunner(),
         timeout: Duration = Limits.linuxToolTimeout) {
        self.runner = runner
        file = LinuxSecretFile(paths: paths)
        self.timeout = timeout
    }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        if source == .effective, account.namespace == "provider",
           let uuid = UUID(uuidString: account.name),
           let value = runner.environment[ProviderProfileID(uuid).environmentVariable], !value.isEmpty {
            return StoredSecret(value: SecretValue(value), tier: .environment)
        }
        try requireWorker()
        lock.lock()
        defer { lock.unlock() }
        do {
            switch try lookup(account) {
            case .found(let value): return StoredSecret(value: value, tier: .secretService)
            case .absent, .toolMissing: return try fileSecret(account)
            }
        } catch let error as SecretStoreError where error == .locked || error == .unavailable {
            // Reading an existing fallback is safe. Never treat an inaccessible
            // service as a missing key and accidentally proceed without auth.
            if let stored = try fileSecret(account) { return stored }
            throw error
        }
    }

    @discardableResult
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        try requireWorker()
        lock.lock()
        defer { lock.unlock() }
        let previousFile = try fileSecret(account)
        let previous = try lookup(account)
        if case .toolMissing = previous {
            do { try file.write(value, account: account); return .file }
            catch { throw SecretStoreError.writeFailed }
        }
        try store(value, account: account)
        if previousFile != nil {
            do { try file.write(nil, account: account) }
            catch {
                // A failed cleanup must not leave a newly saved service key
                // shadowing the old file value after a reported failed write.
                try? restore(previous, account: account)
                throw SecretStoreError.writeFailed
            }
        }
        return .secretService
    }

    func delete(account: SecretAccount) throws {
        try requireWorker()
        lock.lock()
        defer { lock.unlock() }
        let previousFile = try fileSecret(account)
        let previous = try lookup(account)
        if case .found = previous { try clear(account) }
        guard previousFile != nil else { return }
        do { try file.write(nil, account: account) }
        catch {
            try? restore(previous, account: account)
            throw SecretStoreError.deleteFailed
        }
    }

    private func requireWorker() throws {
        guard !Thread.isMainThread else { throw SecretStoreError.unavailable }
    }

    private func fileSecret(_ account: SecretAccount) throws -> StoredSecret? {
        do { return try file.read(account: account).map { StoredSecret(value: $0, tier: .file) } }
        catch { throw SecretStoreError.readFailed }
    }

    private func attributes(_ account: SecretAccount) -> [String] {
        ["service", service, "account", account.rawValue]
    }

    private func lookup(_ account: SecretAccount) throws -> Lookup {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        switch runner.run("secret-tool", arguments: ["lookup"] + attributes(account),
            timeout: timeout, textOutput: .verbatim) {
        case .success(let output): return .found(SecretValue(output.text))
        case .failure(.toolMissing): return .toolMissing
        case .failure(.timeout): throw SecretStoreError.unavailable
        case .failure:
            // lookup exits 1 both for absence and errors. A successful, empty
            // search proves absence; an unreadable matching item is locked.
            // Neither command's diagnostic text is parsed or logged.
            guard ContinuousClock.now < deadline else { throw SecretStoreError.unavailable }
            guard case .success(let output) = runner.run("secret-tool",
                arguments: ["search", "--all"] + attributes(account),
                timeout: ContinuousClock.now.duration(to: deadline)) else { throw SecretStoreError.unavailable }
            guard output.text.isEmpty else { throw SecretStoreError.locked }
            return .absent
        }
    }

    private func store(_ value: SecretValue, account: SecretAccount) throws {
        let input = value.withValue { Data($0.utf8) }
        guard input.count <= Self.secretToolInputCap else { throw SecretStoreError.writeFailed }
        switch runner.run("secret-tool", arguments: ["store", "--label", "Monkey's Paw: \(account.rawValue)"]
            + attributes(account), timeout: timeout, input: input, textOutput: .verbatim) {
        case .success: return
        case .failure(.timeout), .failure(.toolMissing): throw SecretStoreError.unavailable
        case .failure: throw SecretStoreError.writeFailed
        }
    }

    private func clear(_ account: SecretAccount) throws {
        switch runner.run("secret-tool", arguments: ["clear"] + attributes(account), timeout: timeout) {
        case .success: return
        case .failure(.timeout), .failure(.toolMissing): throw SecretStoreError.unavailable
        case .failure: throw SecretStoreError.deleteFailed
        }
    }

    private func restore(_ previous: Lookup, account: SecretAccount) throws {
        switch previous {
        case .found(let value): try store(value, account: account)
        case .absent: try clear(account)
        case .toolMissing: break
        }
    }
}
#endif
