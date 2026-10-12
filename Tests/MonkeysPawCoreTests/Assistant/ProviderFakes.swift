import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderRecordingFiles: FileStore {
    let memory = MemoryFileStore()
    private(set) var attemptedWrites = [Data]()

    func listFiles() throws -> [StoredFile] { try memory.listFiles() }
    func stamp(at path: String) throws -> FileStamp? { try memory.stamp(at: path) }
    func read(at path: String) throws -> Data { try memory.read(at: path) }
    func write(_ data: Data, at path: String) throws {
        attemptedWrites.append(data)
        try memory.write(data, at: path)
    }
    func create(_ data: Data, at path: String) throws {
        attemptedWrites.append(data)
        try memory.create(data, at: path)
    }
    func writePrivate(_ data: Data, at path: String) throws {
        attemptedWrites.append(data)
        try memory.writePrivate(data, at: path)
    }
    func delete(at path: String) throws { try memory.delete(at: path) }
    func move(from source: String, to destination: String) throws { try memory.move(from: source, to: destination) }
}

final class FakeProviderSecrets: SecretStore {
    var persisted = [SecretAccount: StoredSecret]()
    var environment = [SecretAccount: SecretValue]()
    var tier = SecretTier.secretService
    var readError: Error?
    var writeError: Error?
    var deleteError: Error?
    /// Fails the Nth recorded write attempt, including failed attempts.
    /// Ignored when writeError is set, which fails every call first.
    var failWriteNumber: Int?
    private(set) var reads = [(SecretAccount, SecretReadSource)]()
    private(set) var writes = [SecretAccount]()
    private(set) var deletions = [SecretAccount]()

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        reads.append((account, source))
        if let readError { throw readError }
        if case .effective = source, let value = environment[account] {
            return StoredSecret(value: value, tier: .environment)
        }
        return persisted[account]
    }

    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        writes.append(account)
        if let writeError { throw writeError }
        if writes.count == failWriteNumber { throw SecretStoreError.writeFailed }
        persisted[account] = StoredSecret(value: value, tier: tier)
        return tier
    }

    func delete(account: SecretAccount) throws {
        deletions.append(account)
        if let deleteError { throw deleteError }
        persisted[account] = nil
    }
}

final class ProviderCapturedLog: LogSink {
    private(set) var lines = [String]()
    func write(_ level: LogLevel, _ message: String) { lines.append("\(level.rawValue): \(message)") }
}

final class ProviderHarness {
    let files: ProviderRecordingFiles
    let secrets: FakeProviderSecrets
    let log: ProviderCapturedLog
    let service: ProviderSettingsService

    init(files: ProviderRecordingFiles = ProviderRecordingFiles(), secrets: FakeProviderSecrets = FakeProviderSecrets(),
         log: ProviderCapturedLog = ProviderCapturedLog()) {
        self.files = files
        self.secrets = secrets
        self.log = log
        service = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
    }

    /// Simulates a relaunch over the same fakes; recording counts accumulate.
    func reopen() -> ProviderHarness { ProviderHarness(files: files, secrets: secrets, log: log) }

    func json() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: files.read(at: "provider-settings.json"))
        return try XCTUnwrap(object as? [String: Any], "provider-settings.json root should be a JSON object")
    }
}
