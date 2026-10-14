import Foundation
import XCTest
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import MonkeysPawCore
@testable import MonkeysPawServer

final class SyncScenarioTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync")
    }

    func testEverySyncFixtureExecutesAgainstTheRouter() async throws {
        let corpus = try SyncScenarioCorpus.load(at: fixtures)
        let ids = Set(corpus.cases.map(\.id))
        var executed = Set<String>()
        for scenario in corpus.cases {
            print("Executing sync scenario " + scenario.id)
            fflush(stdout)
            do {
                try await SyncServerHarness.run(scenario)
                guard executed.insert(scenario.id).inserted else { throw ScenarioFailure.invalid("duplicate case execution") }
                FileHandle.standardOutput.write(Data(("Executed sync scenario " + scenario.id + " against the real router.\n").utf8))
            } catch {
                XCTFail((error as? ScenarioFailure)?.description ?? scenario.id + ": setup failed (" + String(describing: type(of: error)) + ")")
            }
        }
        XCTAssertEqual(executed, ids)
        if executed == ids { print("Executed \(executed.count) sync scenarios from \(corpus.files.count) files against the real router.") }
    }

    func testCorpusRejectsOrphansMissingFixturesAndDuplicateIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-corpus-" + UUID().uuidString)
        try FileManager.default.copyItem(at: fixtures, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("orphan.md")
        try Data().write(to: orphan)
        XCTAssertThrowsError(try SyncScenarioCorpus.load(at: root))
        try FileManager.default.removeItem(at: orphan)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("01-round-trip.json"))
        XCTAssertThrowsError(try SyncScenarioCorpus.load(at: root))
        try FileManager.default.removeItem(at: link)
        let file = root.appendingPathComponent("01-round-trip.json")
        let original = try Data(contentsOf: file)
        var object = try JSONDecoder().decode(ScenarioValue.self, from: original).object()
        let cases = try object["cases"]!.array()
        object["cases"] = .array(cases + cases)
        try JSONEncoder().encode(ScenarioValue.object(object)).write(to: file)
        XCTAssertThrowsError(try SyncScenarioCorpus.load(at: root))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try SyncScenarioCorpus.load(at: root))
    }

    func testDecoderRejectsUnknownAndUnusedMembers() throws {
        let file = fixtures.appendingPathComponent("01-round-trip.json")
        let baseline = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: file))
        let mutations: [[String: ScenarioValue]] = [
            ["/schema": .integer(2)], ["/category": .string("other")], ["/cases": .array([])],
            ["/cases/0/steps/0/action": .string("unknown")], ["/cases/0/now": .string("2026-10-14T00:00:00+00:00")]
        ]
        for patch in mutations { XCTAssertThrowsError(try ScenarioDecoder.decode(JSONEncoder().encode(baseline.patching(patch)))) }
        var object = try baseline.object()
        object["extra"] = .bool(true)
        XCTAssertThrowsError(try ScenarioDecoder.decode(JSONEncoder().encode(ScenarioValue.object(object))))
        for step in [
            ScenarioValue.object(["action": .string("sync"), "device": .string("a"), "unused": .bool(true)]),
            .object(["action": .string("expect"), "device": .string("a"), "expected": .object(["unused": .integer(0)])]),
            .object(["action": .string("expect"), "device": .string("a"), "expected": .object(["files": .array([.object(["path": .string("a.md"), "content": .string("x"), "unused": .bool(true)])])])])
        ] { XCTAssertThrowsError(try ScenarioDecoder.decodeStep(step)) }
    }

    func testHTTPCheckpointsCompareExactUTF8Strings() {
        XCTAssertNotEqual(ScenarioValue.string("Caf\u{e9}"), .string("Cafe\u{301}"))
        XCTAssertNotEqual(ScenarioValue.object(["content": .string("Caf\u{e9}")]), .object(["content": .string("Cafe\u{301}")]))
    }

    func testRequestPresenceCheckpointRequiresAPath() throws {
        for value in [ScenarioValue.string("Clash (2).md"), .bool(true)] {
            let step = ScenarioValue.object(["action": .string("expect"), "device": .string("a"),
                "expected": .object(["requests": .array([.object(["method": .string("PUT"), "path": .string("*"),
                    "count": .integer(1), "local_exists": value])])])])
            if case .string = value { XCTAssertNoThrow(try ScenarioDecoder.decodeStep(step)) }
            else { XCTAssertThrowsError(try ScenarioDecoder.decodeStep(step)) }
        }
    }

    func testDecoderRequiresDeviceCheckpointsAlongsideHTTPAssertions() throws {
        let original = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: fixtures.appendingPathComponent("01-round-trip.json")))
        let steps = try original.at("/cases/0/steps").array().filter { try $0.at("/action").string() != "expect" }
        let changed = try original.patching(["/cases/0/steps": .array(steps)])
        XCTAssertThrowsError(try ScenarioDecoder.decode(JSONEncoder().encode(changed)))
    }

    func testIncorrectHTTPCheckpointFailsAfterRealRouterExecution() async throws {
        let original = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: fixtures.appendingPathComponent("01-round-trip.json")))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(JSONEncoder().encode(original)).first)
        let steps = baseline.steps.map { step -> ScenarioStep in
            guard case .http(let action) = step else { return step }
            return .http(.init(device: action.device, method: action.method, path: action.path, body: action.body,
                status: action.status, expected: ["/path": .string("incorrect.md")], bindings: action.bindings))
        }
        let scenario = SyncScenario(id: "negative-http-checkpoint", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts, steps: steps)
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Incorrect HTTP checkpoint passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("HTTP JSON checkpoint"))
        }
    }

    func testInvalidHTTPActionURLFailsWithoutCrashing() async throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("01-round-trip.json"))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(original).first)
        let scenario = SyncScenario(id: "invalid-http-url", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts,
            steps: [.login(device: "a", user: "alice", server: "main"), .http(.init(device: "a", method: .get, path: ":bad", body: nil,
                status: 200, expected: [:], bindings: [:]))])
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Invalid HTTP URL passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("HTTP action has an unusable request path"))
        }
    }

    func testIncorrectRacingHTTPCheckpointFailsAfterRealRouterExecution() async throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("11-path-clashes.json"))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(original).first { $0.id == "11-path-clash-exact" })
        let steps = baseline.steps.prefix(4).map { step -> ScenarioStep in
            guard case .beforeRequest(let device, let method, let path, let skip, .http(let action)) = step else { return step }
            return .beforeRequest(device: device, method: method, path: path, skip: skip, then: .http(.init(device: action.device,
                method: action.method, path: action.path, body: action.body, status: action.status,
                expected: ["/rev": .integer(999)], bindings: [:])))
        }
        let scenario = SyncScenario(id: "negative-racing-http-checkpoint", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts,
            steps: steps + [.sync("a"), .expect(.init(device: "a", fields: ["status": .string("offline")]))])
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Incorrect racing HTTP checkpoint passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("HTTP JSON checkpoint"), error.description)
        }
    }

    func testInvalidResponseRewriteCannotBecomeExpectedOfflineStatus() async throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("01-round-trip.json"))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(original).first)
        let scenario = SyncScenario(id: "negative-response-rewrite", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts,
            steps: [.login(device: "a", user: "alice", server: "main"),
                .rewrite(.init(device: "a", phase: .response, method: .post, path: "/api/v1/sync/pull",
                    patch: ["/missing": .string("invalid pointer")])),
                .sync("a"), .expect(.init(device: "a", fields: ["status": .string("offline")]))])
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Invalid response rewrite passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("missing JSON pointer target"))
        }
    }

    func testFailedRacingHTTPRequestCannotBecomeExpectedSyncError() async throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("11-path-clashes.json"))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(original).first { $0.id == "11-path-clash-exact" })
        let steps = baseline.steps.prefix(4).map { step -> ScenarioStep in
            guard case .beforeRequest(let device, let method, let path, let skip, .http(let action)) = step else { return step }
            return .beforeRequest(device: device, method: method, path: path, skip: skip, then: .http(.init(device: action.device,
                method: action.method, path: action.path,
                body: .object(["content": .string(String(repeating: "x", count: SyncAPI.requestEnvelopeMaxBytes + 1))]),
                status: action.status, expected: [:], bindings: [:])))
        }
        let scenario = SyncScenario(id: "negative-racing-http-request", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts,
            steps: steps + [.sync("a"), .expect(.init(device: "a", fields: ["status": .string("syncError")]))])
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Unexecuted racing HTTP assertion passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("HTTPTransportError"), error.description)
        }
    }

    func testPathClashFileCountRejectsUnlistedDownload() async throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("11-path-clashes.json"))
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(original).first { $0.id == "11-path-clash-last-slot" })
        let scenario = SyncScenario(id: "negative-clash-file-count", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts,
            steps: baseline.steps + [.expect(.init(device: "a", fields: ["file_count": .integer(19)]))])
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Missing downloaded file passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("file count"))
        }
    }

    func testIncorrectExpectedBytesFailAfterRealRouterExecution() async throws {
        let original = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: fixtures.appendingPathComponent("01-round-trip.json")))
        let changed = try original.patching([
            "/cases/0/id": .string("negative-file-checkpoint"),
            "/cases/0/steps/4/expected/files/0/content": .string("intentionally incorrect expected bytes")
        ])
        let scenario = try ScenarioDecoder.decode(JSONEncoder().encode(changed))[0]
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Incorrect checkpoint passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("exact file bytes"))
        }
    }
}
