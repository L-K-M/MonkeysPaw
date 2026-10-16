import Foundation
@testable import SyncScenarioSupport
import XCTest
@testable import MonkeysPawCore

extension ScenarioRunner {
    func expectIdentities(_ key: String, _ value: ScenarioValue, state: SyncState?, device: ScenarioDevice) throws {
        switch key {
        case "unique_ids":
            let ids = try device.files.listFiles().compactMap { file in
                PromptCodec.parseFile(try device.files.read(at: file.relativePath),
                    filename: LibraryPath.filename(file.relativePath)).frontMatter.id?.rawValue
            }
            try check((Set(ids).count == ids.count) == value.boolean(), "unique live file identities")
        case "protected_ids":
            for id in try value.array() {
                let id = try SyncIdentifiers.ulid(expand(id.string()))
                try check(!device.files.unprotectedTrashIDs.contains(id.rawValue), "winning identity retired before publication")
            }
        case "state_absent":
            for id in try value.array() {
                let identity = PromptIdentity.assigned(try SyncIdentifiers.ulid(expand(id.string())))
                try check(state?.prompts[identity] == nil, "retired identity still in state")
            }
        default: throw ScenarioFailure.invalid("unknown identity checkpoint")
        }
    }

    /// Both requests enter the real router concurrently. The failed CAS must
    /// describe the committed winner, rather than a fabricated conflict reply.
    func raceHTTP(_ writers: [ScenarioRaceRequest]) async throws {
        let bodies = try writers.map { try expand($0.body) }
        let paths = try writers.map { try expand($0.path) }
        try check(writers.allSatisfy { $0.method == .put } && paths[0] == paths[1], "race must update one prompt")
        try check(bodies[0].at("/base_rev") == bodies[1].at("/base_rev"), "race must share CAS baseline")
        let first = try device(writers[0].device)
        let second = try device(writers[1].device)
        let barrier = ScenarioCASBarrier()
        first.transport.before(method: .put, path: paths[0]) { try await barrier.arrive() }
        second.transport.before(method: .put, path: paths[1]) { try await barrier.arrive() }
        async let left = first.request(method: .put, path: paths[0], body: bodies[0])
        async let right = second.request(method: .put, path: paths[1], body: bodies[1])
        let responses = try await [left, right]
        try check(responses.map(\.statusCode).sorted() == [200, 409], "overlapping CAS must have exactly one winner")
        let winner = responses[0].statusCode == 200 ? 0 : 1
        let loser = 1 - winner
        let accepted = try JSONDecoder().decode(ScenarioValue.self, from: responses[winner].body)
        let conflict = try JSONDecoder().decode(ScenarioValue.self, from: responses[loser].body)
        try check(conflict.at("/code") == .string("conflict"), "loser must receive CAS conflict")
        try check(conflict.at("/head/rev") == accepted.at("/rev"), "conflict revision must be winner's revision")
        for field in ["scope", "path", "content"] {
            try check(conflict.at("/head/" + field) == bodies[winner].at("/" + field), "conflict head must identify winning write")
        }
        try bind("race.winner", writers[winner].device)
        try bind("race.loser", writers[loser].device)
        try bind("race.content", bodies[winner].at("/content").string())
        try bind("race.losing_content", bodies[loser].at("/content").string())
    }
}

private actor ScenarioCASBarrier {
    private var arrivals = 0
    private let deadline = ContinuousClock.now.advanced(by: .seconds(30))

    func arrive() async throws {
        arrivals += 1
        while arrivals < 2 {
            guard ContinuousClock.now < deadline else { throw HTTPTransportError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class SyncConflictMoveScenarioTests: XCTestCase {
    func testNegativeIdentityCheckpointsRejectInvalidIDsAfterRealHTTP() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync")
        for key in ["protected_ids", "absent_ids"] {
            let file = key == "protected_ids" ? "01-round-trip.json" : "20-move-echo-pages.json"
            var scenario = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: root.appendingPathComponent(file)))
                .at("/cases/0").object()
            var steps = try scenario["steps"]!.array()
            if key == "protected_ids" {
                steps.append(.object(["action": .string("expect"), "device": .string("a"),
                    "expected": .object([key: .array([.string("not-a-canonical-id")])])]))
            } else {
                let index = try XCTUnwrap(steps.firstIndex { (try? $0.at("/expected/pages")) != nil })
                var step = try steps[index].object()
                var expected = try step["expected"]!.object()
                var pages = try expected["pages"]!.array()
                var page = try pages[0].object()
                page[key] = .array([.string("not-a-canonical-id")])
                pages[0] = .object(page)
                expected["pages"] = .array(pages)
                step["expected"] = .object(expected)
                steps[index] = .object(step)
            }
            scenario["steps"] = .array(steps)
            let envelope = ScenarioValue.object(["schema": .integer(1), "category": .string("sync"), "cases": .array([.object(scenario)])])
            do {
                try await SyncServerHarness.run(ScenarioDecoder.decode(JSONEncoder().encode(envelope))[0])
                XCTFail("Invalid negative identity passed: " + key)
            } catch is ScenarioFailure { }
        }
    }

    func testNetworkHooksRejectUnsupportedStepsAndExpansionBudgets() throws {
        let then = ScenarioValue.object(["action": .string("sync"), "device": .string("b")])
        for action in ["before_next_request", "after_next_response"] {
            XCTAssertThrowsError(try ScenarioDecoder.decodeStep(.object([
                "action": .string(action), "device": .string("a"), "method": .string("PUT"),
                "path": .string("/api/v1/prompts/p"), "then": then
            ])))
        }
        XCTAssertThrowsError(try ScenarioDecoder.decodeStep(.object([
            "action": .string("bind_text"), "device": .string("a"), "name": .string("large"),
            "unit": .string("é"), "count": .integer(Int64(Limits.maxPromptBytes))
        ])))
    }

    func testRetirementCheckpointRemembersUnprotectedInterval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-retirement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try ScenarioDisk(root: root.appendingPathComponent("library"), trash: root.appendingPathComponent("trash"))
        let id = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
        let bytes = Data(("---\nid: " + id + "\n---\nBody.\n").utf8)
        try files.write(bytes, at: "Old.md")
        try files.trash(at: RelativePath("Old.md"), expecting: .matching(stamp: files.stamp(at: "Old.md")!, bytes: bytes))
        try files.write(bytes, at: "New.md")
        XCTAssertTrue(files.unprotectedTrashIDs.contains(id))
        XCTAssertEqual(try files.listFiles().count, 1)
    }

    func testUnconsumedAcknowledgementLossFailsAfterRealHTTP() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync/01-round-trip.json")
        var envelope = try JSONDecoder().decode(ScenarioValue.self, from: Data(contentsOf: fixture)).object()
        var scenario = try envelope["cases"]!.array()[0].object()
        var steps = try scenario["steps"]!.array()
        steps.insert(.object(["action": .string("drop_next_response"), "device": .string("a"),
            "method": .string("PUT"), "path": .string("/api/v1/prompts/01ARZ3NDEKTSV4RRFFQ69G5FAY")]), at: 0)
        scenario["steps"] = .array(steps)
        envelope["cases"] = .array([.object(scenario)])
        do {
            try await SyncServerHarness.run(ScenarioDecoder.decode(JSONEncoder().encode(ScenarioValue.object(envelope)))[0])
            XCTFail("Unused acknowledgement-loss gate passed")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("unused network mutation"))
        }
    }
}
