import Foundation
import XCTest
@testable import MonkeysPawCore

/// Like import fixtures, path cases have their own source format and strict
/// consumer. The generic corpus dispatcher accounts for every returned file.
enum SyncPathFixtureCorpus {
    enum Failure: Error {
        case invalidCorpus
        case unexpectedResult(String)
    }

    private struct GoldenText: Decodable {
        struct Content: Decodable {
            let path: String
            let path_key: String
        }
        let expected: Content
    }

    static func consume(at root: URL) throws -> (cases: Int, files: [String]) {
        try require(.typeDirectory, at: root)
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { throw Failure.invalidCorpus }
        var consumed = Set<RelativePath>()
        var files = [String]()

        for name in names {
            let directory = root.appendingPathComponent(name)
            try require(.typeDirectory, at: directory)
            let entries = try manager.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }
            for entry in entries { try require(.typeRegular, at: directory.appendingPathComponent(entry)) }
            guard Set(entries.map { RelativePath($0) }) == ["case.json", "path.txt"] else {
                throw Failure.invalidCorpus
            }
            let json = try Data(contentsOf: directory.appendingPathComponent("case.json"))
            let envelope = try object(JSONSerialization.jsonObject(with: json))
            try keys(envelope, ["schema", "category", "source", "scope", "expected"])
            guard try integer(envelope["schema"]) == 1,
                  envelope["category"] as? String == "paths", envelope["source"] as? String == "path.txt",
                  let scopeText = envelope["scope"] as? String,
                  let scope = SyncPathValidator.Scope(rawValue: scopeText) else { throw Failure.invalidCorpus }

            let data = try Data(contentsOf: directory.appendingPathComponent("path.txt"))
            // String(data:encoding:) can strip a leading BOM. Decode scalars
            // without that transformation, then reject any invalid UTF-8 bytes.
            let path = String(decoding: data, as: UTF8.self)
            guard data == Data(path.utf8) else { throw Failure.invalidCorpus }
            let expected = try object(envelope["expected"])
            if let issueValue = expected["issue"] {
                try keys(expected, ["issue"])
                let issue = try object(issueValue)
                try keys(issue, ["code", "segment"])
                guard let codeText = issue["code"] as? String,
                      let code = SyncPathIssueCode(rawValue: codeText) else { throw Failure.invalidCorpus }
                let segment: Int?
                switch code {
                case .emptySegment, .dotSegment, .backslash, .controlCharacter, .trailingDotOrSpace, .segmentTooLong:
                    let index = try integer(issue["segment"])
                    guard index >= 0 else { throw Failure.invalidCorpus }
                    segment = index
                default:
                    guard issue["segment"] is NSNull else { throw Failure.invalidCorpus }
                    segment = nil
                }
                do {
                    _ = try SyncPathValidator.validate(path, scope: scope)
                    throw Failure.unexpectedResult(name)
                } catch let actual as SyncPathIssue {
                    guard actual.code == code, actual.segmentIndex == segment else {
                        throw Failure.unexpectedResult(name)
                    }
                }
            } else {
                try keys(expected, ["path", "path_key"])
                guard expected["path"] is String, expected["path_key"] is String else { throw Failure.invalidCorpus }
                // Keep golden strings in Swift; compare bytes, never String's
                // canonical equality or NSString's bridged normalization.
                let golden = try JSONDecoder().decode(GoldenText.self, from: json).expected
                let actual = try SyncPathValidator.validate(path, scope: scope)
                guard actual.path.utf8.elementsEqual(golden.path.utf8),
                      actual.pathKey.utf8.elementsEqual(golden.path_key.utf8) else {
                    throw Failure.unexpectedResult(name)
                }
            }

            for entry in ["case.json", "path.txt"] {
                let file = name + "/" + entry
                guard consumed.insert(RelativePath(file)).inserted else { throw Failure.invalidCorpus }
                files.append(file)
            }
        }
        return (names.count, files)
    }

    private static func require(_ type: FileAttributeType, at url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type else {
            throw Failure.invalidCorpus
        }
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Failure.invalidCorpus }
        return object
    }

    private static func keys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw Failure.invalidCorpus }
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              let integer = value as? Int, number.doubleValue == Double(integer) else { throw Failure.invalidCorpus }
        return integer
    }
}

final class SyncPathConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/paths")
    }

    func testEveryPortablePathFixture() throws {
        let result = try SyncPathFixtureCorpus.consume(at: root)
        XCTAssertGreaterThan(result.cases, 0)
        XCTAssertEqual(result.files.count, result.cases * 2)
        XCTAssertEqual(Set(result.files.map { RelativePath($0) }).count, result.files.count)
        print("Consumed \(result.cases) sync path fixtures (\(result.files.count) files).")
    }

    func testRejectsUnknownMissingOrOrphanFilesAndDirectories() throws {
        let mutations: [(String, (URL) throws -> Void)] = [
            ("root file", { try Data().write(to: $0.appendingPathComponent("unknown.txt")) }),
            ("unknown case file", { try Data().write(to: $0.appendingPathComponent("basic/unknown.txt")) }),
            ("orphan source", { try Data().write(to: $0.appendingPathComponent("basic/orphan.md")) }),
            ("orphan path", { try Data().write(to: $0.appendingPathComponent("basic/orphan.txt")) }),
            ("additional JSON", { try Data().write(to: $0.appendingPathComponent("basic/extra.json")) }),
            ("missing source", { try FileManager.default.removeItem(at: $0.appendingPathComponent("basic/path.txt")) }),
            ("missing expectation", { try FileManager.default.removeItem(at: $0.appendingPathComponent("basic/case.json")) }),
            ("nested directory", { try FileManager.default.createDirectory(at: $0.appendingPathComponent("basic/nested"),
                                                                           withIntermediateDirectories: false) }),
            ("empty case", { try FileManager.default.createDirectory(at: $0.appendingPathComponent("empty-case"),
                                                                     withIntermediateDirectories: false) }),
            ("empty corpus", { directory in
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            }),
            ("source directory", { directory in
                let path = directory.appendingPathComponent("basic/path.txt")
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            })
        ]
        for (label, mutate) in mutations {
            try withCopy { copy in
                try mutate(copy)
                XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: copy), label)
            }
        }
    }

    func testRejectsSymlinksAtEveryLevel() throws {
        for relative in ["basic/path.txt", "basic/case.json", "basic"] {
            try withCopy { copy in
                let path = copy.appendingPathComponent(relative)
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent(relative))
                XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: copy), relative)
            }
        }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("sync-path-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: link))
    }

    func testRejectsUnknownAndMissingEnvelopeMembersAndTypes() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schema"] = 2 }),
            ("boolean schema", { $0["schema"] = true }),
            ("string schema", { $0["schema"] = "1" }),
            ("category", { $0["category"] = "import" }),
            ("scope", { $0["scope"] = "private" }),
            ("boolean scope", { $0["scope"] = false }),
            ("source", { $0["source"] = "../path.txt" }),
            ("unknown member", { $0["unknown"] = 1 }),
            ("null expectation", { $0["expected"] = NSNull() })
        ]
        for (label, mutate) in mutations { try mutateJSON("basic", label: label, mutate) }
        for key in ["schema", "category", "source", "scope", "expected"] {
            try mutateJSON("basic", label: "missing " + key) { $0.removeValue(forKey: key) }
        }
    }

    func testRejectsUnknownMissingAndIllTypedSuccessMembers() throws {
        try mutateExpected("basic") { $0["unknown"] = 1 }
        for key in ["path", "path_key"] {
            try mutateExpected("basic") { $0.removeValue(forKey: key) }
            try mutateExpected("basic") { $0[key] = true }
            try mutateExpected("basic") { $0[key] = NSNull() }
        }
        try mutateExpected("basic") { $0["issue"] = ["code": "path.empty", "segment": NSNull()] }
    }

    func testRejectsUnknownMissingAndIllTypedDiagnosticMembers() throws {
        try mutateExpected("nul") { $0["unknown"] = 1 }
        try mutateExpected("nul") { $0["path"] = "a.md" }
        try mutateExpected("nul") { $0["issue"] = [] }
        try mutateIssue("nul") { $0["unknown"] = 1 }
        for key in ["code", "segment"] { try mutateIssue("nul") { $0.removeValue(forKey: key) } }
        for value: Any in ["path.unknown", true, NSNull()] { try mutateIssue("nul") { $0["code"] = value } }
        for value: Any in [true, "0", -1, 0.5, NSNull()] { try mutateIssue("nul") { $0["segment"] = value } }
        try mutateIssue("empty") { $0["segment"] = 0 }
        try mutateIssue("empty") { $0["segment"] = false }
    }

    func testRejectsInvalidUTF8AndByteDifferentGoldenText() throws {
        try withCopy { copy in
            try Data([0xC3, 0x28]).write(to: copy.appendingPathComponent("basic/path.txt"))
            XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: copy))
        }
        try mutateExpected("unicode-nfd") { $0["path"] = "Cafe\u{301}/E\u{301}.md" }
        try mutateExpected("unicode-nfd") { $0["path_key"] = "cafe\u{301}/e\u{301}.md" }
    }

    func testHiddenMetadataMatchesTheImportFixtureConvention() throws {
        let baseline = try SyncPathFixtureCorpus.consume(at: root)
        try withCopy { copy in
            for directory in [copy, copy.appendingPathComponent("basic")] {
                for name in [".DS_Store", "._path.txt"] {
                    try Data([0xFF]).write(to: directory.appendingPathComponent(name))
                }
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden"),
                                                        withIntermediateDirectories: false)
            }
            let actual = try SyncPathFixtureCorpus.consume(at: copy)
            XCTAssertEqual(actual.cases, baseline.cases)
            XCTAssertEqual(actual.files, baseline.files)
            try Data().write(to: copy.appendingPathComponent("basic/orphan.txt"))
            XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: copy))
        }
    }

    private func mutateExpected(_ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
        try mutateJSON(name, label: name + " expectation") { envelope in
            var expected = envelope["expected"] as! [String: Any]
            mutate(&expected)
            envelope["expected"] = expected
        }
    }

    private func mutateIssue(_ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
        try mutateExpected(name) { expected in
            var issue = expected["issue"] as! [String: Any]
            mutate(&issue)
            expected["issue"] = issue
        }
    }

    private func mutateJSON(_ name: String, label: String, _ mutate: (inout [String: Any]) -> Void) throws {
        try withCopy { copy in
            let file = copy.appendingPathComponent(name + "/case.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            mutate(&envelope)
            try JSONSerialization.data(withJSONObject: envelope).write(to: file)
            XCTAssertThrowsError(try SyncPathFixtureCorpus.consume(at: copy), label)
        }
    }

    private func withCopy(_ work: (URL) throws -> Void) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("sync-path-corpus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: root, to: copy)
        try work(copy)
    }
}
