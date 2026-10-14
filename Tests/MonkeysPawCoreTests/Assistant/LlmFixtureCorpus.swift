import Foundation
@testable import MonkeysPawCore

/// JSONDecoder preserves scalar spelling in golden strings without NSString bridging.
indirect enum LlmFixtureJSON: Codable {
    case object([String: LlmFixtureJSON]), array([LlmFixtureJSON]), string(String), integer(Int), boolean(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .boolean(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([LlmFixtureJSON].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: LlmFixtureJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .boolean(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: LlmFixtureJSON] { get throws {
        guard case .object(let value) = self else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return value
    } }
    var array: [LlmFixtureJSON] { get throws {
        guard case .array(let value) = self else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return value
    } }
    var string: String { get throws {
        guard case .string(let value) = self else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return value
    } }
    var integer: Int { get throws {
        guard case .integer(let value) = self else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return value
    } }
    var boolean: Bool { get throws {
        guard case .boolean(let value) = self else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return value
    } }
    var isNull: Bool { if case .null = self { return true }; return false }

    var expectationCount: Int {
        switch self {
        case .object(let members): return members.count + members.values.reduce(0) { $0 + $1.expectationCount }
        case .array(let items): return items.reduce(0) { $0 + $1.expectationCount }
        default: return 0
        }
    }

    func bytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum LlmFixtureCorpus {
    enum Failure: Error { case invalidCorpus, mismatch(String) }

    static func consume(at root: URL) throws -> (cases: Int, files: [String], expectations: Int) {
        try require(.typeDirectory, at: root)
        let names = try visible(at: root)
        guard !names.isEmpty else { throw Failure.invalidCorpus }
        var consumed = [String]()
        var expectations = 0
        for name in names {
            let directory = root.appendingPathComponent(name)
            try require(.typeDirectory, at: directory)
            let files = try visible(at: directory)
            for file in files { try require(.typeRegular, at: directory.appendingPathComponent(file)) }
            guard files.contains("case.json") else { throw Failure.invalidCorpus }
            let envelope = try JSONDecoder().decode(LlmFixtureJSON.self,
                from: Data(contentsOf: directory.appendingPathComponent("case.json"))).object
            let kind = try member(envelope, "kind").string
            let outputKind = try member(envelope, "outputKind").string
            guard ["artifact", "review"].contains(outputKind),
                  try member(envelope, "schema").integer == 1,
                  try member(envelope, "category").string == "llm" else { throw Failure.invalidCorpus }
            let expected = try member(envelope, "expected").object
            var references = [String]()
            if kind == "schema" {
                try keys(envelope, ["schema", "category", "kind", "outputKind", "expected"])
                try keys(expected, ["bytes"])
                let source = try sourceName(member(expected, "bytes"), extensions: [".json"])
                references.append(source)
                let actual = outputKind == "artifact" ? LlmArtifact.jsonSchema : LlmReview.jsonSchema
                guard actual == (try Data(contentsOf: directory.appendingPathComponent(source))) else {
                    throw Failure.mismatch(name + ": schema bytes")
                }
            } else if kind == "decode" {
                let required: Set<String> = ["schema", "category", "kind", "outputKind", "source", "expected"]
                try keys(envelope, required.union(outputKind == "review" ? ["reviewedSource"] : []),
                         optional: outputKind == "review" ? ["prefix", "reviewedRepeat"] : ["prefix"])
                let source = try sourceName(member(envelope, "source"), extensions: [".txt", ".bin"])
                references.append(source)
                var output = source.hasSuffix(".bin")
                    ? String(decoding: try Data(contentsOf: directory.appendingPathComponent(source)), as: UTF8.self)
                    : try utf8(at: directory.appendingPathComponent(source))
                if let prefix = envelope["prefix"] {
                    let prefix = try prefix.object
                    try keys(prefix, ["source", "repeat"])
                    let prefixName = try sourceName(member(prefix, "source"), extensions: [".txt"])
                    references.append(prefixName)
                    let text = try utf8(at: directory.appendingPathComponent(prefixName))
                    output = try expanded(text, count: member(prefix, "repeat").integer, cap: Limits.responseCap + 1) + output
                }
                guard output.utf8.count <= Limits.responseCap + 1 else { throw Failure.invalidCorpus }
                var reviewed = ""
                if outputKind == "review" {
                    let source = try sourceName(member(envelope, "reviewedSource"), extensions: [".md"])
                    references.append(source)
                    reviewed = try utf8(at: directory.appendingPathComponent(source))
                    reviewed = try expanded(reviewed, count: envelope["reviewedRepeat"]?.integer ?? 1,
                                            cap: Limits.maxPromptBytes + 1)
                }
                try keys(expected, ["recovered", "parsed", "result"])
                _ = try member(expected, "parsed").boolean
                let recovered = try member(expected, "recovered")
                let actualRecovery = try recovery(output)
                if recovered.isNull {
                    guard actualRecovery == nil else { throw Failure.mismatch(name + ": unexpected recovery") }
                } else {
                    let source = try sourceName(recovered, extensions: [".json"])
                    references.append(source)
                    guard actualRecovery == (try Data(contentsOf: directory.appendingPathComponent(source))) else {
                        throw Failure.mismatch(name + ": recovered bytes")
                    }
                }
                let parsed: Bool
                if let actualRecovery {
                    var parser = LlmJSONParser(bytes: Array(actualRecovery))
                    do { _ = try parser.parse(); parsed = true }
                    catch AssistantError.invalidOutput { parsed = false }
                } else { parsed = false }
                guard parsed == (try member(expected, "parsed").boolean) else { throw Failure.mismatch(name + ": JSON validity") }
                let result = try member(expected, "result")
                try validateResult(result, outputKind: outputKind)
                guard try snapshot(output, source: reviewed, outputKind: outputKind).bytes() == result.bytes() else {
                    throw Failure.mismatch(name + ": typed result")
                }
            } else { throw Failure.invalidCorpus }
            guard Set(references.map { RelativePath($0) }).count == references.count,
                  Set(files.map { RelativePath($0) }) == Set((["case.json"] + references).map { RelativePath($0) }) else {
                throw Failure.invalidCorpus
            }
            consumed += (["case.json"] + references).map { name + "/" + $0 }
            expectations += LlmFixtureJSON.object(expected).expectationCount
        }
        return (names.count, consumed, expectations)
    }

    static func recovery(_ output: String) throws -> Data? {
        do { return Data(try LlmJSONRecovery.object(in: output)) }
        catch AssistantError.invalidOutput { return nil }
    }

    static func snapshot(_ output: String, source: String, outputKind: String) throws -> LlmFixtureJSON {
        do {
            if outputKind == "artifact" {
                let value = try LlmOutputDecoder.artifact(from: output)
                let fields = value.fields.map { field in LlmFixtureJSON.object([
                    "name": .string(field.name), "type": .string(field.type.rawValue), "label": .string(field.label),
                    "description": .string(field.description), "default": .string(field.defaultValue),
                    "options": .array(field.options.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
                    "optional": .boolean(field.optional), "remember": .boolean(field.remember)
                ]) }
                let artifact = LlmFixtureJSON.object([
                    "title": .string(value.title), "description": .string(value.description),
                    "tags": .array(value.tags.map(LlmFixtureJSON.string)), "fields": .array(fields),
                    "body": .string(value.body), "notes": .string(value.notes)
                ])
                let issues = value.issues.map { issue -> LlmFixtureJSON in
                    let location: LlmFixtureJSON
                    switch issue.location {
                    case .body(let offset): location = .object(["bodyByteOffset": .integer(offset)])
                    case .frontMatter(let line, let column): location = .object(["line": .integer(line), "column": .integer(column)])
                    case nil: location = .null
                    }
                    return .object(["code": .string(issue.code.rawValue), "severity": .string(issue.severity.rawValue), "location": location])
                }
                return .object(["artifact": artifact, "issues": .array(issues)])
            }
            let value = try LlmOutputDecoder.review(from: output, source: source)
            let findings = value.findings.map { finding -> LlmFixtureJSON in
                let match: LlmFixtureJSON
                switch finding.quoteMatch {
                case .unmatched: match = .null
                case .matched(let range): match = .object(["startByte": .integer(range.lowerBound), "endByteExclusive": .integer(range.upperBound)])
                }
                return .object(["severity": .string(finding.severity.rawValue), "criterion": .string(finding.criterion.rawValue),
                    "quote": .string(finding.quote), "problem": .string(finding.problem), "suggestion": .string(finding.suggestion), "quoteMatch": match])
            }
            return .object(["review": .object(["summary": .string(value.summary), "findings": .array(findings)])])
        } catch AssistantError.invalidOutput { return .object(["error": .string("invalidOutput")]) }
    }

    private static func validateResult(_ result: LlmFixtureJSON, outputKind: String) throws {
        let members = try result.object
        if let error = members["error"] {
            try keys(members, ["error"])
            guard try error.string == "invalidOutput" else { throw Failure.invalidCorpus }
            return
        }
        if outputKind == "artifact" {
            try keys(members, ["artifact", "issues"])
            var parser = LlmJSONParser(bytes: Array(try member(members, "artifact").bytes()))
            try LlmSchemas.artifact.validate(parser.parse())
            for issue in try member(members, "issues").array {
                let issue = try issue.object
                try keys(issue, ["code", "severity", "location"])
                guard PromptIssueCode(rawValue: try member(issue, "code").string) != nil,
                      ["error", "warning"].contains(try member(issue, "severity").string) else { throw Failure.invalidCorpus }
                let location = try member(issue, "location")
                if !location.isNull {
                    let location = try location.object
                    try keys(location, ["bodyByteOffset"])
                    guard try member(location, "bodyByteOffset").integer >= 0 else { throw Failure.invalidCorpus }
                }
            }
        } else {
            try keys(members, ["review"])
            var review = try member(members, "review").object
            try keys(review, ["summary", "findings"])
            let wireFindings = try member(review, "findings").array.map { finding -> LlmFixtureJSON in
                var finding = try finding.object
                try keys(finding, ["severity", "criterion", "quote", "problem", "suggestion", "quoteMatch"])
                let match = try member(finding, "quoteMatch")
                if !match.isNull {
                    let match = try match.object
                    try keys(match, ["startByte", "endByteExclusive"])
                    let start = try member(match, "startByte").integer
                    guard start >= 0, try member(match, "endByteExclusive").integer > start else { throw Failure.invalidCorpus }
                }
                finding.removeValue(forKey: "quoteMatch")
                return .object(finding)
            }
            review["findings"] = .array(wireFindings)
            var parser = LlmJSONParser(bytes: Array(try LlmFixtureJSON.object(review).bytes()))
            try LlmSchemas.review.validate(parser.parse())
        }
    }

    private static func member(_ object: [String: LlmFixtureJSON], _ key: String) throws -> LlmFixtureJSON {
        guard let value = object[key] else { throw Failure.invalidCorpus }
        return value
    }
    private static func keys(_ object: [String: LlmFixtureJSON], _ required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else { throw Failure.invalidCorpus }
    }
    private static func sourceName(_ value: LlmFixtureJSON, extensions: [String]) throws -> String {
        let name = try value.string
        guard !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), name != "case.json",
              extensions.contains(where: name.hasSuffix) else { throw Failure.invalidCorpus }
        return name
    }
    private static func expanded(_ text: String, count: Int, cap: Int) throws -> String {
        guard count > 0, count <= cap, text.utf8.count <= cap / count else { throw Failure.invalidCorpus }
        return String(repeating: text, count: count)
    }
    private static func utf8(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { throw Failure.invalidCorpus }
        return text
    }
    private static func visible(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.sorted()
    }
    private static func require(_ type: FileAttributeType, at url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type else { throw Failure.invalidCorpus }
    }
}
