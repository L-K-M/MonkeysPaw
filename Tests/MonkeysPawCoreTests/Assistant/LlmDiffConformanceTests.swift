import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmDiffConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/llm")
    }

    func testChangedRowsWarningsAndTypedErrorsCannotPass() throws {
        for key in ["text", "originalLine", "placeholderWarnings", "unconsumed"] {
            try withFixture("diff-lines-composed-decomposed") { corpus, directory in
                try mutate(directory) { envelope in
                    var expected = try envelope["expected"]!.object
                    var rows = try expected["rows"]!.array
                    var row = try rows[0].object
                    switch key {
                    case "text": row[key] = .string("e\u{301}\n")
                    case "originalLine": row[key] = .integer(2)
                    case "placeholderWarnings": row[key] = .array([.object(["kind": .string("removed"), "name": .string("fake")])])
                    default: row[key] = .boolean(true)
                    }
                    rows[0] = .object(row)
                    expected["rows"] = .array(rows)
                    envelope["expected"] = .object(expected)
                }
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), key)
            }
        }
        try withFixture("diff-artifact-rename") { corpus, directory in
            try mutate(directory) { envelope in
                var expected = try envelope["expected"]!.object
                expected["placeholderWarnings"] = .array([])
                envelope["expected"] = .object(expected)
            }
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), "aggregate warnings")
        }
        try withFixture("diff-lines-work-over-limit") { corpus, directory in
            try mutate(directory) { $0["expected"] = .object(["error": .string("sourceTooLarge")]) }
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), "typed work error")
        }
    }

    func testClosedReferencesRepeatsAndNestedWarningsAreEnforced() throws {
        for (key, value) in [("originalRepeat", LlmFixtureJSON.boolean(false)), ("mergedRepeat", .integer(0)),
                             ("mergedRepeat", .integer(262146)), ("original", .string("../original.txt")),
                             ("merged", .string("original.txt")), ("operation", .string("future"))] {
            try withFixture("diff-lines-empty") { corpus, directory in
                try mutate(directory) { $0[key] = value }
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), key)
            }
        }
        try withFixture("diff-artifact-rename") { corpus, directory in
            try mutate(directory) { envelope in
                var expected = try envelope["expected"]!.object
                var warnings = try expected["placeholderWarnings"]!.array
                var warning = try warnings[0].object
                warning["unconsumed"] = .boolean(true)
                warnings[0] = .object(warning)
                expected["placeholderWarnings"] = .array(warnings)
                envelope["expected"] = .object(expected)
            }
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), "nested warning")
        }
    }

    func testCandidateBytesAndVisibleInventoryAreConsumed() throws {
        for file in ["candidate.md", "original-canonical.md"] {
            try withFixture("diff-artifact-utf8-token-offsets") { corpus, directory in
                try Data("wrong bytes".utf8).write(to: directory.appendingPathComponent(file))
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), file)
            }
        }
        try withFixture("diff-lines-empty") { corpus, directory in
            try Data().write(to: directory.appendingPathComponent("orphan.txt"))
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: corpus), "orphan")
        }
    }

    private func mutate(_ directory: URL, _ change: (inout [String: LlmFixtureJSON]) throws -> Void) throws {
        let url = directory.appendingPathComponent("case.json")
        var envelope = try JSONDecoder().decode(LlmFixtureJSON.self, from: Data(contentsOf: url)).object
        try change(&envelope)
        try LlmFixtureJSON.object(envelope).bytes().write(to: url)
    }

    private func withFixture(_ name: String, _ work: (URL, URL) throws -> Void) throws {
        let corpus = FileManager.default.temporaryDirectory.appendingPathComponent("llm-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: corpus) }
        let directory = corpus.appendingPathComponent(name)
        try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: directory)
        try work(corpus, directory)
    }
}
