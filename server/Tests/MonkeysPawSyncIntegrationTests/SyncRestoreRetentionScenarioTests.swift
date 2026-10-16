import Foundation
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import SQLKit
@testable import SyncScenarioSupport
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawServer

/// The transport retains this deployment, so an offline restore replaces the
/// database and router without replacing any client's persisted account.
final class ScenarioDeployment: TestClientProtocol, @unchecked Sendable {
    private var storage: ServerDatabase?
    let directory: URL
    let clock: ScenarioClock
    var client: (any TestClientProtocol)?
    var port: Int? { client?.port }
    var configuration: DatabaseConfiguration { .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]) }

    init(database: ServerDatabase, directory: URL, clock: ScenarioClock) {
        storage = database
        self.directory = directory
        self.clock = clock
    }

    func database() throws -> ServerDatabase {
        guard let storage else { throw ScenarioFailure.invalid("deployment is stopped") }
        return storage
    }

    func executeRequest(uri: String, method: HTTPTypes.HTTPRequest.Method, headers: HTTPFields,
                        body: ByteBuffer?) async throws -> TestResponse {
        guard let client, storage != nil else { throw ScenarioFailure.invalid("deployment is stopped") }
        return try await client.executeRequest(uri: uri, method: method, headers: headers, body: body)
    }

    func shutdown() async {
        if let storage { await storage.shutdown() }
        storage = nil
        client = nil
    }

    func restore(from backup: URL) async throws -> DatabaseBackupResult {
        // The exclusive restore lock must see no live database users.
        try scenarioCheck(port == nil, "restore requires router-only deployment")
        await shutdown()
        let result = try await ServerBackupService(configuration: configuration).restore(from: backup.path)
        let database = try await ServerDatabase.open(configuration: configuration)
        storage = database
        try await database.migrate()
        let accounts = AccountService(database: database, clock: { [clock] in clock.now() })
        let sessions = SessionService(database: database, clock: { [clock] in clock.now() })
        let app = makeApplication(configuration: try .init(environment: ["MONKEYSPAW_LOG_LEVEL": "critical"]),
                                  accounts: accounts, sessions: sessions)
        client = try await ScenarioPeerApplication(base: app).test(.router) { $0 }
        return result
    }
}

enum ScenarioMaintenanceAction {
    case advance(server: String, seconds: Int)
    case retention(server: String, clockOffset: Int, expected: [String: ScenarioValue])
    case backup(server: String, name: String)
    case restore(server: String, name: String, bind: String)
    case cursor(device: String, scope: String, value: String?)
    case serverExpect(server: String, scope: String, expected: [String: ScenarioValue])
    case afterResponse(device: String, method: HTTPMethod, path: String, then: [ScenarioStep])
    case collect(device: String, expected: [String: ScenarioValue])

    static func decode(_ action: String, device: String, object: inout ScenarioObject) throws -> Self? {
        switch action {
        case "collect":
            let expected = try object.required("expected").object()
            let required: Set<String> = ["scope", "head", "cursor", "item_count"]
            guard required.isSubset(of: Set(expected.keys)), Set(expected.keys).isSubset(of: required.union(["prompts", "absent"])) else {
                throw ScenarioFailure.invalid("unknown or missing collection checkpoint")
            }
            _ = try expected["scope"]!.string()
            _ = try expected["cursor"]!.string()
            _ = try expected["head"]!.integer()
            _ = try expected["item_count"]!.integer()
            if let prompts = expected["prompts"] {
                for prompt in try prompts.array() {
                    let fields = try prompt.object()
                    guard Set(fields.keys) == ["id", "rev", "path", "content"] else { throw ScenarioFailure.invalid("invalid collected prompt checkpoint") }
                    for (key, value) in fields { if key == "rev" { _ = try value.integer() } else { _ = try value.string() } }
                }
            }
            if let absent = expected["absent"] { _ = try absent.array().map { try $0.string() } }
            return .collect(device: device, expected: expected)
        case "advance_server":
            let seconds = try object.required("seconds").integer()
            guard seconds > 0 else { throw ScenarioFailure.invalid("clock advance must be positive") }
            return .advance(server: try object.string("server"), seconds: seconds)
        case "retention":
            let server = try object.string("server")
            let offset = try object.take("clock_offset_seconds")?.integer() ?? 0
            let expected = try counts(object.required("expected"), allowed: ["changes", "floors", "tombstones", "revisions"])
            return .retention(server: server, clockOffset: offset, expected: expected)
        case "backup", "restore":
            let server = try object.string("server")
            let name = try object.string("name")
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else {
                throw ScenarioFailure.invalid("invalid backup name")
            }
            if action == "backup" { return .backup(server: server, name: name) }
            return .restore(server: server, name: name, bind: try object.string("bind"))
        case "set_cursor":
            let scope = try object.string("scope")
            let value = try object.required("value")
            if value == .null { return .cursor(device: device, scope: scope, value: nil) }
            let text = try value.string()
            guard !text.isEmpty else { throw ScenarioFailure.invalid("empty cursor") }
            return .cursor(device: device, scope: scope, value: text)
        case "server_expect":
            let server = try object.string("server")
            let scope = try object.string("scope")
            let expected = try counts(object.required("expected"), allowed: ["head", "floor", "changes", "tombstones", "revisions", "retired_ids", "snapshots"])
            return .serverExpect(server: server, scope: scope, expected: expected)
        case "after_next_response":
            guard let method = HTTPMethod(rawValue: try object.string("method")) else { throw ScenarioFailure.invalid("unknown HTTP method") }
            let path = try object.string("path")
            let value = try object.required("then")
            if case .object = value {
                let step = try ScenarioDecoder.decodeStep(value)
                switch step {
                case .http, .write, .expect: return .afterResponse(device: device, method: method, path: path, then: [step])
                default: throw ScenarioFailure.invalid("response hook requires HTTP, write or expect")
                }
            }
            let then = try value.array().map(ScenarioDecoder.decodeStep)
            guard !then.isEmpty, then.allSatisfy({ step in
                switch step {
                case .http, .expect: return true
                case .maintenance(_, .advance), .maintenance(_, .retention), .maintenance(_, .serverExpect): return true
                default: return false
                }
            }) else { throw ScenarioFailure.invalid("invalid response hook action") }
            return .afterResponse(device: device, method: method, path: path, then: then)
        default: return nil
        }
    }

    private static func counts(_ value: ScenarioValue, allowed: Set<String>) throws -> [String: ScenarioValue] {
        let fields = try value.object()
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: allowed) else { throw ScenarioFailure.invalid("unknown maintenance checkpoint") }
        for field in fields.values { _ = try field.integer() }
        return fields
    }
}

extension ScenarioRunner {
    func executeMaintenance(_ action: ScenarioMaintenanceAction) async throws {
        switch action {
        case .collect(let name, let expected):
            let device = try device(name)
            guard let account = try device.accounts.loadAccount(), let state = try device.states.loadForAccountTransition(),
                  let secret = try device.secrets.read(account: account.secretAccount, source: .effective) else {
                throw ScenarioFailure.invalid("collection requires account/state")
            }
            let token = try secret.value.withValue { try JSONDecoder().decode(ScenarioValue.self, from: Data($0.utf8)).at("/token").string() }
            let server = try SyncServerURL(account.identity.serverURL.absoluteString)
            let client = SyncHTTPClient(server: server, transport: device.transport,
                credential: .init(server: server, token: SecretValue(token)))
            let collector = SyncPullCollector(client: client, files: device.data, userID: account.identity.userID)
            let request = SyncAPI.PullRequest(databaseID: state.databaseID?.uuidString.lowercased(),
                cursors: Dictionary(uniqueKeysWithValues: state.cursors.map { ($0.key.rawValue, $0.value) }))
            let collection = try await collector.collect(request, deadline: .now.advanced(by: .seconds(30)))
            defer { try? collection.discard() }
            let key = try SyncScopeKey(expand(expected["scope"]!.string()))
            guard let scope = collection.scopes[key] else { throw ScenarioFailure.invalid("missing collected scope") }
            try check(scope.head == Int64(expected["head"]!.integer()) && scope.cursor == expand(expected["cursor"]!.string()), "collected head/cursor")
            var items: [String: SyncAPI.FeedPrompt] = [:]
            try collection.forEachPage(mode: .snapshot) { page in
                guard page.scope == key else { return }
                for value in page.items {
                    guard case .upsert(_, let prompt) = value.item, items.updateValue(prompt, forKey: prompt.id) == nil else {
                        throw ScenarioFailure.invalid("duplicate or non-upsert snapshot item")
                    }
                }
            }
            try check(items.count == expected["item_count"]!.integer(), "collected item count")
            if let prompts = expected["prompts"] {
                for value in try prompts.array() {
                    let fields = try value.object()
                    guard let prompt = items[try expand(fields["id"]!.string())] else { throw ScenarioFailure.invalid("missing collected prompt") }
                    try check(prompt.rev == Int64(fields["rev"]!.integer()) && prompt.path.utf8.elementsEqual(expand(fields["path"]!.string()).utf8)
                        && prompt.content.utf8.elementsEqual(expand(fields["content"]!.string()).utf8), "exact collected prompt")
                }
            }
            if let absent = expected["absent"] {
                for id in try absent.array() { try check(items[expand(id.string())] == nil, "discarded snapshot item") }
            }
            try check(device.states.loadForAccountTransition() == state, "collection never commits state")
            try collection.discard()
            try check(device.data.listFiles().allSatisfy { !$0.relativePath.hasPrefix("sync/pull-") }, "collection staging cleanup")
        case .advance(let server, let seconds): try deployment(server).clock.advance(TimeInterval(seconds))
        case .retention(let server, let offset, let expected):
            let server = try deployment(server)
            // A separate maintenance clock can age immutable events while a
            // feed request's frozen manifest is still within its lifetime.
            let now = server.clock.now().addingTimeInterval(TimeInterval(offset))
            let counts = try await RetentionService(database: server.database(), clock: { now },
                logger: ServerLogging.logger(level: .critical)).run()
            let actual = ["changes": counts.changes, "floors": counts.floors, "tombstones": counts.tombstones, "revisions": counts.revisions]
            for (key, value) in expected { try check(actual[key] == value.integer(), "retention " + key) }
        case .backup(let server, let name):
            let key = server + "." + name
            try check(maintenanceBackups[key] == nil, "backup name reused")
            let path = root.appendingPathComponent(key + ".db")
            _ = try await ServerBackupService(configuration: deployment(server).configuration).backup(to: path.path)
            maintenanceBackups[key] = path
        case .restore(let server, let name, let symbol):
            guard let backup = maintenanceBackups[server + "." + name] else { throw ScenarioFailure.invalid("unknown backup") }
            await stop()
            let deployment = try deployment(server)
            let oldID = try await MetaRepository(database: deployment.database()).databaseID()
            let result = try await deployment.restore(from: backup)
            try check(result.databaseID != oldID.uuidString && result.previousPath != nil, "real restore identity/recovery copy")
            try bind(symbol, result.databaseID.lowercased())
        case .cursor(let name, let scope, let value):
            let device = try device(name)
            guard let state = try device.states.loadForAccountTransition() else { throw ScenarioFailure.invalid("cursor requires state") }
            try device.states.update(for: state.binding) { $0.cursors[try SyncScopeKey(expand(scope))] = value }
        case .serverExpect(let server, let scope, let expected):
            let database = try deployment(server).database()
            let scope = try SyncScopeKey(expand(scope)).rawValue
            for (key, value) in expected {
                let query: SQLQueryString
                switch key {
                case "head": query = "SELECT COALESCE((SELECT head_seq FROM scope_heads WHERE scope_key = \(bind: scope)), 0) AS value"
                case "floor": query = "SELECT COALESCE((SELECT floor_seq FROM scope_floors WHERE scope_key = \(bind: scope)), 0) AS value"
                case "changes": query = "SELECT COUNT(*) AS value FROM changes WHERE scope_key = \(bind: scope)"
                case "snapshots": query = "SELECT COUNT(*) AS value FROM snapshots WHERE scope_key = \(bind: scope)"
                case "tombstones": query = "SELECT COUNT(*) AS value FROM prompts WHERE deleted_at IS NOT NULL AND (CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END) = \(bind: scope)"
                case "revisions": query = "SELECT COUNT(*) AS value FROM prompt_revisions WHERE (CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END) = \(bind: scope)"
                case "retired_ids": query = "SELECT COUNT(*) AS value FROM retired_prompt_ids WHERE (CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END) = \(bind: scope)"
                default: throw ScenarioFailure.invalid("unconsumed server checkpoint")
                }
                let actual = try await database.read { sql in
                    guard let row = try await sql.raw(query).first() else { throw ScenarioFailure.invalid("missing server checkpoint row") }
                    return try row.decode(column: "value", as: Int.self)
                }
                try check(actual == value.integer(), "server " + key)
            }
        case .afterResponse(let name, let method, let path, let then):
            try device(name).transport.after(method: method, path: expand(path)) { [self] in
                for action in then { try await execute(action) }
            }
        }
    }

    private func deployment(_ name: String) throws -> ScenarioDeployment {
        guard let server = deployments[name + ".test"] else { throw ScenarioFailure.invalid("unknown deployment") }
        return server
    }
}

func scenarioCheck(_ success: @autoclosure () throws -> Bool, _ reason: String) throws {
    guard try success() else { throw ScenarioFailure.invalid(reason) }
}

final class SyncRestoreRetentionScenarioTests: XCTestCase {
    func testFinalRestoreCheckpointRejectsRepeated409() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync/22-restore-lower-head.json")
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(Data(contentsOf: file)).first {
            $0.id == "22-restore-CAS-race-preserves-loser-on-409"
        })
        var steps = baseline.steps
        let retry = ScenarioHTTP(device: "b", method: .put, path: "/api/v1/prompts/${prompt.q}",
            body: .object(["base_rev": .integer(1), "scope": .string("user"), "path": .string("Q.md"),
                "content": .string("---\nid: ${prompt.q}\n---\nLocal retained\n")]), status: 409, expected: [:], bindings: [:])
        steps.insert(.http(retry), at: steps.count - 1)
        let scenario = SyncScenario(id: "negative-restore-retry", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts, steps: steps)
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Repeated 409 passed the final restore checkpoint")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("request count"), error.description)
        }
    }

    func testFailedHookCheckpointCannotBeSwallowedAsOffline() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync/01-round-trip.json")
        let original = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: file))
        let first = try original.at("/cases/0/steps/0")
        let login = try original.at("/cases/0/steps/1")
        let bad: ScenarioValue = .object(["action": .string("expect"), "device": .string("a"),
            "expected": .object(["file_count": .integer(0)])])
        let terminal: ScenarioValue = .object(["action": .string("expect"), "device": .string("a"),
            "expected": .object(["file_count": .integer(1)])])
        for then in [bad, .array([bad])] {
            let hook: ScenarioValue = .object(["action": .string("after_next_response"), "device": .string("a"),
                "method": .string("POST"), "path": .string("/api/v1/sync/pull"), "then": then])
            let changed = try original.patching(["/cases/0/id": .string("negative-hook-checkpoint"),
                "/cases/0/steps": .array([first, hook, login, terminal])])
            let scenario = try ScenarioDecoder.decode(JSONEncoder().encode(changed))[0]
            do {
                try await SyncServerHarness.run(scenario)
                XCTFail("A failed hook checkpoint passed as an offline sync")
            } catch let error as ScenarioFailure {
                XCTAssertTrue(error.description.contains("file count"))
            }
        }
    }

    func testMaintenanceDecoderRejectsUnusedAndInvalidMembers() {
        for step in [
            "{\"action\":\"advance_server\",\"device\":\"a\",\"server\":\"main\",\"seconds\":0}",
            "{\"action\":\"retention\",\"device\":\"a\",\"server\":\"main\",\"expected\":{\"unused\":0}}",
            "{\"action\":\"restore\",\"device\":\"a\",\"server\":\"main\",\"name\":\"../bad\",\"bind\":\"db\"}",
            "{\"action\":\"set_cursor\",\"device\":\"a\",\"scope\":\"s\",\"value\":\"\",\"unused\":true}"
        ] {
            XCTAssertThrowsError(try ScenarioDecoder.decodeStep(JSONDecoder().decode(ScenarioValue.self, from: Data(step.utf8))))
        }
    }
}
