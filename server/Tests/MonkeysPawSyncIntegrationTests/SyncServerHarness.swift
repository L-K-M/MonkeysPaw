import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import NIOEmbedded
@testable import MonkeysPawCore
@testable import MonkeysPawServer

/// Only server value services/repositories are captured by request tasks.
/// Each device owns an independent Core graph and persisted roots.
enum SyncServerHarness {
    static let password = "scenario-test-password"

    static func run(_ scenario: SyncScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ScenarioClock(scenario.now)
        try await withScenarioDeadline(ContinuousClock.now.advanced(by: .seconds(120))) {
            try await withServers(scenario, root: root, clock: clock, index: 0, clients: [:], symbols: [:]) { clients, symbols in
                let runner = try ScenarioRunner(scenario: scenario, root: root, clients: clients, symbols: symbols)
                do {
                    try await runner.run()
                    await runner.stop()
                } catch {
                    await runner.stop()
                    throw error
                }
            }
        }
    }

    static func withServers(_ scenario: SyncScenario, root: URL, clock: ScenarioClock, index: Int,
                                   clients: [String: any TestClientProtocol], symbols: [String: String],
                                   configureDatabase: ((ServerDatabase, [String: String]) async throws -> Void)? = nil,
                                   operation: @escaping ([String: any TestClientProtocol], [String: String]) async throws -> Void) async throws {
        guard index < scenario.servers.count else { try await operation(clients, symbols); return }
        let name = scenario.servers[index]
        let directory = root.appendingPathComponent("server-" + name)
        let database = try await ServerDatabase.open(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]))
        do {
            try await database.migrate()
            let accounts = AccountService(database: database, clock: { clock.now() })
            let sessions = SessionService(database: database, clock: { clock.now() })
            let hash = try await BcryptPasswordHasher().hash(password)
            var symbols = symbols
            for (offset, username) in scenario.users.enumerated() {
                let id = try ULID.generate(at: scenario.now, entropy: [UInt8(index)] + Array(repeating: 0, count: 8) + [UInt8(offset + 1)])
                let user = try AccountRecord(id: id.rawValue, username: AccountValidation.username(username), displayName: nil,
                    passwordHash: hash, accountKind: .member, createdAt: ServerTimestamp.string(scenario.now), disabledAt: nil)
                try await accounts.repository.write { accounts, _ in try await accounts.insert(user) }
                symbols["user." + name + "." + username] = id.rawValue
            }
            try await configureDatabase?(database, symbols)
            let app = makeApplication(configuration: try .init(environment: ["MONKEYSPAW_LOG_LEVEL": "critical"]),
                                      accounts: accounts, sessions: sessions)
            let boundSymbols = symbols
            try await ScenarioPeerApplication(base: app).test(.router) { client in
                var clients = clients
                clients[name + ".test"] = client
                try await withServers(scenario, root: root, clock: clock, index: index + 1, clients: clients, symbols: boundSymbols,
                                      configureDatabase: configureDatabase,
                                      operation: operation)
            }
            await database.shutdown()
        } catch {
            await database.shutdown()
            throw error
        }
    }
}

/// Router testing has no socket peer. Supply connection metadata, then invoke
/// the unchanged production responder, including login/backoff and middleware.
private struct ScenarioPeerApplication<Base: ApplicationProtocol>: ApplicationProtocol {
    let base: Base
    var responder: ScenarioPeerResponder<Base.Responder> {
        get async throws { ScenarioPeerResponder(base: try await base.responder) }
    }
    var logger: Logger { base.logger }
}

private struct ScenarioPeerResponder<Base: HTTPResponder>: HTTPResponder where Base.Context: InitializableFromSource<ApplicationRequestContextSource> {
    let base: Base
    func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
        let channel = NIOAsyncTestingChannel()
        channel.remoteAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 54321)
        let peer = Base.Context(source: .init(channel: channel, logger: context.logger))
        return try await base.respond(to: request, context: peer)
    }
}

final class ScenarioDevice {
    let name: String
    let directory: URL
    let files: ScenarioDisk
    let data: ScenarioDisk
    let secrets: ScenarioSecrets
    let clock: ScenarioClock
    let entropy: ScenarioEntropy
    let transport: InProcessHTTPTransport
    let usage: UsageStore
    let values: ValuesStore
    let library: LibraryService
    let states: SyncStateStore
    let accounts: SyncAccountStore
    let sync: SyncService
    let account: SyncAccountService
    let scheduler = ScenarioScheduler()

    init(name: String, directory: URL, clock: ScenarioClock, entropy: ScenarioEntropy,
         transport: InProcessHTTPTransport) throws {
        self.name = name
        self.directory = directory
        self.clock = clock
        self.entropy = entropy
        self.transport = transport
        files = try ScenarioDisk(root: directory.appendingPathComponent("library"), trash: directory.appendingPathComponent("library-trash"))
        transport.library = files
        data = try ScenarioDisk(root: directory.appendingPathComponent("data"), trash: directory.appendingPathComponent("data-trash"))
        secrets = ScenarioSecrets(files: try ScenarioDisk(root: directory.appendingPathComponent("secrets"), trash: directory.appendingPathComponent("secret-trash")))
        usage = UsageStore(files: data, clock: clock)
        values = ValuesStore(files: data)
        library = LibraryService(library: files, data: data, clock: clock, entropy: entropy, keyedStores: [usage, values])
        states = SyncStateStore(files: data, operations: data)
        accounts = SyncAccountStore(files: data, operations: data)
        sync = try SyncService(library: library, libraryOperations: files, dataFiles: data, dataOperations: data,
            states: states, accounts: accounts, scheduler: scheduler, mainThread: ScenarioMainThread(), clock: clock, entropy: entropy)
        account = try SyncAccountService(sync: sync, accounts: accounts, secrets: secrets, transport: transport, libraryRoot: files.root.path)
    }

    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        try await withScenarioDeadline(deadline) { [self] in
            repeat {
                await sync.drain()
                if sync.report.phase == .idle { return }
                await Task.yield()
            } while ContinuousClock.now < deadline
            throw ScenarioFailure.invalid("device pass did not settle")
        }
    }

    func request(method: HTTPMethod, path: String, body: ScenarioValue?) async throws -> MonkeysPawCore.HTTPResponse {
        guard let account = try accounts.loadAccount(), let stored = try secrets.read(account: account.secretAccount, source: .effective) else {
            throw ScenarioFailure.invalid("HTTP action requires a signed-in device")
        }
        let envelope = try stored.value.withValue { try JSONDecoder().decode(ScenarioValue.self, from: Data($0.utf8)) }
        let token = try envelope.at("/token").string()
        let server = try SyncServerURL(account.identity.serverURL.absoluteString)
        let request = try MonkeysPawCore.HTTPRequest(url: URL(string: server.baseURL.absoluteString + path)!, method: method,
            headers: ["Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json"],
            body: try body.map { try JSONEncoder().encode($0) }, requestByteCap: SyncAPI.requestEnvelopeMaxBytes,
            responseByteCap: SyncAPI.responseEnvelopeMaxBytes, deadline: ContinuousClock.now.advanced(by: .seconds(30)), urlPolicy: .sync(server: server))
        return try await transport.send(request)
    }
}

final class ScenarioRunner {
    private let scenario: SyncScenario
    private let root: URL
    private var devices: [String: ScenarioDevice] = [:]
    private var symbols: [String: String]
    private var checkpoints = 0

    init(scenario: SyncScenario, root: URL, clients: [String: any TestClientProtocol], symbols: [String: String]) throws {
        self.scenario = scenario
        self.root = root
        self.symbols = symbols
        for (key, id) in scenario.prompts { self.symbols["prompt." + key] = id }
        for device in scenario.devices {
            devices[device.name] = try ScenarioDevice(name: device.name, directory: root.appendingPathComponent("device-" + device.name),
                clock: ScenarioClock(scenario.now), entropy: ScenarioEntropy(seed: device.seed), transport: InProcessHTTPTransport(clients: clients))
        }
    }

    func run() async throws {
        for (index, step) in scenario.steps.enumerated() {
            do { try await execute(step) }
            catch {
                // XCTest's errors must never print source bytes, bodies or credentials.
                let reason = safeFailure(error)
                throw ScenarioFailure.invalid(scenario.id + " step \(index + 1): " + reason)
            }
        }
        try check(checkpoints > 0, "scenario did not execute checkpoints")
        try check(devices.values.allSatisfy { $0.transport.pendingRewrites == 0 }, "unused network mutation")
        try check(devices.values.reduce(0) { $0 + $1.transport.traces.count } > 0, "scenario did not execute real HTTP")
    }

    private func safeFailure(_ error: Error) -> String {
        if let failure = error as? ScenarioFailure { return failure.description }
        if let account = error as? SyncAccountServiceError {
            switch account.issue {
            case .http(.transport(let code)): return "account transport " + code.rawValue
            case .metadata(let code): return "account metadata " + String(describing: code)
            case .http(.unauthorized): return "account unauthorized"
            case .http(.malformedResponse): return "account malformed response"
            case .http(.serverFailure(let code)): return "account server status \(code)"
            case .invalidAccount: return "account identity check"
            default: return "account operation failed"
            }
        }
        return "operation failed (" + String(describing: type(of: error)) + ")"
    }

    func stop() async {
        for device in devices.values { device.sync.stop(); await device.sync.drain() }
    }

    private func device(_ name: String) throws -> ScenarioDevice {
        guard let device = devices[name] else { throw ScenarioFailure.invalid("unknown device") }
        return device
    }

    private func execute(_ step: ScenarioStep) async throws {
        switch step {
        case .login(let name, let user, let server):
            let device = try device(name)
            try check(scenario.users.contains(user) && scenario.servers.contains(server), "unknown login participant")
            var password = SyncServerHarness.password
            let result = try await device.account.login(server: "https://" + server + ".test", username: user, password: &password, deviceName: name)
            try check(password.isEmpty && result.enabled && result.cleanup.isComplete, "login activation/cleanup")
            try await device.settle()
        case .write(let name, let path, let content): try device(name).files.write(Data(expand(content).utf8), at: expand(path))
        case .remove(let name, let path): try device(name).files.delete(at: expand(path))
        case .move(let name, let source, let destination): try device(name).files.move(from: expand(source), to: expand(destination))
        case .symlink(let name, let path):
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try device(name).files.symlink(at: expand(path), to: outside)
        case .sync(let name):
            let device = try device(name)
            device.sync.syncNow()
            try await device.settle()
        case .restart(let name):
            let old = try device(name)
            old.sync.stop()
            await old.sync.drain()
            let replacement = try ScenarioDevice(name: name, directory: old.directory, clock: old.clock, entropy: old.entropy, transport: old.transport)
            devices[name] = replacement
            let result = try await replacement.account.startup()
            try check(result.cleanup.isComplete, "restart cleanup")
            try await replacement.settle()
        case .signOut(let name):
            let device = try device(name)
            let cleanup = try await device.account.signOut()
            try check(cleanup.isComplete && cleanup.remote == .revoked, "sign-out cleanup/revocation")
        case .resetMetrics(let name):
            let device = try device(name)
            device.files.resetMetrics()
            device.transport.resetMetrics()
        case .watch(let name, let path):
            let device = try device(name)
            let path = try expand(path)
            let stamp = try device.files.stamp(at: path)
            let hash = try stamp.map { _ in SHA256.hexDigest(try device.files.read(at: path)) }
            device.sync.filesChanged([.init(path: RelativePath(path), stamp: stamp, hash: hash)])
        case .fireTimers(let name, let seconds):
            let device = try device(name)
            device.scheduler.fire(delay: .seconds(seconds))
            try await device.settle()
        case .bindPrompt(let name, let path, let symbol):
            let entry = try device(name).library.load(at: expand(path))
            guard case .assigned(let id) = entry.identity else { throw ScenarioFailure.invalid("cannot bind an idless prompt") }
            try bind("prompt." + symbol, id.rawValue)
        case .seedKeyed(let name, let path):
            let device = try device(name)
            let entry = try device.library.load(at: expand(path))
            _ = try HistoryStore(files: device.data).snapshot(device.files.read(at: expand(path)), for: entry.identity, at: device.clock.now())
            _ = try device.usage.recordUse(identity: entry.identity)
            try device.values.record(identity: entry.identity, values: ["field": "remembered locally"])
        case .favorite(let name, let id, let value):
            let device = try device(name)
            guard let state = try device.states.loadForAccountTransition() else { throw ScenarioFailure.invalid("favourite without state") }
            try device.states.update(for: state.binding) { state in
                let identity = PromptIdentity.assigned(try SyncIdentifiers.ulid(expand(id)))
                try state.applyGroupFavorite(value, for: identity)
            }
        case .http(let action):
            try await http(action)
        case .beforeRequest(let name, let method, let path, let then):
            try device(name).transport.before(method: method, path: expand(path)) { [self] in try await http(then) }
        case .rewrite(let action):
            let rewrite = ScenarioRewrite(device: action.device, phase: action.phase, method: action.method,
                path: try expand(action.path), patch: try action.patch.mapValues(expand))
            try device(action.device).transport.rewrite(rewrite)
        case .expect(let expectation): try expect(expectation)
        }
    }

    private func http(_ action: ScenarioHTTP) async throws {
        let response = try await device(action.device).request(method: action.method, path: expand(action.path), body: action.body.map(expand))
        try check(response.statusCode == action.status, "HTTP status")
        if !action.expected.isEmpty || !action.bindings.isEmpty {
            let json = try JSONDecoder().decode(ScenarioValue.self, from: response.body)
            for (pointer, expected) in action.expected { try check(json.at(pointer) == expand(expected), "HTTP JSON checkpoint") }
            for (name, pointer) in action.bindings { try bind(name, json.at(pointer).string()) }
        }
    }

    private func expect(_ expectation: ScenarioExpectation) throws {
        let device = try device(expectation.device)
        let state = try device.states.loadForAccountTransition()
        for (key, expected) in expectation.fields {
            switch key {
            case "files":
                for value in try expected.array() {
                    var file = try ScenarioObject(value)
                    let path = try expand(file.string("path"))
                    let content = try Data(expand(file.string("content")).utf8)
                    try check(device.files.read(at: path) == content, "exact file bytes")
                    if let mode = file.take("mode") {
                        let mode = try mode.string()
                        try check(["normal", "readOnly"].contains(mode), "unknown expected mode")
                        try check(device.files.mode(at: path) == (mode == "readOnly" ? .readOnly : .normal), "file mode")
                    }
                    try file.finish()
                }
            case "absent": for path in try expected.array() { try check(device.files.stamp(at: expand(path.string())) == nil, "file must be absent") }
            case "file_count": try check(device.files.listFiles().count == expected.integer(), "file count")
            case "status": try check(device.sync.report.status.rawValue == expected.string(), "sync status (" + device.sync.report.status.rawValue +
                ", pending \(device.sync.report.counts.pending), errors \(device.sync.report.counts.fileErrors), " + (device.sync.report.blockingIssue?.rawValue ?? "none") + ")")
            case "blocking_issue": try check((device.sync.report.blockingIssue?.rawValue ?? "none") == expected.string(), "blocking issue")
            case "prompt_count": try check((state?.prompts.count ?? 0) == expected.integer(), "prompt count")
            case "cursor_count": try check((state?.cursors.count ?? 0) == expected.integer(), "cursor count")
            case "held_count": try check(device.account.heldPrompts().count == expected.integer(), "held count")
            case "account_user": try check((device.account.snapshot.account?.identity.userID.rawValue ?? "none") == expand(expected.string()), "account user")
            case "writes": try check(device.files.writes == expected.integer(), "file publication count")
            case "trash_count": try check(device.files.trashCount == expected.integer(), "trash count")
            case "history_count":
                let histories = try device.data.listFiles().filter { $0.relativePath.hasPrefix("history/") && $0.relativePath.hasSuffix(".md") }
                try check(histories.count == expected.integer(), "total history count")
            case "state":
                for value in try expected.array() { try expectState(value, state: state, device: device) }
            case "requests":
                for value in try expected.array() {
                    var object = try ScenarioObject(value)
                    let method = try object.string("method")
                    let path = try expand(object.string("path"))
                    let status = try object.take("status")?.integer()
                    let count = try object.required("count").integer()
                    let body = try object.take("body")?.object().mapValues(expand) ?? [:]
                    let local = try object.take("local_exists")?.string()
                    let localPath = try local.map(expand)
                    let actual = try device.transport.traces.filter { trace in
                        guard (method == "*" || trace.method == method) && (path == "*" || trace.path == path) && (status == nil || status == trace.status) else { return false }
                        if let localPath, !trace.localPaths.contains(where: { $0.utf8.elementsEqual(localPath.utf8) }) { return false }
                        for (pointer, expected) in body {
                            guard let payload = trace.body, try payload.at(pointer) == expected else { return false }
                        }
                        return true
                    }
                    try check(actual.count == count, "request count")
                    try object.finish()
                }
            default: throw ScenarioFailure.invalid("unconsumed expectation")
            }
            checkpoints += 1
        }
    }

    private func expectState(_ value: ScenarioValue, state: SyncState?, device: ScenarioDevice) throws {
        var object = try ScenarioObject(value)
        let identity = PromptIdentity.assigned(try SyncIdentifiers.ulid(expand(object.string("id"))))
        guard let prompt = state?.prompts[identity] else { throw ScenarioFailure.invalid("missing prompt state") }
        try check(prompt.scope.rawValue == expand(object.string("scope")), "prompt scope")
        try check(prompt.path.string.utf8.elementsEqual(expand(object.string("path")).utf8), "prompt path")
        try check(prompt.rev == Int64(object.required("rev").integer()), "prompt revision")
        if let hash = object.take("hash") { try check(prompt.canonicalHash?.rawValue == hash.string(), "canonical hash") }
        if let favorite = object.take("favorite") { try check((state?.favorites[identity] == true) == favorite.boolean(), "favourite overlay") }
        if let error = object.take("error") { try check((prompt.lastError?.code.rawValue ?? "none") == error.string(), "per-file issue") }
        if let origin = object.take("origin") {
            let actual: String
            switch prompt.origin { case .conflictOf(let id): actual = "conflict_of " + id.rawValue; case .rescued: actual = "rescued"; case nil: actual = "none" }
            try check(actual == expand(origin.string()), "prompt origin")
        }
        if let history = object.take("history") { try check(device.library.history(for: identity).count == history.integer(), "identity history migration") }
        if let uses = object.take("uses") { try check(device.usage.useEvents(for: identity).count == uses.integer(), "identity usage migration") }
        if let values = object.take("values") { try check(device.values.rememberedValues(for: identity) == values.object().mapValues { try $0.string() }, "identity values migration") }
        try object.finish()
    }

    private func bind(_ name: String, _ value: String) throws {
        guard symbols[name] == nil || symbols[name] == value else { throw ScenarioFailure.invalid("symbol rebound") }
        symbols[name] = value
    }

    private func expand(_ text: String) throws -> String {
        var result = text
        while let start = result.range(of: "${"), let end = result.range(of: "}", range: start.upperBound..<result.endIndex) {
            let name = String(result[start.upperBound..<end.lowerBound])
            guard let value = symbols[name], !value.contains("${") else { throw ScenarioFailure.invalid("unknown symbolic reference") }
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: value)
        }
        guard !result.contains("${") else { throw ScenarioFailure.invalid("unterminated symbolic reference") }
        return result
    }

    private func expand(_ value: ScenarioValue) throws -> ScenarioValue {
        switch value {
        case .string(let text): return .string(try expand(text))
        case .array(let items): return .array(try items.map(expand))
        case .object(let fields): return .object(try fields.mapValues(expand))
        default: return value
        }
    }

    private func check(_ success: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try success() else { throw ScenarioFailure.invalid(reason) }
    }
}
