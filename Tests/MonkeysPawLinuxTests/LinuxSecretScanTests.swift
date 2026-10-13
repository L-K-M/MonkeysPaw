#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxSecretScanTests: XCTestCase {
    func testSecretServiceLifecycleLeavesNoSentinelOnDisk() throws {
        let portal = try FakePortal(address: FakePortal.requirePrivateBus(),
                                    globalShortcuts: nil, remoteDesktop: nil)
        defer { portal.shutdown() }
        try portal.exportSecretStore()
        try portal.ownName()
        try lifecycle(tier: .secretService)
        XCTAssertTrue(portal.secretMethods.contains("Store"))
        XCTAssertTrue(portal.secretMethods.contains("Lookup"))
        XCTAssertTrue(portal.secretMethods.contains("Clear"))
    }

    func testFileLifecycleLeavesOnlyOneUnencryptedPrivateCopy() throws {
        try lifecycle(tier: .file)
    }

    func testMissingScanRootFailsInsteadOfPassingVacuously() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mp-scan-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try SecretScan("sentinel-\(UUID().uuidString)").matches(in: [missing]))
    }

    func testScanTreatsOnlyMissingPathsAsVanished() {
        let missingUnderlying = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        XCTAssertTrue(SecretScan.isVanished(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(SecretScan.isVanished(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(SecretScan.isVanished(missingUnderlying))
        XCTAssertFalse(SecretScan.isVanished(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(SecretScan.isVanished(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testScannerFindsRawEncodedAndNestedJSONInHiddenDirectories() throws {
        let tools = try FakeLinuxTools()
        let sentinel = "scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let hidden = tools.directory.appendingPathComponent(".hidden/nested")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let credential = try JSONSerialization.data(withJSONObject: ["key": sentinel])
        let nested = try JSONSerialization.data(withJSONObject: ["secret": String(decoding: credential, as: UTF8.self)])
        let encodings = [Data(sentinel.utf8), Data(Data(sentinel.utf8).base64EncodedString().utf8),
            Data(sentinel.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!.utf8),
            credential, nested, Data(repeating: 0, count: 65_532) + Data(sentinel.utf8) + Data([255, 0])]
        var expected = Set<URL>()
        for (index, bytes) in encodings.enumerated() {
            let file = hidden.appendingPathComponent("copy-\(index)")
            try bytes.write(to: file)
            expected.insert(file.standardizedFileURL)
        }
        XCTAssertEqual(try scan.matches(in: [tools.directory, hidden]), expected)
        XCTAssertEqual(scan.copyCount(in: encodings[0] + encodings[4]), 2)
        for file in expected { try FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try scan.matches(in: [tools.directory]).isEmpty)
    }

    private func lifecycle(tier: SecretTier) throws {
        try GTKTestSupport.requireDisplay()
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        let temporary = tools.directory.appendingPathComponent("temporary")
        tools.environment["TMPDIR"] = temporary.path
        let paths = LinuxPaths(environment: tools.environment)
        for directory in [paths.configDirectory, paths.dataDirectory, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if tier == .secretService {
            tools.environment["DBUS_SESSION_BUS_ADDRESS"] = try FakePortal.requirePrivateBus()
            // The implementation host supplies GIO in its userland sysroot.
            tools.environment["LD_LIBRARY_PATH"] = ProcessInfo.processInfo.environment["MONKEYSPAW_HOST_X11_LIBRARIES"]
                ?? ProcessInfo.processInfo.environment["LD_LIBRARY_PATH"]
            try tools.install("secret-tool", script: "exec /usr/bin/python3 \"$SCAN_BRIDGE\" \"$@\"")
            let bridge = tools.directory.appendingPathComponent("bridge.py")
            try Data(Self.bridge.utf8).write(to: bridge)
            tools.environment["SCAN_BRIDGE"] = bridge.path
        }
        let sentinel = "sk-scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let stderr = temporary.appendingPathComponent("stderr.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stderr)
        defer { try? output.close() }
        let log = CompositeLogSink(sinks: [StandardErrorLog(output: output),
            FileLogSink(dataDirectory: paths.dataDirectory)], policy: LogLevelPolicy(environmentValue: "debug"))
        log.write(.debug, "Secret scan lifecycle started.")
        let transport = SecretScanTransport(key: SecretValue(sentinel))
        var graph = try self.graph(tools, transport: transport, log: log)
        var draft = ProviderDraft(displayName: "Sentinel profile", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "manual",
            key: .replace(SecretValue(sentinel)))
        let id = draft.id
        let file = paths.configDirectory.appendingPathComponent("secrets-unencrypted.json").standardizedFileURL
        let roots = [repository, tools.directory, paths.configDirectory, paths.dataDirectory,
            paths.dataDirectory.appendingPathComponent("logs"), temporary]

        func checkpoint(_ step: String, hasKey: Bool = true) throws {
            log.write(.debug, "Secret scan checkpoint: \(step).")
            let expected: Set<URL> = tier == .file && hasKey ? [file] : []
            XCTAssertEqual(try scan.matches(in: roots), expected, "Unexpected secret copy after \(step)")
            if tier == .file && hasKey {
                var info = stat()
                XCTAssertEqual(lstat(file.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o600)
                XCTAssertEqual(info.st_nlink, 1)
                XCTAssertEqual(info.st_uid, geteuid())
                let bytes = try Data(contentsOf: file)
                XCTAssertEqual(scan.copyCount(in: bytes), 1, "Fallback must contain exactly one sentinel")
                let map = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(map["storage"] as? String, "unencrypted")
                let secrets = try XCTUnwrap(map["secrets"] as? [String: String])
                XCTAssertEqual(Set(secrets.keys), [SecretAccount.provider(id).rawValue])
                let bound = try XCTUnwrap(secrets[SecretAccount.provider(id).rawValue])
                let credential = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bound.utf8)) as? [String: Any])
                XCTAssertTrue(credential["key"] as? String == sentinel, "Saved credential changed")
            }
        }

        try worker { try graph.settings.save(draft) }
        draft.key = .keep
        try assertStorage(graph, tier: tier)
        try checkpoint("save")
        let metadata = try Data(contentsOf: paths.configDirectory.appendingPathComponent("provider-settings.json"))
        try testConnection(graph, draft: draft, expected: .ok(models: []))
        try checkpoint("Test connection")
        try testConnection(graph, draft: draft, expected: .authentication)
        XCTAssertTrue(try Data(contentsOf: paths.configDirectory.appendingPathComponent("provider-settings.json")) == metadata)
        try checkpoint("failed Test connection")

        graph = try self.graph(tools, transport: transport, log: log)
        try worker {
            XCTAssertEqual(graph.settings.snapshot.settings.selectedProfileID, id)
            let key = try graph.settings.connection(for: id).key
            XCTAssertTrue(key == SecretValue(sentinel), "Restart lost the saved credential")
        }
        try assertStorage(graph, tier: tier)
        try checkpoint("restart")
        draft.displayName = "Renamed profile"
        try worker { try graph.settings.save(draft) }
        try checkpoint("rename")
        let other = ProviderDraft(displayName: "Keyless profile", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "other", key: .clear)
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
        try checkpoint("delete sentinel profile", hasKey: false)
        graph = try self.graph(tools, transport: transport, log: log)
        XCTAssertTrue(graph.settings.snapshot.settings.profiles.isEmpty)
        try checkpoint("restart after deletion", hasKey: false)
    }

    private struct Graph {
        let secrets: LinuxSecretStore
        let settings: ProviderSettingsService
        let assistant: AssistantService
        let work: LinuxBackgroundWork
    }

    private func graph(_ tools: FakeLinuxTools, transport: SecretScanTransport, log: LogSink) throws -> Graph {
        let paths = LinuxPaths(environment: tools.environment)
        let files = try RootedFileStore(root: paths.configDirectory)
        let secrets = LinuxSecretStore(paths: paths, runner: tools.runner)
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
        let work = LinuxBackgroundWork()
        let assistant = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: files)),
            work: work, main: GLibMainThread())
        return Graph(secrets: secrets, settings: settings, assistant: assistant, work: work)
    }

    private func assertStorage(_ graph: Graph, tier: SecretTier) throws {
        let model = AssistantSettingsModel(settings: graph.settings, assistant: graph.assistant,
            work: graph.work, mainThread: GLibMainThread())
        XCTAssertTrue(GTKTestSupport.spin { model.state.operation == nil && model.state.keyStorage == .saved(tier) })
        XCTAssertEqual(model.state.keyStorage, .saved(tier))
        if tier == .file {
            XCTAssertTrue(LinuxAssistantSettingsStrings.storage(model.state.keyStorage).contains("unencrypted"))
            XCTAssertTrue(LinuxAssistantSettingsStrings.unencrypted.contains("unencrypted"))
        }
    }

    private func testConnection(_ graph: Graph, draft: ProviderDraft, expected: ConnectionTestResult) throws {
        var result: ConnectionTestResult?
        let test = graph.assistant.testConnection(draft: draft) { result = $0 }
        defer { test.cancel() }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
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
        DispatchQueue.global().async { receipt.value = Result { try body() } }
        // The worker's fake service calls need this thread to drain GLib.
        XCTAssertTrue(GTKTestSupport.spin(until: { receipt.value != nil }, timeout: .seconds(15)))
        try XCTUnwrap(receipt.value).get()
    }

    /// Implements only secret-tool's CLI boundary, using the existing private
    /// portal fixture's test interface rather than a disk-backed fake vault.
    private static let bridge = #"""
    import ctypes as c
    import sys
    gio = c.CDLL("libgio-2.0.so.0")
    glib = c.CDLL("libglib-2.0.so.0")
    def api(lib, name, result, *args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, args
        return fn
    ptr, text, integer = c.c_void_p, c.c_char_p, c.c_int
    bus_get = api(gio, "g_bus_get_sync", ptr, integer, ptr, ptr)
    call = api(gio, "g_dbus_connection_call_sync", ptr, ptr, text, text, text, text, ptr, ptr, integer, integer, ptr, ptr)
    string = api(glib, "g_variant_new_string", ptr, text)
    tuple_value = api(glib, "g_variant_new_tuple", ptr, c.POINTER(ptr), c.c_size_t)
    child = api(glib, "g_variant_get_child_value", ptr, ptr, c.c_size_t)
    boolean = api(glib, "g_variant_get_boolean", integer, ptr)
    value_text = api(glib, "g_variant_get_string", text, ptr, ptr)
    unref = api(glib, "g_variant_unref", None, ptr)
    object_unref = api(gio, "g_object_unref", None, ptr)
    try:
        args = sys.argv[1:]
        action = args[0]
        account = args[args.index("account") + 1]
        values = [account.encode()]
        if action == "store":
            values.append(sys.stdin.buffer.read())
        children = (ptr * len(values))(*(string(value) for value in values))
        parameters = tuple_value(children, len(values))
        bus = bus_get(2, None, None)
        if not bus:
            sys.exit(2)
        reply = call(bus, b"org.freedesktop.portal.Desktop", b"/org/freedesktop/portal/desktop",
            b"ch.lkmc.monkeyspaw.tests.SecretStore", action.capitalize().encode(), parameters,
            None, 0, 1500, None, None)
        if not reply:
            sys.exit(2)
        status = 0
        if action in ("lookup", "search"):
            found, value = child(reply, 0), child(reply, 1)
            present = boolean(found)
            if action == "lookup":
                if present:
                    sys.stdout.buffer.write(value_text(value, None))
                else:
                    status = 1
            elif present:
                sys.stdout.write("[item]")
            unref(found)
            unref(value)
        unref(reply)
        object_unref(bus)
        sys.exit(status)
    except Exception:
        sys.exit(2)
    """#
}

private actor SecretScanTransport: HTTPTransporting {
    private let key: SecretValue
    private var requests = 0
    init(key: SecretValue) { self.key = key }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/v1/models")
        XCTAssertNil(request.body)
        XCTAssertTrue(key.withValue { request.headers["Authorization"] == "Bearer " + $0 }, "Test used the wrong key")
        if requests == 1 { return HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)) }
        return HTTPResponse(statusCode: 401, body: key.withValue { Data($0.utf8) })
    }
}
#endif
