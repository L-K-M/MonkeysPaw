import Foundation
import XCTest
@testable import MonkeysPawCore

/// Each case owns its source, optional adoption candidate and expectation.
/// Global dispatch and this consumer both account for every file exactly once.
enum CanonicalFixtureCorpus {
    enum Failure: Error { case invalidCorpus }

    private struct GoldenText: Decodable {
        struct Expected: Decodable {
            let bytes: String
            let body: String
        }
        let expected: Expected
    }

    static func consume(at root: URL) throws -> (cases: Int, files: [String]) {
        try require(.typeDirectory, at: root)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { throw Failure.invalidCorpus }
        var consumed = [String]()
        for name in names {
            let directory = root.appendingPathComponent(name)
            try require(.typeDirectory, at: directory)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
            for file in files { try require(.typeRegular, at: directory.appendingPathComponent(file)) }
            guard files.contains("case.json") else { throw Failure.invalidCorpus }
            let json = try Data(contentsOf: directory.appendingPathComponent("case.json"))
            let envelope = try object(JSONSerialization.jsonObject(with: json))
            try keys(envelope, ["schema", "category", "scope", "source", "expected"], optional: ["comparison"])
            guard let schema = envelope["schema"] as? NSNumber,
                  String(cString: schema.objCType) != "c", schema.doubleValue == 1,
                  envelope["category"] as? String == "canonical",
                  let scopeName = envelope["scope"] as? String,
                  let scope = CanonicalForm.Scope(rawValue: scopeName) else { throw Failure.invalidCorpus }
            let source = try sourceName(envelope["source"])
            var references = [source]
            let comparison = try envelope["comparison"].map(object)
            if let comparison {
                try keys(comparison, ["source", "equivalent"])
                references.append(try sourceName(comparison["source"]))
                _ = try boolean(comparison["equivalent"])
            }
            guard Set(references.map { RelativePath($0) }).count == references.count,
                  Set(files.map { RelativePath($0) }) == Set((["case.json"] + references).map { RelativePath($0) }) else {
                throw Failure.invalidCorpus
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(source))
            let expected = try object(envelope["expected"])
            if let error = expected["error"] {
                try keys(expected, ["error"])
                guard comparison == nil else { throw Failure.invalidCorpus }
                let failure = try expectedError(object(error))
                do {
                    _ = try canonical(data, scope: scope, filename: source)
                    XCTFail("Expected canonical refusal: " + name)
                } catch let actual as PromptWriteError {
                    XCTAssertEqual(actual, failure, name)
                }
            } else {
                try validateExpectation(expected)
                // Decode byte-sensitive text without NSString bridging, which
                // can remove a leading BOM from a JSON string on Linux.
                let golden = try JSONDecoder().decode(GoldenText.self, from: json).expected
                let actual = try canonical(data, scope: scope, filename: source)
                XCTAssertEqual(actual.bytes, Data(golden.bytes.utf8), name)
                XCTAssertEqual(actual.canonicalHash, expected["canonicalHash"] as? String, name)
                let favorite = expected["favorite"] is NSNull ? nil : try boolean(expected["favorite"])
                XCTAssertEqual(actual.favorite, favorite, name)
                let warnings = actual.warnings.map { ["code": $0.code.rawValue, "severity": $0.severity.rawValue] }
                XCTAssertEqual(warnings, expected["warnings"] as? [[String: String]], name)
                let document = PromptCodec.parse(String(decoding: data, as: UTF8.self), filename: source)
                XCTAssertEqual(Data(document.body.utf8), Data(golden.body.utf8), name)
                let stored = PromptCodec.parse(String(decoding: actual.bytes, as: UTF8.self), filename: source)
                XCTAssertEqual(Data(stored.body.utf8), Data(golden.body.utf8), name)
                if scope == .group {
                    let repeated = try CanonicalForm.group(actual.bytes, filename: source)
                    XCTAssertEqual(repeated.bytes, actual.bytes, name)
                    XCTAssertEqual(repeated.canonicalHash, actual.canonicalHash, name)
                    XCTAssertNil(repeated.favorite, name)
                    XCTAssertFalse(repeated.warnings.contains { $0.code == .groupPrivateRemoved }, name)
                } else {
                    XCTAssertEqual(actual.bytes, data, name)
                    XCTAssertNil(actual.favorite, name)
                }
                if let comparison {
                    let candidate = try Data(contentsOf: directory.appendingPathComponent(references[1]))
                    let equivalent = try boolean(comparison["equivalent"])
                    XCTAssertEqual(try CanonicalForm.equivalentForAdoption(data, candidate, scope: scope, filename: source),
                                   equivalent, name)
                    XCTAssertEqual(try CanonicalForm.equivalentForAdoption(candidate, data, scope: scope, filename: source),
                                   equivalent, name)
                }
            }
            consumed += (["case.json"] + references).map { name + "/" + $0 }
        }
        return (names.count, consumed)
    }

    private static func canonical(_ data: Data, scope: CanonicalForm.Scope, filename: String) throws -> CanonicalForm {
        switch scope {
        case .group: return try CanonicalForm.group(data, filename: filename)
        case .user: return try CanonicalForm.user(data, filename: filename)
        }
    }

    private static func validateExpectation(_ expected: [String: Any]) throws {
        try keys(expected, ["bytes", "body", "canonicalHash", "favorite", "warnings"])
        guard expected["bytes"] is String, expected["body"] is String,
              let hash = expected["canonicalHash"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let warnings = expected["warnings"] as? [[String: Any]] else { throw Failure.invalidCorpus }
        if !(expected["favorite"] is NSNull) { _ = try boolean(expected["favorite"]) }
        for warning in warnings {
            try keys(warning, ["code", "severity"])
            guard let code = warning["code"] as? String, let parsed = PromptIssueCode(rawValue: code),
                  [.invalidPlaceholder, .unusedField, .groupPrivateRemoved].contains(parsed),
                  warning["severity"] as? String == "warning" else { throw Failure.invalidCorpus }
        }
    }

    private static func expectedError(_ error: [String: Any]) throws -> PromptWriteError {
        switch error["code"] as? String {
        case "invalid_prompt":
            try keys(error, ["code"])
            return .invalidPrompt
        case "source_too_large":
            try keys(error, ["code"])
            return .sourceTooLarge
        case "unsupported_format":
            try keys(error, ["code", "version"])
            guard let spelling = error["version"] as? String,
                  let version = PromptFormatVersion(decimalValue: spelling), version.isFuture,
                  version.decimalValue == spelling else { throw Failure.invalidCorpus }
            return .unsupportedFormat(version)
        default: throw Failure.invalidCorpus
        }
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw Failure.invalidCorpus }
        return value
    }

    private static func keys(_ object: [String: Any], _ required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw Failure.invalidCorpus }
    }

    private static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { throw Failure.invalidCorpus }
        return number.boolValue
    }

    private static func sourceName(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.hasPrefix("."), value.hasSuffix(".md"),
              !value.contains("/"), !value.contains("\\") else { throw Failure.invalidCorpus }
        return value
    }

    private static func require(_ type: FileAttributeType, at url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type else {
            throw Failure.invalidCorpus
        }
    }
}

final class CanonicalConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/canonical")
    }

    func testEveryPortableCanonicalFixture() throws {
        let result = try CanonicalFixtureCorpus.consume(at: root)
        XCTAssertGreaterThan(result.cases, 0)
        XCTAssertEqual(Set(result.files.map { RelativePath($0) }).count, result.files.count)
        print("Consumed \(result.cases) canonical fixtures (\(result.files.count) files).")
    }

    func testHiddenMetadataIsIgnoredWithoutWeakeningStrictDispatch() throws {
        let original = try CanonicalFixtureCorpus.consume(at: root)
        try withCopy { copy in
            // A complete hidden case must also stay outside enumeration.
            try FileManager.default.copyItem(at: copy.appendingPathComponent("empty"),
                                            to: copy.appendingPathComponent(".hidden"))
            for directory in [copy, copy.appendingPathComponent("group-strip")] {
                for name in [".DS_Store", "._source.md", ".gitattributes"] {
                    try Data([0xff]).write(to: directory.appendingPathComponent(name))
                }
            }
            try FileManager.default.createDirectory(at: copy.appendingPathComponent("group-strip/.hidden"),
                                                    withIntermediateDirectories: false)
            let actual = try CanonicalFixtureCorpus.consume(at: copy)
            XCTAssertEqual(actual.cases, original.cases)
            XCTAssertEqual(actual.files, original.files)
            try Data().write(to: copy.appendingPathComponent("group-strip/orphan.md"))
            XCTAssertThrowsError(try CanonicalFixtureCorpus.consume(at: copy))
        }
    }

    func testGitMetadataIsOptionalAndIgnored() throws {
        let baseline = try CanonicalFixtureCorpus.consume(at: root)
        let mutations: [(URL) throws -> Void] = [
            { try FileManager.default.removeItem(at: $0.appendingPathComponent(".gitattributes")) },
            { copy in
                let attributes = copy.appendingPathComponent(".gitattributes")
                try FileManager.default.removeItem(at: attributes)
                try FileManager.default.createSymbolicLink(atPath: attributes.path, withDestinationPath: "group-strip/source.md")
            },
            { copy in
                let attributes = copy.appendingPathComponent(".gitattributes")
                try FileManager.default.removeItem(at: attributes)
                try FileManager.default.createDirectory(at: attributes, withIntermediateDirectories: false)
            }
        ]
        for mutation in mutations {
            try withCopy { copy in
                try mutation(copy)
                let actual = try CanonicalFixtureCorpus.consume(at: copy)
                XCTAssertEqual(actual.cases, baseline.cases)
                XCTAssertEqual(actual.files, baseline.files)
            }
        }
    }

    func testRejectsUnknownMissingOrphanLinkedAndNestedFiles() throws {
        let mutations: [(URL) throws -> Void] = [
            { try Data().write(to: $0.appendingPathComponent("unknown.txt")) },
            { try Data().write(to: $0.appendingPathComponent("group-strip/unknown.txt")) },
            { try Data().write(to: $0.appendingPathComponent("group-strip/orphan.md")) },
            { try Data().write(to: $0.appendingPathComponent("group-strip/extra.json")) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("group-strip/source.md")) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("group-strip/candidate.md")) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("group-strip/case.json")) },
            { try FileManager.default.createDirectory(at: $0.appendingPathComponent("group-strip/nested.md"), withIntermediateDirectories: false) },
            { try FileManager.default.createDirectory(at: $0.appendingPathComponent("empty-case"), withIntermediateDirectories: false) },
            { copy in
                let source = copy.appendingPathComponent("group-strip/source.md")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "candidate.md")
            },
            { copy in
                let directory = copy.appendingPathComponent("group-strip")
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: "plain-bom")
            },
            { copy in
                for name in try FileManager.default.contentsOfDirectory(atPath: copy.path) where !name.hasPrefix(".") {
                    try FileManager.default.removeItem(at: copy.appendingPathComponent(name))
                }
            }
        ]
        for (index, mutation) in mutations.enumerated() {
            try withCopy { copy in
                try mutation(copy)
                XCTAssertThrowsError(try CanonicalFixtureCorpus.consume(at: copy), "mutation \(index)")
            }
        }
    }

    func testRejectsUnknownMissingAndWronglyTypedCaseMembers() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schema"] = 2 }, { $0["schema"] = true }, { $0["schema"] = 1.5 },
            { $0["category"] = "format" }, { $0["scope"] = "private" }, { $0["unknown"] = 1 },
            { $0.removeValue(forKey: "source") }, { $0["source"] = "../source.md" },
            { $0["source"] = "nested\\source.md" }, { $0["source"] = "case.json" },
            { $0["comparison"] = ["source": "source.md", "equivalent": true] },
            { $0["comparison"] = ["source": "candidate.md", "equivalent": 1] },
            { $0["comparison"] = ["source": "candidate.md", "equivalent": true, "unknown": 1] },
            { $0["comparison"] = ["source": "candidate.md"] },
            { fixture in
                var expected = fixture["expected"] as! [String: Any]
                expected["unknown"] = 1
                fixture["expected"] = expected
            },
            { fixture in
                var expected = fixture["expected"] as! [String: Any]
                expected.removeValue(forKey: "body")
                fixture["expected"] = expected
            },
            { fixture in
                var expected = fixture["expected"] as! [String: Any]
                expected["favorite"] = 1
                fixture["expected"] = expected
            },
            { fixture in
                var expected = fixture["expected"] as! [String: Any]
                expected["canonicalHash"] = String(repeating: "G", count: 64)
                fixture["expected"] = expected
            }
        ]
        for mutation in mutations { try mutateJSON("group-strip", mutation) }
        let warningMutations: [[String: Any]] = [
            ["code": "unknown", "severity": "warning"],
            ["code": "metadata.group_private_removed", "severity": "error"],
            ["code": "metadata.group_private_removed", "severity": "warning", "unknown": 1],
            ["code": "metadata.group_private_removed"]
        ]
        for warning in warningMutations {
            try mutateJSON("group-strip") { fixture in
                var expected = fixture["expected"] as! [String: Any]
                expected["warnings"] = [warning]
                fixture["expected"] = expected
            }
        }
        let errorMutations: [[String: Any]] = [
            ["code": "unknown"], ["code": "invalid_prompt", "unknown": 1],
            ["code": "unsupported_format"], ["code": "unsupported_format", "version": "1"],
            ["code": "unsupported_format", "version": 2]
        ]
        for error in errorMutations {
            try mutateJSON("invalid-private") { $0["expected"] = ["error": error] }
        }
    }

    private func mutateJSON(_ name: String, _ mutation: (inout [String: Any]) -> Void) throws {
        try withCopy { copy in
            let file = copy.appendingPathComponent(name + "/case.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            mutation(&envelope)
            try JSONSerialization.data(withJSONObject: envelope).write(to: file)
            XCTAssertThrowsError(try CanonicalFixtureCorpus.consume(at: copy), name)
        }
    }

    private func withCopy(_ work: (URL) throws -> Void) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-contract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: root, to: copy)
        try work(copy)
    }
}
