import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// This debug-only acceptance worker is not copied into the deployed image.
#if DEBUG
@testable import SyncScenarioSupport
@testable import MonkeysPawCore

private struct WorkerInput: Decodable {
    let directory: String
    let endpoint: String
    let secret: String
    let now: Double
    let seed: UInt64
    let checkpoint: String
    let fileCount: Int
}

private final class Checkpoint {
    let input: WorkerInput
    private var publications = 0
    init(_ input: WorkerInput) { self.input = input }

    func published() throws {
        publications += 1
        if input.checkpoint == "after_files", publications == input.fileCount { try pauseHere() }
    }

    func beforePrivateWrite(_ path: String) throws {
        if publications > 0, path == "sync/state.json", input.checkpoint == "before_state" { try pauseHere() }
    }

    func beforeDelete(_ path: String) throws {
        // SyncApplyJournal deletes apply.json only after the state write and
        // both checked directory flushes have returned successfully.
        if publications > 0, path == "sync/apply.json", input.checkpoint == "after_state" { try pauseHere() }
    }

    func pauseHere() throws {
        try FileHandle.standardOutput.write(contentsOf: Data("paused\n".utf8))
        DispatchSemaphore(value: 0).wait()
    }
}

/// Use the exact acceptance disk adapter. The wrapper only pauses between
/// completed operations; it never fabricates bytes or a committed cursor.
private final class WorkerDisk: FileStore, SyncFileOperations {
    let disk: ScenarioDisk
    let checkpoint: Checkpoint
    let isLibrary: Bool
    init(_ disk: ScenarioDisk, checkpoint: Checkpoint, isLibrary: Bool) {
        self.disk = disk
        self.checkpoint = checkpoint
        self.isLibrary = isLibrary
    }
    func listFiles() throws -> [StoredFile] { try disk.listFiles() }
    func stamp(at path: String) throws -> FileStamp? { try disk.stamp(at: path) }
    func read(at path: String) throws -> Data { try disk.read(at: path) }
    func write(_ data: Data, at path: String) throws { try disk.write(data, at: path) }
    func writePrivate(_ data: Data, at path: String) throws {
        if !isLibrary { try checkpoint.beforePrivateWrite(path) }
        try disk.writePrivate(data, at: path)
    }
    func create(_ data: Data, at path: String) throws { try disk.create(data, at: path) }
    func delete(at path: String) throws {
        if !isLibrary { try checkpoint.beforeDelete(path) }
        try disk.delete(at: path)
    }
    func move(from source: String, to destination: String) throws { try disk.move(from: source, to: destination) }
    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication {
        let result = try disk.publish(bytes, at: path, expecting: expecting, mode: mode)
        if isLibrary { try checkpoint.published() }
        return result
    }
    func flushFile(at path: RelativePath) throws { try disk.flushFile(at: path) }
    func flushDirectory(at path: RelativePath?) throws { try disk.flushDirectory(at: path) }
    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws { try disk.setMode(mode, at: path) }
    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws { try disk.trash(at: path, expecting: expecting) }
    func createDirectory(at path: RelativePath) throws { try disk.createDirectory(at: path) }
    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws { try disk.renameDirectory(from: source, to: destination) }
    func directories(at path: RelativePath?) throws -> [RelativePath] { try disk.directories(at: path) }
    func directoryIdentity(at path: RelativePath) throws -> FileStamp? { try disk.directoryIdentity(at: path) }
    func removeEmptyDirectory(at path: RelativePath, expecting: FileStamp) throws { try disk.removeEmptyDirectory(at: path, expecting: expecting) }
}

private struct WorkerSecrets: SecretStore {
    let envelope: String
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        .init(value: SecretValue(envelope), tier: .file)
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier { throw FileStoreError.ioFailure }
    func delete(account: SecretAccount) throws { throw FileStoreError.ioFailure }
}

/// Metadata remains bound to the fixture's logical deployment. Only this
/// test transport maps that deployment to the live server's ephemeral port.
private struct WorkerTransport: HTTPTransporting {
    let endpoint: SyncServerURL
    func send(_ request: MonkeysPawCore.HTTPRequest) async throws -> MonkeysPawCore.HTTPResponse {
        guard case .sync(let original) = request.urlPolicy else { throw HTTPTransportError.serverMismatch }
        _ = try original.validatedRequestURL(request.url)
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        components.scheme = endpoint.baseURL.scheme
        components.host = endpoint.baseURL.host
        components.port = endpoint.baseURL.port
        let mapped = try MonkeysPawCore.HTTPRequest(url: components.url!, method: request.method, headers: request.headers,
            body: request.body, requestByteCap: request.requestByteCap, responseByteCap: request.responseByteCap,
            deadline: request.deadline, urlPolicy: .sync(server: endpoint))
        return try await URLSessionHTTPTransport().send(mapped)
    }
}

private func runWorker() async throws {
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    guard bytes.count <= 64 * 1024 else { throw FileStoreError.ioFailure }
    let input = try JSONDecoder().decode(WorkerInput.self, from: bytes)
    guard ["none", "after_files", "before_state", "after_state", "stall"].contains(input.checkpoint),
          input.fileCount > 0 else { throw FileStoreError.ioFailure }
    let endpoint = try SyncServerURL(input.endpoint)
    guard endpoint.baseURL.host == "127.0.0.1", endpoint.baseURL.scheme == "http" else { throw HTTPTransportError.invalidURL }
    let checkpoint = Checkpoint(input)
    if input.checkpoint == "stall" { try checkpoint.pauseHere() }
    let directory = URL(fileURLWithPath: input.directory)
    let files = try WorkerDisk(ScenarioDisk(root: directory.appendingPathComponent("library"),
        trash: directory.appendingPathComponent("library-trash")), checkpoint: checkpoint, isLibrary: true)
    let data = try WorkerDisk(ScenarioDisk(root: directory.appendingPathComponent("data"),
        trash: directory.appendingPathComponent("data-trash")), checkpoint: checkpoint, isLibrary: false)
    let clock = ScenarioClock(Date(timeIntervalSince1970: input.now))
    let entropy = ScenarioEntropy(seed: input.seed)
    let usage = UsageStore(files: data, clock: clock)
    let values = ValuesStore(files: data)
    let library = LibraryService(library: files, data: data, clock: clock, entropy: entropy, keyedStores: [usage, values])
    let states = SyncStateStore(files: data, operations: data)
    let accounts = SyncAccountStore(files: data, operations: data)
    let sync = try SyncService(library: library, libraryOperations: files, dataFiles: data, dataOperations: data,
        states: states, accounts: accounts, scheduler: ScenarioScheduler(), mainThread: ScenarioMainThread(), clock: clock, entropy: entropy)
    let account = try SyncAccountService(sync: sync, accounts: accounts, secrets: WorkerSecrets(envelope: input.secret),
        transport: WorkerTransport(endpoint: endpoint), libraryRoot: files.disk.root.path)
    let result = try await account.startup()
    guard result.enabled, result.cleanup.isComplete else { throw FileStoreError.ioFailure }
    repeat { await sync.drain(); await Task.yield() } while sync.report.phase != .idle
    guard sync.report.blockingIssue == nil, [.idle, .hasConflicts].contains(sync.report.status),
          try data.stamp(at: "sync/apply.json") == nil else { throw FileStoreError.ioFailure }
    sync.stop()
    await sync.drain()
    try FileHandle.standardOutput.write(contentsOf: Data("complete\n".utf8))
}

Task {
    do { try await runWorker(); exit(0) }
    catch { exit(1) } // Never emit credentials, content or tool error bodies.
}
dispatchMain()
#else
exit(1)
#endif
