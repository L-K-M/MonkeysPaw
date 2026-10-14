import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/llm")
    }

    func testEveryLlmExpectationAndByteGoldenIsExecuted() throws {
        let coverage = try LlmFixtureCorpus.consume(at: root)
        print("llm: \(coverage.cases) cases / \(coverage.files.count) files; \(coverage.expectations) expectations; pending 0.")
    }

    func testUnknownKindsFalseSchemasAndUnconsumedExpectationsCannotPass() throws {
        let mutations: [(String, (inout [String: LlmFixtureJSON]) throws -> Void)] = [
            ("unknown kind", { $0["kind"] = .string("exchange") }),
            ("false schema", { $0["schema"] = .boolean(false) }),
            ("future schema", { $0["schema"] = .integer(2) }),
            ("unknown output", { $0["outputKind"] = .string("other") }),
            ("unknown envelope", { $0["unconsumed"] = .boolean(true) }),
            ("unsafe reference", { $0["source"] = .string("../output.txt") }),
            ("duplicate reference", { $0["prefix"] = .object(["source": $0["source"]!, "repeat": .integer(1)]) }),
            ("unconsumed expectation", { envelope in
                var expected = try envelope["expected"]!.object
                expected["unconsumed"] = .boolean(true)
                envelope["expected"] = .object(expected)
            }),
            ("unconsumed nested expectation", { envelope in
                var expected = try envelope["expected"]!.object
                var result = try expected["result"]!.object
                var artifact = try result["artifact"]!.object
                artifact["unconsumed"] = .boolean(true)
                result["artifact"] = .object(artifact)
                expected["result"] = .object(result)
                envelope["expected"] = .object(expected)
            }),
            ("wrong typed golden", { envelope in
                var expected = try envelope["expected"]!.object
                var result = try expected["result"]!.object
                var artifact = try result["artifact"]!.object
                artifact["notes"] = .string("wrong golden")
                result["artifact"] = .object(artifact)
                expected["result"] = .object(result)
                envelope["expected"] = .object(expected)
            }),
            ("wrong parser golden", { envelope in
                var expected = try envelope["expected"]!.object
                expected["parsed"] = .boolean(false)
                envelope["expected"] = .object(expected)
            })
        ]
        for (label, mutate) in mutations {
            try withTemporaryCorpus { directory in
                let url = directory.appendingPathComponent("artifact-all-fields/case.json")
                var envelope = try JSONDecoder().decode(LlmFixtureJSON.self, from: Data(contentsOf: url)).object
                try mutate(&envelope)
                try LlmFixtureJSON.object(envelope).bytes().write(to: url)
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), label)
            }
        }
    }

    func testOrphansSymlinksMissingSourcesAndFalseByteGoldensCannotPass() throws {
        let mutations: [(String, (URL) throws -> Void)] = [
            ("orphan", { try Data().write(to: $0.appendingPathComponent("orphan.txt")) }),
            ("nested file", { try FileManager.default.createDirectory(at: $0.appendingPathComponent("nested.txt"), withIntermediateDirectories: false) }),
            ("missing source", { try FileManager.default.removeItem(at: $0.appendingPathComponent("output.txt")) }),
            ("source symlink", { directory in
                let source = directory.appendingPathComponent("output.txt")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "recovered.json")
            }),
            ("false recovered bytes", { try Data("{}".utf8).write(to: $0.appendingPathComponent("recovered.json")) })
        ]
        for (label, mutate) in mutations {
            try withTemporaryCorpus { directory in
                try mutate(directory.appendingPathComponent("artifact-all-fields"))
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), label)
            }
        }
        try withTemporaryCorpus { directory in
            try Data("{}".utf8).write(to: directory.appendingPathComponent("schema-artifact/schema.json"))
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), "false schema bytes")
        }
    }

    private func withTemporaryCorpus(_ work: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("llm-contract-" + UUID().uuidString)
        try FileManager.default.copyItem(at: root, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try work(directory)
    }
}
