import Foundation
import XCTest
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
