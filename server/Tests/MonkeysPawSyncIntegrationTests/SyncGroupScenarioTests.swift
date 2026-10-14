import Foundation
@testable import SyncScenarioSupport
import XCTest
@testable import MonkeysPawCore

extension ScenarioDecoder {
    static func validateGroupCheckpoint(_ key: String, _ value: ScenarioValue) throws {
        let entries = try value.array()
        guard !entries.isEmpty else { throw ScenarioFailure.invalid("empty group/page checkpoint") }
        for entry in entries {
            var object = try ScenarioObject(entry)
            if key == "groups" {
                for field in ["id", "name", "folder", "role"] { _ = try object.string(field) }
            } else {
                _ = try object.required("item_count").integer()
                _ = try object.required("has_more").boolean()
                for field in ["min_bytes", "max_bytes"] { if let value = object.take(field) { _ = try value.integer() } }
                if let removed = object.take("removed") { _ = try removed.array().map { try $0.string() } }
                if let scopes = object.take("scopes") {
                    for scope in try scopes.array() {
                        var fields = try ScenarioObject(scope)
                        _ = try fields.string("key")
                        _ = try fields.string("mode")
                        try fields.finish()
                    }
                }
                if let contains = object.take("contains") {
                    for item in try contains.array() {
                        var fields = try ScenarioObject(item)
                        for field in ["id", "scope", "kind"] { _ = try fields.string(field) }
                        try fields.finish()
                    }
                }
                if let absent = object.take("absent_ids") { _ = try absent.array().map { try $0.string() } }
            }
            try object.finish()
        }
    }
}

extension ScenarioRunner {
    /// Compact fixture templates still issue and check every individual router
    /// request; explicit IDs make the series portable to the Kotlin runner.
    func httpSeries(_ action: ScenarioHTTP, ids: [String]) async throws {
        func substituting(_ value: ScenarioValue, id: String, index: Int) -> ScenarioValue {
            switch value {
            case .string(let text): return .string(text.replacingOccurrences(of: "${item.id}", with: id)
                .replacingOccurrences(of: "${item.index}", with: String(index)))
            case .array(let items): return .array(items.map { substituting($0, id: id, index: index) })
            case .object(let fields): return .object(fields.mapValues { substituting($0, id: id, index: index) })
            default: return value
            }
        }
        for (index, id) in ids.enumerated() {
            do {
                try await http(ScenarioHTTP(device: action.device, method: action.method,
                    path: try substituting(.string(action.path), id: id, index: index).string(),
                    body: action.body.map { substituting($0, id: id, index: index) }, status: action.status,
                    expected: action.expected.mapValues { substituting($0, id: id, index: index) }, bindings: [:]))
            } catch let error as ScenarioFailure {
                throw ScenarioFailure.invalid("HTTP series item \(index): " + error.description)
            }
        }
    }

    func expectGroups(_ key: String, _ value: ScenarioValue, state: SyncState?, device: ScenarioDevice) throws {
        if key == "group_count" { try check((state?.groups.count ?? 0) == value.integer(), "group count"); return }
        if key == "groups" {
            for entry in try value.array() {
                var fields = try ScenarioObject(entry)
                let id = try SyncIdentifiers.ulid(expand(fields.string("id")))
                guard let group = state?.groups[id] else { throw ScenarioFailure.invalid("missing group state") }
                try check(group.name.utf8.elementsEqual(expand(fields.string("name")).utf8), "group name")
                try check(group.folder.utf8.elementsEqual(expand(fields.string("folder")).utf8), "group folder")
                try check(group.role.rawValue == fields.string("role"), "group role")
                try fields.finish()
            }
            return
        }
        let pages = device.transport.traces.filter { $0.pull != nil }
        let expectations = try value.array()
        try check(pages.count == expectations.count, "pull page count")
        for (trace, entry) in zip(pages, expectations) {
            guard let pull = trace.pull else { throw ScenarioFailure.invalid("missing real pull") }
            var fields = try ScenarioObject(entry)
            try check(pull.scopes.reduce(0) { $0 + $1.items.count } == fields.required("item_count").integer(), "page item budget")
            try check(pull.scopes.contains(where: \.hasMore) == fields.required("has_more").boolean(), "page continuation")
            if let minimum = fields.take("min_bytes") { try check(trace.responseBytes >= minimum.integer(), "page byte lower bound") }
            if let maximum = fields.take("max_bytes") { try check(trace.responseBytes <= maximum.integer(), "page byte upper bound") }
            if let removed = fields.take("removed") {
                try check(pull.removed.sorted() == removed.array().map { try expand($0.string()) }.sorted(), "removed scopes")
            }
            if let scopes = fields.take("scopes") {
                for entry in try scopes.array() {
                    var scope = try ScenarioObject(entry)
                    let key = try expand(scope.string("key"))
                    try check(pull.scopes.first(where: { $0.identity.key == key })?.mode.rawValue == scope.string("mode"), "scope feed mode")
                    try scope.finish()
                }
            }
            if let contains = fields.take("contains") {
                for entry in try contains.array() {
                    var item = try ScenarioObject(entry)
                    let id = try expand(item.string("id"))
                    let key = try expand(item.string("scope"))
                    let kind = try item.string("kind")
                    let found = pull.scopes.first(where: { $0.identity.key == key })?.items.contains { value in
                        switch value {
                        case .upsert(_, let prompt): return kind == "upsert" && prompt.id == id
                        case .delete(_, let deleted): return kind == "delete" && deleted == id
                        case .moveOut(_, let moved): return kind == "move_out" && moved == id
                        }
                    } ?? false
                    try check(found, "required move/feed event")
                    try item.finish()
                }
            }
            if let absent = fields.take("absent_ids") {
                for id in try absent.array() {
                    let id = try SyncIdentifiers.ulid(expand(id.string())).rawValue
                    try check(!pull.scopes.flatMap(\.items).contains { value in
                        switch value {
                        case .upsert(_, let prompt): return prompt.id == id
                        case .delete(_, let deleted), .moveOut(_, let deleted): return deleted == id
                        }
                    }, "unauthorized feed identity")
                }
            }
            try fields.finish()
        }
    }
}

final class SyncGroupScenarioTests: XCTestCase {
    func testMissingMoveEventCheckpointFailsAfterRealHTTP() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync/20-move-echo-pages.json")
        let envelope = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: fixture))
        var scenario = try envelope.at("/cases/0").object()
        var steps = try scenario["steps"]!.array()
        let checkpoint = try XCTUnwrap(steps.firstIndex { value in
            (try? value.at("/expected/pages/0/contains/0/kind")) == .string("move_out")
        })
        steps[checkpoint] = try steps[checkpoint].patching(["/expected/pages/0/contains/0/kind": .string("delete")])
        scenario["steps"] = .array(steps)
        let changed = ScenarioValue.object(["schema": .integer(1), "category": .string("sync"), "cases": .array([.object(scenario)])])
        do {
            try await SyncServerHarness.run(ScenarioDecoder.decode(JSONEncoder().encode(changed))[0])
            XCTFail("Incorrect event checkpoint passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("required move/feed event"))
        }
    }

    func testGroupAndPageCheckpointsRejectUnknownMembers() throws {
        for (key, entry) in [
            ("groups", ScenarioValue.object(["id": .string("g"), "name": .string("Team"), "folder": .string("Team"),
                "role": .string("viewer"), "unused": .bool(true)])),
            ("pages", .object(["item_count": .integer(200), "has_more": .bool(true), "unused": .bool(true)]))
        ] {
            XCTAssertThrowsError(try ScenarioDecoder.decodeStep(.object(["action": .string("expect"), "device": .string("a"),
                "expected": .object([key: .array([entry])])])))
        }
    }
}
