import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmExchangeConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/llm")
    }

    func testClosedExchangeMembersAndChangedRequestAndResultExpectationsFail() throws {
        let paths: [[String]] = [[], ["setup"], ["actions", "0"], ["actions", "0", "profile"], ["actions", "0", "intent"],
            ["actions", "0", "exchanges", "0"], ["actions", "0", "exchanges", "0", "request"],
            ["actions", "0", "exchanges", "0", "response"], ["actions", "0", "expected"], ["actions", "0", "expected", "cache"]]
        for path in paths {
            try withFixture { directory in
                try change(directory, path: path) { value in
                    var value = try value.object
                    value["unconsumed"] = .boolean(true)
                    return .object(value)
                }
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), path.joined(separator: "/"))
            }
        }
        let changes: [([String], LlmFixtureJSON)] = [
            (["schema"], .boolean(true)), (["setup", "nowMonotonicMs"], .boolean(false)),
            (["setup", "capabilityState"], .object([:])), (["actions", "0", "budgetMs"], .boolean(false)),
            (["actions", "0", "exchanges", "0", "request", "deadlineMs"], .integer(299_999)),
            (["actions", "0", "exchanges", "0", "request", "requestByteCap"], .integer(3_000_000)),
            (["actions", "0", "exchanges", "0", "request", "headers", "Authorization"], .string("Bearer fixture-only")),
            (["actions", "0", "expected", "requestCount"], .integer(2)),
            (["actions", "0", "intent", "brief"], .string("../brief.txt")),
            (["actions", "0", "expected", "cache", "writes"], .integer(1))
        ]
        for (path, value) in changes {
            try withFixture { directory in
                try change(directory, path: path) { _ in value }
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), path.joined(separator: "/"))
            }
        }
    }

    func testRawGoldensMissingFilesAndOrphansFail() throws {
        for filename in ["1-request.json", "1-expected.json"] {
            try withFixture { directory in
                try Data("{}".utf8).write(to: directory.appendingPathComponent("anthropic-write-official-unset/" + filename))
                XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory), filename)
            }
        }
        try withFixture { directory in
            try FileManager.default.removeItem(at: directory.appendingPathComponent("anthropic-write-official-unset/1-response.bin"))
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory))
        }
        try withFixture { directory in
            try Data().write(to: directory.appendingPathComponent("anthropic-write-official-unset/orphan.bin"))
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory))
        }
    }

    func testCanonicallyEqualHeaderValuesMustStillMatchUTF8Bytes() throws {
        try withFixture { directory in
            try change(directory, path: ["actions", "0", "profile", "key"]) { _ in .string("fixture-only-caf\u{00e9}") }
            try change(directory, path: ["actions", "0", "exchanges", "0", "request", "headers", "x-api-key"]) {
                _ in .string("fixture-only-cafe\u{0301}")
            }
            XCTAssertThrowsError(try LlmFixtureCorpus.consume(at: directory))
        }
    }

    private func change(_ directory: URL, path: [String], transform: (LlmFixtureJSON) throws -> LlmFixtureJSON) throws {
        let url = directory.appendingPathComponent("anthropic-write-official-unset/case.json")
        func replacing(_ value: LlmFixtureJSON, path: ArraySlice<String>) throws -> LlmFixtureJSON {
            guard let first = path.first else { return try transform(value) }
            if case .array(var items) = value {
                let index = Int(first)!
                items[index] = try replacing(items[index], path: path.dropFirst())
                return .array(items)
            }
            var object = try value.object
            object[first] = try replacing(object[first] ?? .null, path: path.dropFirst())
            return .object(object)
        }
        let value = try JSONDecoder().decode(LlmFixtureJSON.self, from: Data(contentsOf: url))
        try replacing(value, path: path[...]).bytes().write(to: url)
    }

    private func withFixture(_ work: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("llm-exchange-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("anthropic-write-official-unset"),
                                        to: directory.appendingPathComponent("anthropic-write-official-unset"))
        try work(directory)
    }
}
