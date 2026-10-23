import Foundation
import XCTest
@testable import MonkeysPawCore

/// Owned content is enumerated and dispatched exactly once. Sync scenarios
/// have an explicit server-package owner, without a root server dependency.
final class PromptConformanceTests: XCTestCase {
    private let categories: Set<String> = ["format", "grammar", "render", "validation", "ranking", "import", "paths", "canonical", "dto", "llm"]
    // Real-router sync execution belongs to the server package (E34).
    private let delegatedCategories: Set<String> = ["sync"]
    private let rankingAccuracy = 1e-12

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spec/fixtures")
    }

    func testEveryFixture() throws {
        XCTAssertEqual(categories.count, 10)
        let result = try consumeCorpus(at: fixtureRoot)
        print("Consumed \(result.cases) prompt fixtures (\(result.files) files); delegated \(result.delegatedFiles) sync files to the server suite.")
    }

    func testMergePreservationAndCandidateBytesCannotBypassFullGate() throws {
        try withTemporaryCorpus { root in
            let directory = root.appendingPathComponent("llm/merge-improve-typed-metadata")
            let url = directory.appendingPathComponent("case.json")
            let original = try Data(contentsOf: url)
            var envelope = try JSONDecoder().decode(LlmFixtureJSON.self, from: original).object
            var expected = try envelope["expected"]!.object
            var ready = try expected["ready"]!.object
            ready["preserved"] = .array([])
            expected["ready"] = .object(ready)
            envelope["expected"] = .object(expected)
            try LlmFixtureJSON.object(envelope).bytes().write(to: url)
            XCTAssertThrowsError(try consumeCorpus(at: root), "preserved metadata")
            try original.write(to: url)
            try Data("wrong bytes".utf8).write(to: directory.appendingPathComponent("candidate.md"))
            XCTAssertThrowsError(try consumeCorpus(at: root), "candidate bytes")
        }
    }

    func testDiffRowsAndCanonicalBytesCannotBypassFullGate() throws {
        try withTemporaryCorpus { root in
            let directory = root.appendingPathComponent("llm/diff-artifact-rename")
            let url = directory.appendingPathComponent("case.json")
            let original = try Data(contentsOf: url)
            var envelope = try JSONDecoder().decode(LlmFixtureJSON.self, from: original).object
            var expected = try envelope["expected"]!.object
            expected["body"] = .array([])
            envelope["expected"] = .object(expected)
            try LlmFixtureJSON.object(envelope).bytes().write(to: url)
            XCTAssertThrowsError(try consumeCorpus(at: root), "diff rows")
            try original.write(to: url)
            try Data("wrong bytes".utf8).write(to: directory.appendingPathComponent("candidate.md"))
            XCTAssertThrowsError(try consumeCorpus(at: root), "diff candidate bytes")
        }
    }

    func testHiddenMetadataIsIgnoredAtEveryCorpusLevel() throws {
        let baseline = try consumeCorpus(at: fixtureRoot)
        try withTemporaryCorpus { root in
            var directories = [root]
            for category in categories {
                let directory = root.appendingPathComponent(category)
                directories.append(directory)
                if ["import", "ranking", "paths", "canonical", "dto", "llm"].contains(category) {
                    let cases = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        .filter { !$0.hasPrefix(".") }
                    directories += cases.map { directory.appendingPathComponent($0) }
                }
            }
            for directory in directories {
                for name in [".DS_Store", "._metadata", ".gitattributes"] {
                    try Data([0xff]).write(to: directory.appendingPathComponent(name))
                }
            }
            let actual = try consumeCorpus(at: root)
            XCTAssertEqual(actual.cases, baseline.cases)
            XCTAssertEqual(actual.files, baseline.files)
            XCTAssertEqual(actual.delegatedFiles, baseline.delegatedFiles)
        }
    }

    func testRejectsUnknownCategoriesAndFilesAndUnconsumedSources() throws {
        let mutations: [(String, CorpusError, (URL) throws -> Void)] = [
            ("unknown category", .unknownCategory, { root in
                try FileManager.default.createDirectory(at: root.appendingPathComponent("unknown"),
                                                        withIntermediateDirectories: false)
            }),
            ("missing category", .unknownCategory, { root in
                try FileManager.default.removeItem(at: root.appendingPathComponent("ranking"))
            }),
            ("missing delegated sync category", .unknownCategory, { root in
                try FileManager.default.removeItem(at: root.appendingPathComponent("sync"))
            }),
            ("unknown delegated sync file", .unrecognizedFile, { root in
                try Data().write(to: root.appendingPathComponent("sync/orphan.md"))
            }),
            ("unknown content file", .unrecognizedFile, { root in
                try Data().write(to: root.appendingPathComponent("format/extra.txt"))
            }),
            ("unconsumed content source", .unconsumedFiles, { root in
                try Data().write(to: root.appendingPathComponent("format/orphan.md"))
            }),
            ("unknown ranking file", .unrecognizedFile, { root in
                try Data().write(to: root.appendingPathComponent("ranking/field-weights/extra.txt"))
            }),
            ("additional ranking JSON", .unrecognizedFile, { root in
                try Data().write(to: root.appendingPathComponent("ranking/field-weights/extra.json"))
            }),
            ("unconsumed ranking source", .unconsumedFiles, { root in
                try Data().write(to: root.appendingPathComponent("ranking/field-weights/orphan.md"))
            }),
            ("missing ranking source", .missingSource, { root in
                try FileManager.default.removeItem(at: root.appendingPathComponent("ranking/field-weights/title.md"))
            }),
            ("nested ranking directory", .unrecognizedFile, { root in
                try FileManager.default.createDirectory(at: root.appendingPathComponent("ranking/field-weights/nested.md"),
                                                        withIntermediateDirectories: false)
            }),
            ("source symlink", .unrecognizedFile, { root in
                let source = root.appendingPathComponent("ranking/field-weights/title.md")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "body.md")
            })
        ]
        for (label, expected, mutate) in mutations {
            try withTemporaryCorpus { root in
                try mutate(root)
                XCTAssertThrowsError(try consumeCorpus(at: root), label) {
                    XCTAssertEqual($0 as? CorpusError, expected, label)
                }
            }
        }
    }

    func testRejectsUnknownSchemaVersionsAndContentMembers() throws {
        for category in categories.subtracting(["ranking", "import", "paths", "canonical", "dto", "llm"]).sorted() {
            let files = try FileManager.default.contentsOfDirectory(atPath: fixtureRoot.appendingPathComponent(category).path)
                .filter { !$0.hasPrefix(".") }
            let file = try XCTUnwrap(files.sorted().first { $0.hasSuffix(".json") })
            try assertRejectsJSON(category + "/" + file, label: category + " schema") { $0["schema"] = 2 }
            try assertRejectsJSON(category + "/" + file, label: category + " member") { $0["unknown"] = 1 }
        }
    }

    func testRejectsUnknownOrMistypedFormEdits() throws {
        let mutations: [(String, Any)] = [
            ("not an array", "title"),
            ("unknown property", [["property": "id", "value": "replacement"]]),
            ("missing value", [["property": "title"]]),
            ("extra member", [["property": "title", "value": "Title", "extra": true]]),
            ("wrong text type", [["property": "title", "value": 1]]),
            ("wrong tag type", [["property": "tags", "value": [1]]]),
            ("numeric boolean", [["property": "private", "value": 1]])
        ]
        for (label, edits) in mutations {
            try assertRejectsJSON("format/form-properties.json", label: label) { $0["edits"] = edits }
        }
    }

    func testRejectsInvalidRankingMembersTimesAndReferences() throws {
        let mutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("schema", { $0["schema"] = 2 }),
            ("boolean schema", { $0["schema"] = true }),
            ("category", { $0["category"] = "format" }),
            ("envelope member", { $0["unknown"] = 1 }),
            ("non-canonical UTC now", { $0["now"] = "2026-10-11T12:00:00+00:00" }),
            ("missing now", { $0.removeValue(forKey: "now") }),
            ("empty prompt set", { $0["prompts"] = [] }),
            ("prompt member", { fixture in
                var prompts = try self.array(fixture["prompts"])
                var prompt = try self.object(prompts[0])
                prompt["unknown"] = 1
                prompts[0] = prompt
                fixture["prompts"] = prompts
            }),
            ("non-canonical UTC use", { fixture in
                var prompts = try self.array(fixture["prompts"])
                var prompt = try self.object(prompts[0])
                prompt["uses"] = ["2026-10-11T12:00:00+00:00"]
                prompts[0] = prompt
                fixture["prompts"] = prompts
            }),
            ("duplicate path", { fixture in
                var prompts = try self.array(fixture["prompts"])
                var prompt = try self.object(prompts[1])
                prompt["path"] = try self.object(prompts[0])["path"]
                prompts[1] = prompt
                fixture["prompts"] = prompts
            }),
            ("expectation member", { fixture in
                var expected = try self.object(fixture["expected"])
                expected["unknown"] = 1
                fixture["expected"] = expected
            }),
            ("result member", { fixture in
                var expected = try self.object(fixture["expected"])
                var results = try self.array(expected["results"])
                var result = try self.object(results[0])
                result["unknown"] = 1
                results[0] = result
                expected["results"] = results
                fixture["expected"] = expected
            }),
            ("boolean score", { fixture in
                var expected = try self.object(fixture["expected"])
                var results = try self.array(expected["results"])
                var result = try self.object(results[0])
                result["score"] = true
                results[0] = result
                expected["results"] = results
                fixture["expected"] = expected
            })
        ]
        for (label, mutate) in mutations {
            try assertRejectsJSON("ranking/field-weights/case.json", label: label, mutate: mutate)
        }
        try assertRejectsJSON("ranking/field-weights/case.json", label: "duplicate source",
                              expectedError: .duplicateConsumption) { fixture in
            var prompts = try self.array(fixture["prompts"])
            var prompt = try self.object(prompts[1])
            prompt["source"] = try self.object(prompts[0])["source"]
            prompts[1] = prompt
            fixture["prompts"] = prompts
        }
    }

    private func assertRejectsJSON(_ path: String, label: String, expectedError: CorpusError = .unrecognizedCase,
                                   mutate: (inout [String: Any]) throws -> Void) throws {
        try withTemporaryCorpus { root in
            let url = root.appendingPathComponent(path)
            var fixture = try object(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
            try mutate(&fixture)
            try JSONSerialization.data(withJSONObject: fixture).write(to: url)
            XCTAssertThrowsError(try consumeCorpus(at: root), label) {
                XCTAssertEqual($0 as? CorpusError, expectedError, label)
            }
        }
    }

    private func withTemporaryCorpus(_ work: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ranking-contract-" + UUID().uuidString)
        try FileManager.default.copyItem(at: fixtureRoot, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try work(root)
    }

    private func consumeCorpus(at root: URL) throws -> (cases: Int, files: Int, delegatedFiles: Int) {
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        guard Set(directories) == categories.union(delegatedCategories) else { throw CorpusError.unknownCategory }
        var consumed = Set<RelativePath>()
        var allFiles = Set<RelativePath>()
        var cases = 0
        var delegatedFiles = 0

        for category in directories {
            let directory = root.appendingPathComponent(category)
            try require(.directory, at: directory)
            let files = try manager.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }.sorted()
            guard !files.isEmpty else { throw CorpusError.emptyCategory }

            if delegatedCategories.contains(category) {
                for file in files {
                    guard file.hasSuffix(".json") else { throw CorpusError.unrecognizedFile }
                    try require(.file, at: directory.appendingPathComponent(file))
                    delegatedFiles += 1
                }
                continue
            }

            if category == "import" {
                let imported = try ImportFixtureCorpus.consume(at: directory)
                for file in imported.files {
                    let path = "import/" + file
                    allFiles.insert(RelativePath(path))
                    try consume(path, in: &consumed)
                }
                cases += imported.cases
                continue
            }

            if category == "paths" {
                let paths = try SyncPathFixtureCorpus.consume(at: directory)
                for file in paths.files {
                    let path = "paths/" + file
                    allFiles.insert(RelativePath(path))
                    try consume(path, in: &consumed)
                }
                cases += paths.cases
                continue
            }

            if category == "canonical" {
                let canonical = try CanonicalFixtureCorpus.consume(at: directory)
                for file in canonical.files {
                    let path = "canonical/" + file
                    allFiles.insert(RelativePath(path))
                    try consume(path, in: &consumed)
                }
                cases += canonical.cases
                continue
            }

            if category == "llm" {
                let llm = try LlmFixtureCorpus.consume(at: directory)
                print("Full gate llm: \(llm.cases) cases / \(llm.files.count) files / \(llm.expectations) expectations; pending 0.")
                for file in llm.files {
                    let path = "llm/" + file
                    allFiles.insert(RelativePath(path))
                    try consume(path, in: &consumed)
                }
                cases += llm.cases
                continue
            }

            if category == "dto" {
                let dto = try DTOFixtureCorpus.consume(at: directory)
                for file in dto.files {
                    let path = "dto/" + file
                    allFiles.insert(RelativePath(path))
                    try consume(path, in: &consumed)
                }
                cases += dto.cases
                continue
            }

            if category == "ranking" {
                for name in files {
                    let caseDirectory = directory.appendingPathComponent(name)
                    try require(.directory, at: caseDirectory)
                    try consumeRanking(at: caseDirectory, relative: "ranking/" + name,
                                       consumed: &consumed, allFiles: &allFiles)
                    cases += 1
                }
                continue
            }

            for file in files {
                try require(.file, at: directory.appendingPathComponent(file))
                guard file.hasSuffix(".md") || file.hasSuffix(".json") else {
                    throw CorpusError.unrecognizedFile
                }
                allFiles.insert(RelativePath(category + "/" + file))
            }

            for file in files where file.hasSuffix(".json") {
                let sourceFile = String(file.dropLast(5)) + ".md"
                guard files.contains(where: { $0.utf8.elementsEqual(sourceFile.utf8) }) else {
                    throw CorpusError.missingSource
                }
                let data = try Data(contentsOf: directory.appendingPathComponent(file))
                let fixture = try object(JSONSerialization.jsonObject(with: data))
                let optional: Set<String> = category == "render" ? ["repeat", "values", "builtins"]
                    : category == "format" ? ["repeat", "edits"] : ["repeat"]
                try keys(fixture, required: ["schema", "category", "filename", "expected"],
                         optional: optional)
                guard try integer(fixture["schema"]) == 1,
                      fixture["category"] as? String == category,
                      let filename = fixture["filename"] as? String else {
                    throw CorpusError.unrecognizedCase
                }
                let sourceData = try Data(contentsOf: directory.appendingPathComponent(sourceFile))
                guard let unit = String(data: sourceData, encoding: .utf8) else {
                    throw CorpusError.invalidUTF8
                }
                let count = try fixture["repeat"].map { try integer($0) } ?? 1
                guard count > 0 else { throw CorpusError.unrecognizedCase }
                let source = String(repeating: unit, count: count)
                var document = PromptCodec.parse(source, filename: filename)
                XCTAssertEqual(Array(document.source.utf8), Array(source.utf8), file)
                if let edits = fixture["edits"] {
                    for value in try array(edits) {
                        let item = try object(value)
                        try keys(item, required: ["property", "value"])
                        let edit: PromptEdit
                        switch item["property"] as? String {
                        case "title", "description", "body":
                            guard let text = item["value"] as? String else { throw CorpusError.unrecognizedCase }
                            switch item["property"] as? String {
                            case "title": edit = .title(text)
                            case "description": edit = .description(text)
                            default: edit = .body(text)
                            }
                        case "tags":
                            guard let tags = item["value"] as? [String] else { throw CorpusError.unrecognizedCase }
                            edit = .tags(tags)
                        case "private":
                            guard let number = item["value"] as? NSNumber, String(cString: number.objCType) == "c" else {
                                throw CorpusError.unrecognizedCase
                            }
                            edit = .isPrivate(number.boolValue)
                        case "field": edit = .field(try fieldSettingsEdit(item["value"], document: document))
                        default: throw CorpusError.unrecognizedCase
                        }
                        document = try PromptCodec.editing(edit, in: document, filename: filename)
                    }
                }
                XCTAssertEqual(document.issues, PromptValidator.validate(document), file)
                let expected = try object(fixture["expected"])
                let actual: [String: Any]

                switch category {
                case "format":
                    try keys(expected, required: ["metadata", "body", "issues", "canonical"])
                    let canonical: Any = (try? PromptCodec.write(document)) ?? NSNull()
                    guard let expectedBody = expected["body"] as? String else { throw CorpusError.unrecognizedCase }
                    XCTAssertEqual(Array(document.body.utf8), Array(expectedBody.utf8), file)
                    if let text = canonical as? String, let expectedText = expected["canonical"] as? String {
                        XCTAssertEqual(Array(text.utf8), Array(expectedText.utf8), file)
                    }
                    actual = ["metadata": metadata(document.frontMatter), "body": document.body,
                              "issues": issues(document), "canonical": canonical]
                    if let written = canonical as? String {
                        let reparsed = PromptCodec.parse(written, filename: filename)
                        XCTAssertEqual(Array(reparsed.body.utf8), Array(document.body.utf8), file)
                        XCTAssertEqual(try PromptCodec.write(reparsed), written, file)
                        XCTAssertEqual(NSDictionary(dictionary: metadata(reparsed.frontMatter)),
                                       NSDictionary(dictionary: metadata(document.frontMatter)), file)
                    }
                case "grammar":
                    try keys(expected, required: ["tokens", "names", "fields", "issues"])
                    actual = ["tokens": document.template.tokens.map(token),
                              "names": document.template.names,
                              "fields": document.effectiveFields.map(field), "issues": issues(document)]
                case "render":
                    try keys(expected, required: ["fields", "builtins", "issues", "result"])
                    let values = try strings(fixture["values"] ?? [:])
                    let context = try strings(fixture["builtins"] ?? [:])
                    guard Set(context.keys).isSubset(of: ["clipboard", "date", "time"]) else {
                        throw CorpusError.unrecognizedCase
                    }
                    let builtins = PromptBuiltinValues(clipboard: context["clipboard"],
                                                       date: context["date"], time: context["time"])
                    var result: [String: Any]
                    do {
                        result = ["text": try PromptRenderer.render(document, values: values,
                                                                     builtins: builtins)]
                    } catch let error as PromptRenderError {
                        result = renderFailure(error)
                    }
                    if let text = result["text"] as? String,
                       let expectedResult = expected["result"] as? [String: Any],
                       let expectedText = expectedResult["text"] as? String {
                        XCTAssertEqual(Array(text.utf8), Array(expectedText.utf8), file)
                    }
                    actual = ["fields": document.effectiveFields.map(field),
                              "builtins": document.template.builtins.map(\.rawValue),
                              "issues": issues(document), "result": result]
                case "validation":
                    try keys(expected, required: ["issues", "private", "fields", "canRender",
                                                  "readOnly", "canWrite"])
                    actual = ["issues": issues(document), "private": document.frontMatter.isPrivate,
                              "fields": document.effectiveFields.map(field),
                              "canRender": document.canRender, "readOnly": document.isReadOnly,
                              "canWrite": (try? PromptCodec.write(document)) != nil]
                default:
                    throw CorpusError.unknownCategory
                }

                XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected),
                               category + "/" + file)
                try consume(category + "/" + file, in: &consumed)
                try consume(category + "/" + sourceFile, in: &consumed)
                cases += 1
            }
        }

        guard cases > 0, consumed == allFiles else { throw CorpusError.unconsumedFiles }
        return (cases, consumed.count, delegatedFiles)
    }

    private func consumeRanking(at directory: URL, relative: String,
                                consumed: inout Set<RelativePath>, allFiles: inout Set<RelativePath>) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
        for file in files {
            try require(.file, at: directory.appendingPathComponent(file))
            guard file == "case.json" || file.hasSuffix(".md") else { throw CorpusError.unrecognizedFile }
            allFiles.insert(RelativePath(relative + "/" + file))
        }
        guard files.contains("case.json") else { throw CorpusError.unrecognizedCase }
        try consume(relative + "/case.json", in: &consumed)
        let data = try Data(contentsOf: directory.appendingPathComponent("case.json"))
        let fixture = try object(JSONSerialization.jsonObject(with: data))
        try keys(fixture, required: ["schema", "category", "query", "now", "prompts", "expected"])
        guard try integer(fixture["schema"]) == 1,
              fixture["category"] as? String == "ranking",
              let query = fixture["query"] as? String else { throw CorpusError.unrecognizedCase }
        let now = try timestamp(fixture["now"])
        let prompts = try array(fixture["prompts"])
        guard !prompts.isEmpty else { throw CorpusError.unrecognizedCase }
        var inputs = [PromptRanking.Input]()
        var paths = Set<RelativePath>()
        var identities = Set<PromptIdentity>()
        var events = [PromptIdentity: [Date]]()
        let clock = LibraryClock()
        clock.date = now
        let usage = UsageStore(files: MemoryFileStore(), clock: clock)

        for value in prompts {
            let prompt = try object(value)
            try keys(prompt, required: ["source", "path", "uses"])
            guard let source = prompt["source"] as? String, source.hasSuffix(".md"),
                  !source.contains("/"),
                  let path = prompt["path"] as? String else { throw CorpusError.unrecognizedCase }
            guard files.contains(where: { $0.utf8.elementsEqual(source.utf8) }) else {
                throw CorpusError.missingSource
            }
            try LibraryPath.validate(path)
            guard paths.insert(RelativePath(path)).inserted else { throw CorpusError.unrecognizedCase }
            try consume(relative + "/" + source, in: &consumed)
            let bytes = try Data(contentsOf: directory.appendingPathComponent(source))
            guard let text = String(data: bytes, encoding: .utf8) else { throw CorpusError.invalidUTF8 }
            let document = PromptCodec.parse(text, filename: LibraryPath.filename(path))
            guard document.canRender else { throw CorpusError.unrecognizedCase }
            let entry = LibraryEntry(path: path, document: document, stamp: FileStamp("fixture"))
            guard identities.insert(entry.identity).inserted else { throw CorpusError.unrecognizedCase }
            inputs.append(PromptRanking.Input(entry))
            // Uses are the full recording-order history. Exercise the real
            // store's 1,024-event retention before the shared pure ranking path.
            for use in try array(prompt["uses"]) {
                try usage.recordUse(identity: entry.identity, at: timestamp(use))
            }
            events[entry.identity] = try usage.useEvents(for: entry.identity)
        }

        let expected = try object(fixture["expected"])
        try keys(expected, required: ["results"])
        let results = try array(expected["results"]).map { value -> (path: RelativePath, score: Double, fields: [String]) in
            let result = try object(value)
            try keys(result, required: ["path", "score", "matchedFields"])
            guard let path = result["path"] as? String,
                  paths.contains(RelativePath(path)),
                  let fields = result["matchedFields"] as? [String],
                  Set(fields).isSubset(of: ["title", "tags", "folder", "description", "body"]) else {
                throw CorpusError.unrecognizedCase
            }
            return (RelativePath(path), try number(result["score"]), fields)
        }
        guard Set(results.map(\.path)).count == results.count else { throw CorpusError.unrecognizedCase }
        let actual = PromptRanking.rank(inputs, query: query, useEvents: events, at: now)
        XCTAssertEqual(actual.map { RelativePath($0.relativePath) }, results.map(\.path), relative)
        for (actual, expected) in zip(actual, results) {
            XCTAssertEqual(actual.score, expected.score, accuracy: rankingAccuracy, relative + "/" + expected.path.string)
            XCTAssertEqual(actual.matchedFields.map(searchField), expected.fields, relative)
        }
        XCTAssertEqual(clock.readCount, 0, "Fixture times must be explicit.")
    }

    private func searchField(_ field: PromptSearchField) -> String {
        switch field {
        case .title: return "title"
        case .tags: return "tags"
        case .folder: return "folder"
        case .description: return "description"
        case .body: return "body"
        }
    }

    private func consume(_ path: String, in consumed: inout Set<RelativePath>) throws {
        guard consumed.insert(RelativePath(path)).inserted else { throw CorpusError.duplicateConsumption }
    }

    private enum FixtureKind { case directory, file }

    private func require(_ kind: FixtureKind, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink == false else { throw CorpusError.unrecognizedFile }
        switch kind {
        case .directory:
            guard values.isDirectory == true else { throw CorpusError.unrecognizedFile }
        case .file:
            guard values.isRegularFile == true else { throw CorpusError.unrecognizedFile }
        }
    }

    // XCTest runs a class's tests serially; one formatter serves the corpus.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Accepts only the canonical `YYYY-MM-DDTHH:mm:ssZ` spelling: the value
    /// must round-trip unchanged, so `+00:00` and other offsets are rejected.
    private func timestamp(_ value: Any?) throws -> Date {
        let formatter = Self.timestampFormatter
        guard let text = value as? String, let date = formatter.date(from: text),
              formatter.string(from: date) == text else { throw CorpusError.unrecognizedCase }
        return date
    }

    private func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any] else { throw CorpusError.unrecognizedCase }
        return array
    }

    private func number(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue.isFinite else { throw CorpusError.unrecognizedCase }
        return number.doubleValue
    }

    private func metadata(_ value: FrontMatter) -> [String: Any] {
        ["id": value.id?.rawValue as Any? ?? NSNull(), "title": value.title,
         "description": value.description as Any? ?? NSNull(), "tags": value.tags,
         "favorite": value.favorite, "private": value.isPrivate, "format": value.format.decimalValue,
         "declarations": value.fields.map(field)]
    }

    private func fieldSettingsEdit(_ value: Any?, document: PromptDocument) throws -> PromptFieldSettings {
        let item = try object(value)
        try keys(item, required: ["name", "type", "label", "description", "default", "options", "optional", "remember"])
        guard let name = item["name"] as? String,
              var settings = PromptForm(document)?.fieldSettings.first(where: { $0.name == name }),
              let type = item["type"] as? String, let kind = FieldKind(rawValue: type),
              let label = item["label"] as? String else { throw CorpusError.unrecognizedCase }
        func nullableString(_ value: Any?) throws -> String? {
            if value is NSNull { return nil }
            guard let value = value as? String else { throw CorpusError.unrecognizedCase }
            return value
        }
        func boolean(_ value: Any?) throws -> Bool {
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else {
                throw CorpusError.unrecognizedCase
            }
            return number.boolValue
        }
        settings.kind = kind
        settings.label = label
        settings.description = try nullableString(item["description"])
        settings.defaultValue = try nullableString(item["default"])
        settings.optional = try boolean(item["optional"])
        settings.remember = try boolean(item["remember"])
        let original = settings.options
        settings.options = try array(item["options"]).map { element in
            let option = try object(element)
            try keys(option, required: ["label", "value"], optional: ["sourceIndex"])
            guard let label = option["label"] as? String, let value = option["value"] as? String else {
                throw CorpusError.unrecognizedCase
            }
            guard let index = option["sourceIndex"] else { return PromptFieldOptionSettings(label: label, value: value) }
            let offset = try integer(index)
            guard original.indices.contains(offset) else { throw CorpusError.unrecognizedCase }
            var changed = original[offset]
            changed.label = label
            changed.value = value
            return changed
        }
        return settings
    }

    private func field(_ value: PromptField) -> [String: Any] {
        ["name": value.name, "type": value.kind.rawValue, "label": value.label,
         "description": value.description as Any? ?? NSNull(), "default": value.defaultValue,
         "options": value.options.map { ["label": $0.label, "value": $0.value] },
         "optional": value.optional, "remember": value.remember, "implicit": value.isImplicit]
    }

    private func token(_ value: TemplateToken) -> [String: Any] {
        switch value {
        case .literal(let text): return ["kind": "literal", "text": text]
        case .escapedOpener: return ["kind": "escape"]
        case .placeholder(let name): return ["kind": "placeholder", "name": name]
        }
    }

    private func issues(_ value: PromptDocument) -> [[String: String]] {
        value.issues.map { ["code": $0.code.rawValue, "severity": $0.severity.rawValue] }
    }

    private func renderFailure(_ error: PromptRenderError) -> [String: Any] {
        switch error {
        case .invalidPrompt: return ["error": "invalid_prompt"]
        case .unsupportedFormat(let version): return ["error": "unsupported_format", "version": version.decimalValue]
        case .missingRequiredValue(let name): return ["error": "required_value_missing", "field": name]
        case .invalidChoiceValue(let name): return ["error": "choice_value_invalid", "field": name]
        case .missingBuiltin(let name): return ["error": "builtin_missing", "name": name.rawValue]
        }
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CorpusError.unrecognizedCase }
        return object
    }

    private func strings(_ value: Any) throws -> [String: String] {
        guard let values = value as? [String: String] else { throw CorpusError.unrecognizedCase }
        return values
    }

    private func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              let integer = value as? Int, number.doubleValue == Double(integer) else {
            throw CorpusError.unrecognizedCase
        }
        return integer
    }

    private func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw CorpusError.unrecognizedCase
        }
    }

    private enum CorpusError: Error, Equatable {
        case unknownCategory, emptyCategory, unrecognizedFile, missingSource
        case invalidUTF8, unrecognizedCase, duplicateConsumption, unconsumedFiles
    }
}
