import Foundation
@testable import MonkeysPawCore

enum LlmDiffFixtureCorpus {
    enum Output {
        case lines([LineDiffLine])
        case artifact(ArtifactDiff, original: Data?, candidate: Data)
        case error(LineDiffError)
    }

    static func consume(_ envelope: [String: LlmFixtureJSON], at directory: URL) throws -> [String] {
        let expected = try LlmFixtureCorpus.member(envelope, "expected").object
        let goldens = try validateExpected(expected, operation: LlmFixtureCorpus.member(envelope, "operation").string)
        var references = [String]()
        func read(_ name: String) throws -> Data {
            references.append(name)
            return try Data(contentsOf: directory.appendingPathComponent(name))
        }
        let output = try evaluate(envelope, read: read)
        guard try matches(snapshot(output, originalName: goldens.original ?? "original-canonical.md",
                                   candidateName: goldens.candidate ?? "candidate.md"), .object(expected)) else {
            throw LlmFixtureCorpus.Failure.mismatch(directory.lastPathComponent + ": diff result")
        }
        if case .artifact(let diff, let original, let candidate) = output {
            let oldGolden = try goldens.original.map(read)
            let newGolden = try read(goldens.candidate!)
            guard original == oldGolden, candidate == newGolden,
                  project(diff.frontMatter + diff.body, excluding: .added) == (oldGolden ?? Data()),
                  project(diff.frontMatter + diff.body, excluding: .removed) == newGolden else {
                throw LlmFixtureCorpus.Failure.mismatch(directory.lastPathComponent + ": canonical reconstruction")
            }
        }
        return references
    }

    /// Capture and conformance both call the unchanged Swift domain implementation.
    static func evaluate(_ envelope: [String: LlmFixtureJSON], read: (String) throws -> Data) throws -> Output {
        guard try LlmFixtureCorpus.member(envelope, "schema").integer == 1,
              try LlmFixtureCorpus.member(envelope, "category").string == "llm",
              try LlmFixtureCorpus.member(envelope, "kind").string == "diff" else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        let operation = try LlmFixtureCorpus.member(envelope, "operation").string
        let common: Set<String> = ["schema", "category", "kind", "operation", "expected"]
        do {
            if operation == "lines" {
                try LlmFixtureCorpus.keys(envelope, common.union(["original", "merged"]), optional: ["originalRepeat", "mergedRepeat"])
                let old = try text(envelope, key: "original", repeatKey: "originalRepeat", extensions: [".txt"], read: read)
                let new = try text(envelope, key: "merged", repeatKey: "mergedRepeat", extensions: [".txt"], read: read)
                let rows = try MyersLineDiff.compare(old, new)
                guard project(rows, excluding: .added) == Data(old.utf8), project(rows, excluding: .removed) == Data(new.utf8) else {
                    throw LlmFixtureCorpus.Failure.mismatch("Line reconstruction")
                }
                return .lines(rows)
            }
            try LlmFixtureCorpus.keys(envelope, common.union(["artifact", "original", "filename", "id"]),
                                      optional: ["originalRepeat", "artifactBodyRepeat"])
            let filename = try LlmFixtureCorpus.member(envelope, "filename").string
            let bodyCount = try count(envelope["artifactBodyRepeat"])
            let original: PromptDocument?
            let id: ULID?
            if operation == "write" {
                guard try LlmFixtureCorpus.member(envelope, "original").isNull, envelope["originalRepeat"] == nil,
                      let supplied = ULID(try LlmFixtureCorpus.member(envelope, "id").string) else { throw LlmFixtureCorpus.Failure.invalidCorpus }
                original = nil
                id = supplied
            } else if operation == "improve" {
                guard try LlmFixtureCorpus.member(envelope, "id").isNull else { throw LlmFixtureCorpus.Failure.invalidCorpus }
                original = try PromptCodec.parse(text(envelope, key: "original", repeatKey: "originalRepeat", extensions: [".md"], read: read),
                                                 filename: filename)
                id = nil
            } else { throw LlmFixtureCorpus.Failure.invalidCorpus }
            let artifactName = try LlmFixtureCorpus.sourceName(LlmFixtureCorpus.member(envelope, "artifact"), extensions: [".json"])
            let decoded = try LlmOutputDecoder.artifact(from: utf8(read(artifactName)))
            let body = try expanded(decoded.body, count: bodyCount)
            let artifact = LlmArtifact(title: decoded.title, description: decoded.description, tags: decoded.tags,
                                      fields: decoded.fields, body: body, notes: decoded.notes)
            let merged = original.map { ArtifactMerge.improve(artifact, original: $0) } ?? ArtifactMerge.write(artifact, id: id!)
            guard case .ready(let candidate) = merged else { throw LlmFixtureCorpus.Failure.invalidCorpus }
            let diff = try ArtifactDiff.compare(original: original, candidate: candidate)
            return .artifact(diff, original: try original.map { Data(try PromptCodec.write($0).utf8) }, candidate: candidate.canonicalBytes)
        } catch let error as LineDiffError { return .error(error) }
    }

    static func snapshot(_ output: Output, originalName: String = "original-canonical.md", candidateName: String = "candidate.md") -> LlmFixtureJSON {
        switch output {
        case .lines(let value): return .object(["rows": rows(value)])
        case .artifact(let diff, let original, _): return .object([
            "frontMatter": rows(diff.frontMatter), "body": rows(diff.body), "placeholderWarnings": warnings(diff.placeholderWarnings),
            "originalCanonical": original == nil ? .null : .string(originalName), "candidate": .string(candidateName)
        ])
        case .error(let error): return .object(["error": .string(error == .sourceTooLarge ? "sourceTooLarge" : "comparisonTooComplex")])
        }
    }

    private static func rows(_ rows: [LineDiffLine]) -> LlmFixtureJSON {
        .array(rows.map { .object([
            "kind": .string($0.kind.rawValue), "text": .string($0.text),
            "originalLine": $0.originalLine.map(LlmFixtureJSON.integer) ?? .null,
            "mergedLine": $0.mergedLine.map(LlmFixtureJSON.integer) ?? .null,
            "placeholderWarnings": warnings($0.placeholderWarnings)
        ]) })
    }

    private static func warnings(_ warnings: [PlaceholderChange]) -> LlmFixtureJSON {
        .array(warnings.map { change in
            switch change {
            case .added(let name): return .object(["kind": .string("added"), "name": .string(name)])
            case .removed(let name): return .object(["kind": .string("removed"), "name": .string(name)])
            case .renamed(let from, let to): return .object(["kind": .string("renamed"), "from": .string(from), "to": .string(to)])
            }
        })
    }

    private static func validateExpected(_ expected: [String: LlmFixtureJSON], operation: String) throws -> (original: String?, candidate: String?) {
        if let error = expected["error"] {
            try LlmFixtureCorpus.keys(expected, ["error"])
            guard ["sourceTooLarge", "comparisonTooComplex"].contains(try error.string) else { throw LlmFixtureCorpus.Failure.invalidCorpus }
            return (nil, nil)
        }
        if operation == "lines" {
            try LlmFixtureCorpus.keys(expected, ["rows"])
            try validateRows(LlmFixtureCorpus.member(expected, "rows"))
            return (nil, nil)
        }
        try LlmFixtureCorpus.keys(expected, ["frontMatter", "body", "placeholderWarnings", "originalCanonical", "candidate"])
        try validateRows(LlmFixtureCorpus.member(expected, "frontMatter"))
        try validateRows(LlmFixtureCorpus.member(expected, "body"))
        try validateWarnings(LlmFixtureCorpus.member(expected, "placeholderWarnings"))
        let original = try LlmFixtureCorpus.member(expected, "originalCanonical")
        guard original.isNull == (operation == "write") else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return (try original.isNull ? nil : LlmFixtureCorpus.sourceName(original, extensions: [".md"]),
                try LlmFixtureCorpus.sourceName(LlmFixtureCorpus.member(expected, "candidate"), extensions: [".md"]))
    }

    private static func validateRows(_ value: LlmFixtureJSON) throws {
        for row in try value.array {
            let row = try row.object
            try LlmFixtureCorpus.keys(row, ["kind", "text", "originalLine", "mergedLine", "placeholderWarnings"])
            let kind = try LlmFixtureCorpus.member(row, "kind").string
            guard LineDiffLine.Kind(rawValue: kind) != nil else { throw LlmFixtureCorpus.Failure.invalidCorpus }
            _ = try LlmFixtureCorpus.member(row, "text").string
            for (key, absent) in [("originalLine", kind == "added"), ("mergedLine", kind == "removed")] {
                let line = try LlmFixtureCorpus.member(row, key)
                guard line.isNull == absent else { throw LlmFixtureCorpus.Failure.invalidCorpus }
                if !line.isNull { guard try line.integer > 0 else { throw LlmFixtureCorpus.Failure.invalidCorpus } }
            }
            try validateWarnings(LlmFixtureCorpus.member(row, "placeholderWarnings"))
        }
    }

    private static func validateWarnings(_ value: LlmFixtureJSON) throws {
        for warning in try value.array {
            let warning = try warning.object
            let kind = try LlmFixtureCorpus.member(warning, "kind").string
            if kind == "renamed" {
                try LlmFixtureCorpus.keys(warning, ["kind", "from", "to"])
                _ = try LlmFixtureCorpus.member(warning, "from").string
                _ = try LlmFixtureCorpus.member(warning, "to").string
            } else {
                guard ["added", "removed"].contains(kind) else { throw LlmFixtureCorpus.Failure.invalidCorpus }
                try LlmFixtureCorpus.keys(warning, ["kind", "name"])
                _ = try LlmFixtureCorpus.member(warning, "name").string
            }
        }
    }

    private static func text(_ envelope: [String: LlmFixtureJSON], key: String, repeatKey: String,
                             extensions: [String], read: (String) throws -> Data) throws -> String {
        let name = try LlmFixtureCorpus.sourceName(LlmFixtureCorpus.member(envelope, key), extensions: extensions)
        return try expanded(utf8(read(name)), count: count(envelope[repeatKey]))
    }
    private static func count(_ value: LlmFixtureJSON?) throws -> Int {
        let count = try value?.integer ?? 1
        guard count > 0, count <= Limits.maxPromptBytes + 1 else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return count
    }
    private static func expanded(_ text: String, count: Int) throws -> String {
        guard text.utf8.count <= (Limits.maxPromptBytes + 1) / count else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return String(repeating: text, count: count)
    }
    private static func utf8(_ bytes: Data) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard Data(text.utf8) == bytes else { throw LlmFixtureCorpus.Failure.invalidCorpus }
        return text
    }
    private static func project(_ rows: [LineDiffLine], excluding: LineDiffLine.Kind) -> Data {
        rows.filter { $0.kind != excluding }.reduce(into: Data()) { $0.append($1.bytes) }
    }

    /// Compare string bytes directly; neither normalization nor Foundation reserialization is evidence.
    private static func matches(_ actual: LlmFixtureJSON, _ expected: LlmFixtureJSON) throws -> Bool {
        switch (actual, expected) {
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.integer(let a), .integer(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (a, b) in zip(a, b) { if try !matches(a, b) { return false } }
            return true
        case (.object(let a), .object(let b)):
            guard Set(a.keys) == Set(b.keys) else { return false }
            for (key, value) in a { if try !matches(value, b[key]!) { return false } }
            return true
        default: return false
        }
    }
}
