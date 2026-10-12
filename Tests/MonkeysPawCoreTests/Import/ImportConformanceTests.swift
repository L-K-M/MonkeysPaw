import Foundation
import XCTest
@testable import MonkeysPawCore

/// Import needs its own source extensions and mapping report; it reuses the
/// ranking category's case-directory shape and the global strict dispatch.
enum ImportFixtureCorpus {
    enum Failure: Error { case invalidCorpus }

    static func consume(at root: URL) throws -> (cases: Int, files: [String]) {
        try require(.typeDirectory, at: root)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        guard !names.isEmpty else { throw Failure.invalidCorpus }
        var consumed: [String] = []
        for name in names {
            let directory = root.appendingPathComponent(name)
            try require(.typeDirectory, at: directory)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for file in files { try require(.typeRegular, at: directory.appendingPathComponent(file)) }
            guard files.contains("case.json") else { throw Failure.invalidCorpus }
            let envelope = try object(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("case.json"))))
            try keys(envelope, ["schema", "category", "source", "expected"], optional: ["repeat"])
            guard try integer(envelope["schema"]) == 1, envelope["category"] as? String == "import",
                  let sourceName = envelope["source"] as? String,
                  !sourceName.contains("/"), ImportFormat.filename(sourceName) != nil,
                  Set(files) == ["case.json", sourceName] else { throw Failure.invalidCorpus }
            let unit = try Data(contentsOf: directory.appendingPathComponent(sourceName))
            guard String(data: unit, encoding: .utf8) != nil else { throw Failure.invalidCorpus }
            let text = String(decoding: unit, as: UTF8.self)
            let count = try envelope["repeat"].map(integer) ?? 1
            let size = unit.count.multipliedReportingOverflow(by: count)
            guard count > 0, !size.overflow, size.partialValue <= Limits.importFileCapBytes + 1 else {
                throw Failure.invalidCorpus
            }
            let data = Data(String(repeating: text, count: count).utf8)
            let expected = try object(envelope["expected"])
            let actual: [String: Any]
            if let refusal = expected["refusal"] {
                try keys(expected, ["refusal"])
                let detail = try object(refusal)
                try keys(detail, ["code", "issues"])
                guard let code = detail["code"] as? String,
                      ["invalidPrompt", "fileTooLarge", "convertedTooLarge"].contains(code),
                      let issues = detail["issues"] as? [String],
                      issues.allSatisfy({ PromptIssueCode(rawValue: $0) != nil }) else { throw Failure.invalidCorpus }
                do {
                    _ = try ImportMapper.map(data, filename: sourceName)
                    XCTFail("Expected import refusal for " + name)
                    actual = [:]
                } catch let reason as ImportSkipReason {
                    actual = ["refusal": failure(reason)]
                }
            } else {
                try validateExpectation(expected)
                let mapped = try ImportMapper.map(data, filename: sourceName)
                actual = ["source": mapped.document.source, "body": mapped.document.body,
                          "mappings": mapped.report.mappings.map(mapping),
                          "preservedKeys": mapped.report.preservedKeys,
                          "dropped": mapped.report.dropped.map(\.rawValue),
                          "warnings": mapped.report.warnings.map(warning)]
                XCTAssertEqual(Data(mapped.document.source.utf8), Data((expected["source"] as! String).utf8), name)
                XCTAssertEqual(Data(mapped.document.body.utf8), Data((expected["body"] as! String).utf8), name)
            }
            XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected), name)
            consumed += [name + "/case.json", name + "/" + sourceName]
        }
        return (names.count, consumed)
    }

    private static func validateExpectation(_ expected: [String: Any]) throws {
        try keys(expected, ["source", "body", "mappings", "preservedKeys", "dropped", "warnings"])
        guard expected["source"] is String, expected["body"] is String,
              expected["preservedKeys"] is [String], let dropped = expected["dropped"] as? [String],
              dropped.allSatisfy({ ImportLoss(rawValue: $0) != nil }),
              let mappings = expected["mappings"] as? [[String: Any]],
              let warnings = expected["warnings"] as? [[String: Any]] else { throw Failure.invalidCorpus }
        for entry in mappings {
            try keys(entry, ["sourceKey", "fieldName", "kind", "defaultSource"])
            guard entry["sourceKey"] is String, entry["fieldName"] is String,
                  let kind = entry["kind"] as? String, FieldKind(rawValue: kind) != nil,
                  entry["defaultSource"] is String || entry["defaultSource"] is NSNull else { throw Failure.invalidCorpus }
        }
        for entry in warnings {
            try keys(entry, ["code"], optional: ["key", "format", "byteOffset"])
            guard let code = entry["code"] as? String else { throw Failure.invalidCorpus }
            switch code {
            case "unsupportedInput", "invalidName", "reservedName", "fieldCollision", "invalidOptions", "invalidDefault", "invalidDescription", "validation":
                try keys(entry, ["code", "key"])
                guard entry["key"] is String else { throw Failure.invalidCorpus }
                if code == "validation", PromptIssueCode(rawValue: entry["key"] as! String) == nil { throw Failure.invalidCorpus }
            case "unsupportedTemplate":
                try keys(entry, ["code", "format", "byteOffset"])
                guard let format = entry["format"] as? String, ImportFormat(rawValue: format) != nil,
                      try integer(entry["byteOffset"]) >= 0 else { throw Failure.invalidCorpus }
            case "identityReassigned": try keys(entry, ["code"])
            default: throw Failure.invalidCorpus
            }
        }
    }

    private static func mapping(_ value: ImportFieldMapping) -> [String: Any] {
        ["sourceKey": value.sourceKey, "fieldName": value.fieldName,
         "kind": value.kind.rawValue, "defaultSource": value.defaultSource as Any? ?? NSNull()]
    }

    private static func warning(_ value: ImportWarning) -> [String: Any] {
        let code: String, key: String
        switch value {
        case .unsupportedInput(let name): code = "unsupportedInput"; key = name
        case .invalidName(let name): code = "invalidName"; key = name
        case .reservedName(let name): code = "reservedName"; key = name
        case .fieldCollision(let name): code = "fieldCollision"; key = name
        case .invalidOptions(let name): code = "invalidOptions"; key = name
        case .invalidDefault(let name): code = "invalidDefault"; key = name
        case .invalidDescription(let name): code = "invalidDescription"; key = name
        case .validation(let issue): code = "validation"; key = issue.rawValue
        case .unsupportedTemplate(let format, let offset):
            return ["code": "unsupportedTemplate", "format": format.rawValue, "byteOffset": offset]
        case .identityReassigned: return ["code": "identityReassigned"]
        }
        return ["code": code, "key": key]
    }

    private static func failure(_ reason: ImportSkipReason) -> [String: Any] {
        switch reason {
        case .invalidPrompt(let issues): return ["code": "invalidPrompt", "issues": issues.map(\.rawValue)]
        case .fileTooLarge: return ["code": "fileTooLarge", "issues": [String]()]
        case .convertedTooLarge: return ["code": "convertedTooLarge", "issues": [String]()]
        default: return ["code": "unexpected", "issues": [String]()]
        }
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw Failure.invalidCorpus }
        return result
    }

    private static func keys(_ value: [String: Any], _ required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)) else {
            throw Failure.invalidCorpus
        }
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let value = value as? NSNumber, String(cString: value.objCType) != "c",
              value.doubleValue == Double(value.intValue) else { throw Failure.invalidCorpus }
        return value.intValue
    }

    private static func require(_ type: FileAttributeType, at url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type else {
            throw Failure.invalidCorpus
        }
    }
}

final class ImportConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/import")
    }

    func testEveryPortableImportFixture() throws {
        let result = try ImportFixtureCorpus.consume(at: root)
        XCTAssertGreaterThan(result.cases, 0)
        XCTAssertEqual(result.files.count, result.cases * 2)
    }

    func testStrictDispatchRejectsOrphansLinksDirectoriesAndUnknownMembers() throws {
        let mutations: [(URL) throws -> Void] = [
            { try Data().write(to: $0.appendingPathComponent("markdown/orphan.md")) },
            { try Data().write(to: $0.appendingPathComponent("unknown.txt")) },
            { try FileManager.default.createDirectory(at: $0.appendingPathComponent("markdown/nested"), withIntermediateDirectories: false) },
            { root in
                let source = root.appendingPathComponent("markdown/example.md")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "case.json")
            }
        ]
        for mutation in mutations { try withCopy { copy in try mutation(copy); XCTAssertThrowsError(try ImportFixtureCorpus.consume(at: copy)) } }
        for (key, value) in [("schema", 2 as Any), ("schema", true as Any), ("category", "format" as Any),
                             ("extra", 1 as Any), ("source", "../example.md" as Any), ("repeat", 0 as Any)] {
            try mutateJSON { $0[key] = value }
        }
        try mutateJSON { envelope in
            var expected = envelope["expected"] as! [String: Any]
            expected["extra"] = 1
            envelope["expected"] = expected
        }
        try mutateJSON { envelope in
            var expected = envelope["expected"] as! [String: Any]
            expected["warnings"] = [["code": "invented"]]
            envelope["expected"] = expected
        }
    }

    private func mutateJSON(_ mutate: (inout [String: Any]) -> Void) throws {
        try withCopy { copy in
            let file = copy.appendingPathComponent("markdown/case.json")
            var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            mutate(&envelope)
            try JSONSerialization.data(withJSONObject: envelope).write(to: file)
            XCTAssertThrowsError(try ImportFixtureCorpus.consume(at: copy))
        }
    }

    private func withCopy(_ body: (URL) throws -> Void) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: root, to: copy)
        try body(copy)
    }
}
