import Foundation
@testable import MonkeysPawCore

enum ScenarioFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let reason): return "Sync scenario: " + reason } }
}

/// Data-only JSON contract. No Swift types or actual credentials enter fixtures.
enum ScenarioValue: Codable, Equatable, Sendable {
    case object([String: ScenarioValue]), array([ScenarioValue]), string(String), integer(Int64), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ScenarioValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ScenarioValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func object() throws -> [String: ScenarioValue] {
        guard case .object(let value) = self else { throw ScenarioFailure.invalid("expected object") }
        return value
    }
    func string() throws -> String {
        guard case .string(let value) = self else { throw ScenarioFailure.invalid("expected string") }
        return value
    }
    func integer() throws -> Int {
        guard case .integer(let value) = self, let number = Int(exactly: value), number >= 0 else {
            throw ScenarioFailure.invalid("expected nonnegative integer")
        }
        return number
    }
    func boolean() throws -> Bool {
        guard case .bool(let value) = self else { throw ScenarioFailure.invalid("expected boolean") }
        return value
    }
    func array() throws -> [ScenarioValue] {
        guard case .array(let value) = self else { throw ScenarioFailure.invalid("expected array") }
        return value
    }
}

/// Removing fields as they are decoded makes unconsumed members a hard error.
struct ScenarioObject {
    private var fields: [String: ScenarioValue]
    init(_ value: ScenarioValue) throws { fields = try value.object() }
    mutating func take(_ key: String) -> ScenarioValue? { fields.removeValue(forKey: key) }
    mutating func required(_ key: String) throws -> ScenarioValue {
        guard let value = take(key) else { throw ScenarioFailure.invalid("missing " + key) }
        return value
    }
    mutating func string(_ key: String) throws -> String { try required(key).string() }
    mutating func strings(_ key: String) throws -> [String] { try required(key).array().map { try $0.string() } }
    func finish() throws {
        guard fields.isEmpty else { throw ScenarioFailure.invalid("unknown or unconsumed member") }
    }
}

struct SyncScenario {
    let id: String
    let now: Date
    let servers: [String]
    let users: [String]
    let devices: [(name: String, seed: UInt64)]
    let prompts: [String: String]
    let steps: [ScenarioStep]
}

enum ScenarioStep {
    case login(device: String, user: String, server: String)
    case write(device: String, path: String, content: String)
    case remove(device: String, path: String)
    case move(device: String, source: String, destination: String)
    case symlink(device: String, path: String)
    case sync(String), restart(String), signOut(String), resetMetrics(String)
    case bindPrompt(device: String, path: String, name: String)
    case seedKeyed(device: String, path: String)
    case favorite(device: String, id: String, value: Bool)
    case http(ScenarioHTTP)
    case beforeRequest(device: String, method: HTTPMethod, path: String, then: ScenarioHTTP)
    case rewrite(ScenarioRewrite)
    case expect(ScenarioExpectation)
}

struct ScenarioHTTP {
    let device: String
    let method: HTTPMethod
    let path: String
    let body: ScenarioValue?
    let status: Int
    let expected: [String: ScenarioValue]
    let bindings: [String: String]
}

struct ScenarioRewrite {
    let device: String
    let response: Bool
    let method: HTTPMethod
    let path: String
    let patch: [String: ScenarioValue]
}

struct ScenarioExpectation {
    let device: String
    let fields: [String: ScenarioValue]
}

enum ScenarioDecoder {
    static let expectationKeys: Set<String> = ["files", "absent", "file_count", "status", "blocking_issue", "state",
        "prompt_count", "cursor_count", "held_count", "account_user", "writes", "trash_count", "requests", "history_count"]

    static func decode(_ data: Data) throws -> [SyncScenario] {
        var envelope = try ScenarioObject(JSONDecoder().decode(ScenarioValue.self, from: data))
        guard try envelope.required("schema").integer() == 1, try envelope.string("category") == "sync" else {
            throw ScenarioFailure.invalid("unsupported schema or category")
        }
        let cases = try envelope.required("cases").array()
        try envelope.finish()
        guard !cases.isEmpty else { throw ScenarioFailure.invalid("empty case set") }
        return try cases.map { value in
            var object = try ScenarioObject(value)
            let id = try object.string("id")
            let text = try object.string("now")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let now = formatter.date(from: text), formatter.string(from: now) == text else {
                throw ScenarioFailure.invalid("clock must use exact UTC seconds")
            }
            let servers = try object.strings("servers")
            let users = try object.strings("users")
            let devices = try object.required("devices").array().map { item in
                var device = try ScenarioObject(item)
                let name = try device.string("name")
                let seed = try device.required("entropy_seed").integer()
                try device.finish()
                guard seed > 0, seed < Int(UInt32.max) else { throw ScenarioFailure.invalid("entropy seed out of range") }
                return (name: name, seed: UInt64(seed))
            }
            let prompts = try object.required("prompts").object().mapValues { try $0.string() }
            for id in prompts.values { _ = try SyncIdentifiers.ulid(id) }
            let steps = try object.required("steps").array().map(decodeStep)
            try object.finish()
            for names in [servers, users, devices.map(\.name), Array(prompts.keys)] {
                guard Set(names).count == names.count, names.allSatisfy(validName) else {
                    throw ScenarioFailure.invalid("invalid or duplicate symbolic name")
                }
            }
            guard !id.isEmpty, !servers.isEmpty, users.count >= 2, devices.count >= 2,
                  Set(devices.map(\.seed)).count == devices.count, steps.contains(where: { if case .expect = $0 { return true }; return false }) else {
                throw ScenarioFailure.invalid("missing scenario participants or checkpoints")
            }
            return SyncScenario(id: id, now: now, servers: servers, users: users, devices: devices, prompts: prompts, steps: steps)
        }
    }

    static func decodeStep(_ value: ScenarioValue) throws -> ScenarioStep {
        var object = try ScenarioObject(value)
        let action = try object.string("action")
        let device = try object.string("device")
        let step: ScenarioStep
        switch action {
        case "login": step = .login(device: device, user: try object.string("user"), server: try object.string("server"))
        case "write": step = .write(device: device, path: try object.string("path"), content: try object.string("content"))
        case "remove": step = .remove(device: device, path: try object.string("path"))
        case "move": step = .move(device: device, source: try object.string("source"), destination: try object.string("destination"))
        case "symlink": step = .symlink(device: device, path: try object.string("path"))
        case "sync": step = .sync(device)
        case "restart": step = .restart(device)
        case "sign_out": step = .signOut(device)
        case "reset_metrics": step = .resetMetrics(device)
        case "bind_prompt": step = .bindPrompt(device: device, path: try object.string("path"), name: try object.string("name"))
        case "seed_keyed": step = .seedKeyed(device: device, path: try object.string("path"))
        case "favorite": step = .favorite(device: device, id: try object.string("id"), value: try object.required("value").boolean())
        case "http":
            let method = try method(object.string("method"))
            let path = try object.string("path")
            let body = object.take("body")
            let status = try object.required("status").integer()
            let expected = try object.take("expected")?.object() ?? [:]
            let bindings = try object.take("bind")?.object().mapValues { try $0.string() } ?? [:]
            step = .http(.init(device: device, method: method, path: path, body: body, status: status, expected: expected, bindings: bindings))
        case "before_next_request":
            let method = try method(object.string("method"))
            let path = try object.string("path")
            guard case .http(let next) = try decodeStep(object.required("then")) else {
                throw ScenarioFailure.invalid("network race must execute an HTTP action")
            }
            step = .beforeRequest(device: device, method: method, path: path, then: next)
        case "rewrite_next_request", "rewrite_next_response":
            let method = try method(object.string("method"))
            let path = try object.string("path")
            let patch = try object.required("patch").object()
            guard !patch.isEmpty else { throw ScenarioFailure.invalid("empty network patch") }
            step = .rewrite(.init(device: device, response: action == "rewrite_next_response", method: method, path: path, patch: patch))
        case "expect":
            let fields = try object.required("expected").object()
            guard !fields.isEmpty, Set(fields.keys).isSubset(of: expectationKeys) else { throw ScenarioFailure.invalid("unknown or empty expectation") }
            try validateExpectations(fields)
            step = .expect(.init(device: device, fields: fields))
        default: throw ScenarioFailure.invalid("unknown action")
        }
        try object.finish()
        return step
    }

    private static func method(_ text: String) throws -> HTTPMethod {
        guard let method = HTTPMethod(rawValue: text) else { throw ScenarioFailure.invalid("unknown HTTP method") }
        return method
    }

    private static func validName(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func validateExpectations(_ fields: [String: ScenarioValue]) throws {
        for (key, value) in fields {
            switch key {
            case "files", "state", "requests":
                let allowed: Set<String>
                if key == "files" { allowed = ["path", "content", "mode"] }
                else if key == "state" { allowed = ["id", "scope", "path", "rev", "hash", "favorite", "error", "origin", "history", "uses", "values"] }
                else { allowed = ["method", "path", "status", "count", "body", "local_exists"] }
                let items = try value.array()
                guard !items.isEmpty else { throw ScenarioFailure.invalid("empty checkpoint list") }
                for item in items {
                    let fields = try item.object()
                    let required: Set<String> = key == "files" ? ["path", "content"] : key == "state" ? ["id", "scope", "path", "rev"] : ["method", "path", "count"]
                    guard Set(fields.keys).isSubset(of: allowed), required.isSubset(of: Set(fields.keys)) else {
                        throw ScenarioFailure.invalid("unknown or missing checkpoint member")
                    }
                    for (name, field) in fields {
                        switch name {
                        case "rev", "history", "uses", "status", "count": _ = try field.integer()
                        case "favorite": _ = try field.boolean()
                        case "values": _ = try field.object().mapValues { try $0.string() }
                        case "body": _ = try field.object()
                        default: _ = try field.string()
                        }
                    }
                }
            case "absent": _ = try value.array().map { try $0.string() }
            case "status", "blocking_issue", "account_user": _ = try value.string()
            default: _ = try value.integer()
            }
        }
    }
}

enum SyncScenarioCorpus {
    static func load(at directory: URL) throws -> (files: Set<String>, cases: [SyncScenario]) {
        let type = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard type.isDirectory == true, type.isSymbolicLink != true else { throw ScenarioFailure.invalid("invalid sync corpus directory") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let names = Set(files.map(\.lastPathComponent))
        let required: Set<String> = ["01-round-trip.json", "11-path-clashes.json", "12-untrusted-paths.json", "13-copied-library.json",
            "14-account-change.json", "15-group-favourite.json", "16-invalid-content.json"]
        guard required.isSubset(of: names) else { throw ScenarioFailure.invalid("missing acceptance fixture") }
        var ids = Set<String>()
        var cases: [SyncScenario] = []
        for file in files {
            let type = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard type.isRegularFile == true, type.isSymbolicLink != true, file.pathExtension == "json" else {
                throw ScenarioFailure.invalid("unknown sync corpus file")
            }
            let decoded = try ScenarioDecoder.decode(Data(contentsOf: file))
            for scenario in decoded {
                guard scenario.id.hasPrefix(String(file.lastPathComponent.prefix(2)) + "-"), ids.insert(scenario.id).inserted else {
                    throw ScenarioFailure.invalid("orphan or duplicate case ID")
                }
            }
            cases += decoded
        }
        return (names, cases)
    }
}

/// RFC 6901 pointers are used for HTTP checks/bindings and one-shot patches.
extension ScenarioValue {
    func at(_ pointer: String) throws -> ScenarioValue {
        try replacing(pointer, with: nil).value
    }
    func patching(_ patches: [String: ScenarioValue]) throws -> ScenarioValue {
        try patches.keys.sorted().reduce(self) { try $0.replacing($1, with: patches[$1]).root }
    }
    private func replacing(_ pointer: String, with replacement: ScenarioValue?) throws -> (root: ScenarioValue, value: ScenarioValue) {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { throw ScenarioFailure.invalid("invalid JSON pointer") }
        let parts = pointer.isEmpty ? [] : pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
        func visit(_ node: ScenarioValue, _ index: Int) throws -> (ScenarioValue, ScenarioValue) {
            guard index < parts.count else { return (replacement ?? node, node) }
            switch node {
            case .object(var fields):
                guard let child = fields[parts[index]] else { throw ScenarioFailure.invalid("missing JSON pointer target") }
                let (next, value) = try visit(child, index + 1)
                fields[parts[index]] = next
                return (.object(fields), value)
            case .array(var items):
                guard let offset = Int(parts[index]), items.indices.contains(offset) else { throw ScenarioFailure.invalid("invalid array pointer") }
                let (next, value) = try visit(items[offset], index + 1)
                items[offset] = next
                return (.array(items), value)
            default: throw ScenarioFailure.invalid("noncontainer JSON pointer")
            }
        }
        let (root, value) = try visit(self, 0)
        return (root, value)
    }
}
