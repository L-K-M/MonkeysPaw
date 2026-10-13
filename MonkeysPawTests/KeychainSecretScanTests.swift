import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class KeychainSecretScanTests: XCTestCase {
    func testKeychainLifecycleLeavesNoSentinelOnDiskWithoutPrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-secret-scan-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let data = root.appendingPathComponent("data")
        let temporary = root.appendingPathComponent("temporary")
        for directory in [config, data, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let sentinel = "sk-scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let stderr = temporary.appendingPathComponent("stderr.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stderr)
        defer { try? output.close() }
        let log = CompositeLogSink(sinks: [KeychainScanLog(output: output), FileLogSink(dataDirectory: data)],
            policy: LogLevelPolicy(environmentValue: "debug"))
        log.write(.debug, "Secret scan lifecycle started.")
        // The service namespace is unique; never touch the app's real secret-map item.
        let itemService = "ch.lkmc.monkeyspaw.tests.scan." + UUID().uuidString
        let transport = KeychainScanTransport(key: SecretValue(sentinel))
        var graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        var draft = ProviderDraft(displayName: "Sentinel profile", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "manual", key: .replace(SecretValue(sentinel)))
        let id = draft.id
        do { try worker { try graph.settings.save(draft) } }
        catch let error as ProviderSettingsError where error == .secret(.locked) || error == .secret(.unavailable) {
            throw XCTSkip("Login Keychain is unavailable or requires interaction; owner verification remains required")
        }
        defer {
            do { try worker { try graph.secrets.delete(account: .provider(id)) } }
            catch { XCTFail("Could not remove the uniquely named scan Keychain item") }
        }
        draft.key = .keep
        let roots = [repository, root, config, data, data.appendingPathComponent("logs"), temporary]
        func checkpoint(_ step: String) throws {
            log.write(.debug, "Secret scan checkpoint: \(step).")
            XCTAssertTrue(try scan.matches(in: roots).isEmpty, "Unexpected secret copy after \(step)")
        }

        try assertStorage(graph)
        try checkpoint("save")
        let metadata = try Data(contentsOf: config.appendingPathComponent("provider-settings.json"))
        try testConnection(graph, draft: draft, expected: .ok(models: []))
        try checkpoint("Test connection")
        try testConnection(graph, draft: draft, expected: .authentication)
        XCTAssertTrue(try Data(contentsOf: config.appendingPathComponent("provider-settings.json")) == metadata)
        try checkpoint("failed Test connection")
        graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        try worker {
            XCTAssertEqual(graph.settings.snapshot.settings.selectedProfileID, id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel), "Restart lost the saved credential")
        }
        try assertStorage(graph)
        try checkpoint("restart")
        draft.displayName = "Renamed profile"
        try worker { try graph.settings.save(draft) }
        try checkpoint("rename")
        let other = ProviderDraft(displayName: "Keyless profile", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "other", key: .clear)
        try worker {
            try graph.settings.save(other)
            try graph.settings.selectProfile(other.id)
            XCTAssertNil(try graph.settings.connection(for: other.id).key)
        }
        try checkpoint("switch away")
        try worker {
            try graph.settings.selectProfile(id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel))
        }
        try checkpoint("switch back")
        try worker {
            try graph.settings.deleteProfile(other.id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel))
        }
        try checkpoint("delete other profile")
        try worker {
            try graph.settings.deleteProfile(id)
            XCTAssertNil(try graph.secrets.read(account: .provider(id), source: .persisted))
        }
        try checkpoint("delete sentinel profile")
        graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        XCTAssertTrue(graph.settings.snapshot.settings.profiles.isEmpty)
        try checkpoint("restart after deletion")
    }

    func testScannerFindsRawEncodedAndNestedJSONInHiddenDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-scan-calibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".hidden/nested")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let sentinel = "scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let credential = try JSONSerialization.data(withJSONObject: ["key": sentinel])
        let nested = try JSONSerialization.data(withJSONObject: ["secret": String(decoding: credential, as: UTF8.self)])
        let encodings = [Data(sentinel.utf8), Data(Data(sentinel.utf8).base64EncodedString().utf8),
            Data(sentinel.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!.utf8), credential, nested,
            Data(repeating: 0, count: 65_532) + Data(sentinel.utf8) + Data([255, 0])]
        var expected = Set<URL>()
        for (index, bytes) in encodings.enumerated() {
            let file = hidden.appendingPathComponent("copy-\(index)")
            try bytes.write(to: file)
            expected.insert(file.standardizedFileURL)
        }
        XCTAssertEqual(try scan.matches(in: [root, hidden]), expected)
        XCTAssertEqual(scan.copyCount(in: encodings[0] + encodings[4]), 2)
        for file in expected { try FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try scan.matches(in: [root]).isEmpty)
    }

    private struct Graph {
        let secrets: NoninteractiveKeychain
        let settings: ProviderSettingsService
        let assistant: AssistantService
        let work: DispatchBackgroundWork
    }

    private func graph(config: URL, itemService: String, transport: KeychainScanTransport, log: LogSink) throws -> Graph {
        let files = try RootedFileStore(root: config)
        let secrets = NoninteractiveKeychain(store: KeychainSecretStore(service: itemService))
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
        let work = DispatchBackgroundWork()
        let assistant = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: files)),
            work: work, main: DispatchMainThread())
        return Graph(secrets: secrets, settings: settings, assistant: assistant, work: work)
    }

    private func assertStorage(_ graph: Graph) throws {
        let model = AssistantSettingsModel(settings: graph.settings, assistant: graph.assistant,
            work: graph.work, mainThread: DispatchMainThread())
        let deadline = Date(timeIntervalSinceNow: 5)
        while (model.state.operation != nil || model.state.keyStorage != .saved(.keychain)), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        XCTAssertEqual(model.state.keyStorage, .saved(.keychain))
    }

    private func testConnection(_ graph: Graph, draft: ProviderDraft, expected: ConnectionTestResult) throws {
        let done = expectation(description: "Connection test finished")
        var result: ConnectionTestResult?
        let test = graph.assistant.testConnection(draft: draft) { result = $0; done.fulfill() }
        defer { test.cancel() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, expected)
    }

    private func worker(_ body: @escaping () throws -> Void) throws {
        final class Receipt {
            private let lock = NSLock()
            private var stored: Result<Void, Error>?
            var value: Result<Void, Error>? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); defer { lock.unlock() }; stored = newValue }
            }
        }
        let receipt = Receipt()
        let done = expectation(description: "Background secret operation")
        DispatchQueue.global().async { receipt.value = Result { try body() }; done.fulfill() }
        wait(for: [done], timeout: 10)
        try XCTUnwrap(receipt.value).get()
    }
}

/// Scope interaction suppression per call: holding its lock across an async
/// connection test would deadlock the worker trying to read the Keychain.
private struct NoninteractiveKeychain: SecretStore {
    let store: KeychainSecretStore
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        try access { try store.read(account: account, source: source) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        try access { try store.write(value, account: account) }
    }
    func delete(account: SecretAccount) throws { try access { try store.delete(account: account) } }

    private func access<T>(_ work: () throws -> T) throws -> T {
        do { return try SystemKeychainAccess.withoutUserInteraction(work) }
        catch KeychainAccessError.unavailable { throw SecretStoreError.unavailable }
    }
}

private actor KeychainScanTransport: HTTPTransporting {
    private let key: SecretValue
    private var requests = 0
    init(key: SecretValue) { self.key = key }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/v1/models")
        XCTAssertNil(request.body)
        XCTAssertTrue(key.withValue { request.headers["x-api-key"] == $0 }, "Test used the wrong key")
        if requests == 1 { return HTTPResponse(statusCode: 200, body: Data(#"{"data":[],"has_more":false}"#.utf8)) }
        return HTTPResponse(statusCode: 401, body: key.withValue { Data($0.utf8) })
    }
}

private struct KeychainScanLog: LogSink {
    let output: FileHandle
    func write(_ level: LogLevel, _ message: String) {
        do { try output.write(contentsOf: Data((message + "\n").utf8)) }
        catch { XCTFail("Could not capture secret-scan diagnostics") }
    }
}
