import Foundation
import Yams
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
            let outputKind = try envelope["outputKind"]?.string ?? ""
            guard (kind == "merge" || ["artifact", "review"].contains(outputKind)),
                  try member(envelope, "schema").integer == 1,
                  try member(envelope, "category").string == "llm" else { throw Failure.invalidCorpus }
            let expected = try member(envelope, "expected").object
            var references = [String]()
            if kind == "merge" {
                references = try consumeMerge(envelope, expected: expected, at: directory)
            } else if kind == "schema" {
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

extension LlmFixtureCorpus {
    private static func consumeMerge(_ envelope: [String: LlmFixtureJSON], expected: [String: LlmFixtureJSON],
                                     at directory: URL) throws -> [String] {
        try keys(envelope, ["schema", "category", "kind", "operation", "artifact", "original", "filename", "id", "expected"],
                 optional: ["originalRepeat", "artifactBodyRepeat"])
        let operation = try member(envelope, "operation").string
        let filename = try member(envelope, "filename").string
        let bodyRepeat = try envelope["artifactBodyRepeat"]?.integer ?? 1
        guard bodyRepeat > 0, bodyRepeat <= Limits.maxPromptBytes + 1 else { throw Failure.invalidCorpus }
        let artifactName = try sourceName(member(envelope, "artifact"), extensions: [".json"])
        let output = try utf8(at: directory.appendingPathComponent(artifactName))
        var references = [artifactName]
        let original: PromptDocument?
        let id: ULID?
        if operation == "write" {
            guard try member(envelope, "original").isNull, envelope["originalRepeat"] == nil,
                  let supplied = ULID(try member(envelope, "id").string) else { throw Failure.invalidCorpus }
            original = nil
            id = supplied
        } else if operation == "improve" {
            guard try member(envelope, "id").isNull else { throw Failure.invalidCorpus }
            let source = try sourceName(member(envelope, "original"), extensions: [".md", ".bin"])
            references.append(source)
            let data = try Data(contentsOf: directory.appendingPathComponent(source))
            if source.hasSuffix(".md") { _ = try utf8(at: directory.appendingPathComponent(source)) }
            let count = try envelope["originalRepeat"]?.integer ?? 1
            guard count > 0, count <= Limits.maxPromptBytes + 1, data.count <= (Limits.maxPromptBytes + 1) / count else {
                throw Failure.invalidCorpus
            }
            var expandedData = Data()
            for _ in 0..<count { expandedData.append(data) }
            original = PromptCodec.parseFile(expandedData, filename: filename)
            id = nil
        } else { throw Failure.invalidCorpus }
        let candidateName = try validateMergeExpected(expected)
        if let candidateName { references.append(candidateName) }
        let snapshot: LlmFixtureJSON
        do {
            let decoded = try LlmOutputDecoder.artifact(from: output)
            let body = try expanded(decoded.body, count: bodyRepeat, cap: Limits.maxPromptBytes + 1)
            let artifact = LlmArtifact(title: decoded.title, description: decoded.description, tags: decoded.tags,
                                      fields: decoded.fields, body: body, notes: decoded.notes)
            let result = original.map { ArtifactMerge.improve(artifact, original: $0) } ?? ArtifactMerge.write(artifact, id: id!)
            if case .ready(let candidate) = result {
                guard let candidateName,
                      candidate.canonicalBytes == (try Data(contentsOf: directory.appendingPathComponent(candidateName))),
                      candidate.canonicalBytes == Data(candidate.document.source.utf8) else {
                    throw Failure.mismatch(directory.lastPathComponent + ": candidate bytes")
                }
            }
            snapshot = try mergeSnapshot(result, candidateName: candidateName ?? "candidate.md")
        } catch AssistantError.invalidOutput { snapshot = .object(["error": .string("invalidOutput")]) }
        guard try snapshot.bytes() == LlmFixtureJSON.object(expected).bytes() else {
            throw Failure.mismatch(directory.lastPathComponent + ": merge result")
        }
        return references
    }

    static func mergeSnapshot(_ result: ArtifactMergeResult, candidateName: String) throws -> LlmFixtureJSON {
        switch result {
        case .ready(let candidate):
            let document = candidate.document
            let preserved = try document.preservedHeader?.mapping?.filter {
                !["title", "description", "tags", "fields"].contains(PortableYAML.string($0.key) ?? "")
            }.map { try yamlPair($0.key, $0.value) } ?? []
            return .object(["ready": .object([
                "candidate": .string(candidateName), "id": document.frontMatter.id.map { .string($0.rawValue) } ?? .null,
                "issues": mergeIssues(document.issues), "preserved": .array(preserved)
            ])])
        case .invalid(let issues): return .object(["invalid": mergeIssues(issues)])
        case .failed(let error):
            var failed: [String: LlmFixtureJSON]
            switch error {
            case .invalidPrompt: failed = ["error": .string("invalidPrompt")]
            case .serializationFailed: failed = ["error": .string("serializationFailed")]
            case .sourceTooLarge: failed = ["error": .string("sourceTooLarge")]
            case .unsupportedFormat(let version): failed = ["error": .string("unsupportedFormat"), "format": .string(version.decimalValue)]
            }
            return .object(["failed": .object(failed)])
        }
    }

    private static func mergeIssues(_ issues: [PromptIssue]) -> LlmFixtureJSON {
        .array(issues.map { issue in
            let location: LlmFixtureJSON
            switch issue.location {
            case nil: location = .null
            case .body(let offset): location = .object(["bodyByteOffset": .integer(offset)])
            case .frontMatter(let line, let column): location = .object(["line": .integer(line), "column": .integer(column)])
            }
            return .object(["code": .string(issue.code.rawValue), "severity": .string(issue.severity.rawValue), "location": location])
        })
    }

    private static func yamlPair(_ key: Node, _ value: Node) throws -> LlmFixtureJSON {
        .object(["key": try yamlSnapshot(key), "value": try yamlSnapshot(value)])
    }

    private static func yamlSnapshot(_ node: Node) throws -> LlmFixtureJSON {
        let value: LlmFixtureJSON
        switch node {
        case .scalar(let scalar): value = .string(scalar.string)
        case .sequence(let sequence): value = .array(try sequence.map(yamlSnapshot))
        case .mapping(let mapping): value = .array(try mapping.map { try yamlPair($0.key, $0.value) })
        case .alias: throw Failure.invalidCorpus
        }
        return .object(["tag": .string(String(node.tag.rawValue.split(separator: ":").last!)), "value": value])
    }

    private static func validateMergeExpected(_ expected: [String: LlmFixtureJSON]) throws -> String? {
        if let ready = expected["ready"] {
            try keys(expected, ["ready"])
            let ready = try ready.object
            try keys(ready, ["candidate", "id", "issues", "preserved"])
            let id = try member(ready, "id")
            guard try id.isNull || ULID(id.string) != nil else { throw Failure.invalidCorpus }
            try validateMergeIssues(member(ready, "issues"))
            for pair in try member(ready, "preserved").array { try validateYAMLPair(pair) }
            return try sourceName(member(ready, "candidate"), extensions: [".md"])
        }
        if let invalid = expected["invalid"] {
            try keys(expected, ["invalid"])
            try validateMergeIssues(invalid)
        } else if let failed = expected["failed"] {
            try keys(expected, ["failed"])
            let failed = try failed.object
            let error = try member(failed, "error").string
            try keys(failed, error == "unsupportedFormat" ? ["error", "format"] : ["error"])
            guard ["invalidPrompt", "serializationFailed", "sourceTooLarge", "unsupportedFormat"].contains(error) else {
                throw Failure.invalidCorpus
            }
            if error == "unsupportedFormat" { _ = try member(failed, "format").string }
        } else {
            try keys(expected, ["error"])
            guard try member(expected, "error").string == "invalidOutput" else { throw Failure.invalidCorpus }
        }
        return nil
    }

    private static func validateMergeIssues(_ value: LlmFixtureJSON) throws {
        for issue in try value.array {
            let issue = try issue.object
            try keys(issue, ["code", "severity", "location"])
            guard PromptIssueCode(rawValue: try member(issue, "code").string) != nil,
                  ["error", "warning"].contains(try member(issue, "severity").string) else { throw Failure.invalidCorpus }
            let location = try member(issue, "location")
            if !location.isNull {
                let location = try location.object
                if let offset = location["bodyByteOffset"] {
                    try keys(location, ["bodyByteOffset"])
                    guard try offset.integer >= 0 else { throw Failure.invalidCorpus }
                } else {
                    try keys(location, ["line", "column"])
                    guard try member(location, "line").integer > 0, try member(location, "column").integer > 0 else {
                        throw Failure.invalidCorpus
                    }
                }
            }
        }
    }

    private static func validateYAMLPair(_ value: LlmFixtureJSON) throws {
        let pair = try value.object
        try keys(pair, ["key", "value"])
        try validateYAMLNode(member(pair, "key"))
        try validateYAMLNode(member(pair, "value"))
    }

    private static func validateYAMLNode(_ value: LlmFixtureJSON) throws {
        let node = try value.object
        try keys(node, ["tag", "value"])
        let value = try member(node, "value")
        switch try member(node, "tag").string {
        case "map": for pair in try value.array { try validateYAMLPair(pair) }
        case "seq": for child in try value.array { try validateYAMLNode(child) }
        case "str", "int", "float", "bool", "null": _ = try value.string
        default: throw Failure.invalidCorpus
        }
    }
}
