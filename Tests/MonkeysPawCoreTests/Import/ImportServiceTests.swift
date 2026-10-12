import Foundation
import XCTest
@testable import MonkeysPawCore

final class ImportServiceTests: XCTestCase {
    private let suppliedID = "01K6Z4V9KQWZX7MPQ4T8ZNB2PD"

    func testReadsAndWritesRunOnWorkAndCallbacksWaitForMain() throws {
        let graph = ImportTestGraph()
        graph.sources.put("body", at: "/source/Example.md")
        var progress: [ImportProgress] = []
        var reports: [ImportReport] = []
        graph.service.import(.files(["/source/Example.md"]), progress: { progress.append($0) }, completion: { reports.append($0) })
        XCTAssertEqual(graph.work.jobs.count, 1)
        XCTAssertTrue(graph.sources.reads.isEmpty)
        XCTAssertEqual(graph.files.accessCount, 0)
        XCTAssertTrue(progress.isEmpty)
        graph.work.drain()
        XCTAssertEqual(graph.sources.reads.map(\.0), ["/source/Example.md"])
        XCTAssertEqual(graph.sources.reads.map(\.1), [Limits.importFileCapBytes])
        XCTAssertTrue(progress.isEmpty)
        XCTAssertTrue(reports.isEmpty)
        graph.main.drain()
        XCTAssertEqual(progress, [.enumerating, .importing(completed: 0, total: 1), .importing(completed: 1, total: 1)])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].files[0].outcome, .created(path: "Imported/Example.md"))
        XCTAssertEqual(try graph.files.text(at: "Imported/Example.md"), "body")
        XCTAssertNil(try graph.library.load(at: "Imported/Example.md").document.frontMatter.id)
    }

    func testOccupiedNamesAndRacesNeverOverwriteAndMoveToNextSuffix() throws {
        let graph = ImportTestGraph()
        try graph.files.put("existing", at: "Imported/Example.md")
        graph.sources.put("incoming", at: "/source/Example.md")
        var creations: [String] = []
        graph.files.onCreate = { path in
            creations.append(path)
            if path == "Imported/Example 2.md" {
                try graph.files.put("raced", at: path)
            }
        }
        let report = try XCTUnwrap(graph.run(.files(["/source/Example.md"])))
        XCTAssertEqual(report.files[0].outcome, .created(path: "Imported/Example 3.md"))
        XCTAssertEqual(creations, ["Imported/Example 2.md", "Imported/Example 3.md"])
        XCTAssertEqual(try graph.files.text(at: "Imported/Example.md"), "existing")
        XCTAssertEqual(try graph.files.text(at: "Imported/Example 2.md"), "raced")
        XCTAssertEqual(try graph.files.text(at: "Imported/Example 3.md"), "incoming")
        XCTAssertTrue(try graph.data.listFiles().isEmpty)
    }

    func testRacedDestinationsAreBoundedAndDoNotRetryOtherErrors() throws {
        let graph = ImportTestGraph()
        graph.sources.put("incoming", at: "/source/x.md")
        var count = 0
        graph.files.onCreate = { _ in count += 1; throw FileStoreError.alreadyExists }
        let report = try XCTUnwrap(graph.run(.files(["/source/x.md"])))
        XCTAssertEqual(report.files[0].outcome, .skipped(.library(.copyLimitReached)))
        XCTAssertEqual(count, Limits.libraryCreateAttemptCap)
        graph.files.onCreate = { _ in count += 1; throw FileStoreError.ioFailure }
        count = 0
        let failed = try XCTUnwrap(graph.run(.files(["/source/x.md"])))
        XCTAssertEqual(failed.files[0].outcome, .skipped(.fileStore(.ioFailure)))
        XCTAssertEqual(count, 1)
    }

    func testDuplicateIDsReceiveFreshIDsWithoutChangingOriginalOrItsState() throws {
        let graph = ImportTestGraph()
        let source = "---\r\n# preserve this\r\ncustom: {a: 7}\r\nid: '\(suppliedID)' # identity\r\n---\r\né\t{{name}}\r\n\n"
        try graph.files.put(source, at: "Old.md")
        try graph.data.put("old values", at: "usage/" + suppliedID)
        graph.sources.put(source, at: "/source/A.md")
        graph.sources.put(source, at: "/source/B.md")
        let report = try XCTUnwrap(graph.run(.files(["/source/B.md", "/source/A.md"])))
        XCTAssertEqual(report.createdCount, 2)
        let a = try graph.library.load(at: "Imported/A.md")
        let b = try graph.library.load(at: "Imported/B.md")
        XCTAssertNotEqual(a.document.frontMatter.id?.rawValue, suppliedID)
        XCTAssertNotEqual(a.document.frontMatter.id, b.document.frontMatter.id)
        XCTAssertEqual(Data(a.document.body.utf8), Data("é\t{{name}}\r\n\n".utf8))
        XCTAssertTrue(report.files.allSatisfy { $0.mapping.warnings.contains(.identityReassigned) })
        XCTAssertEqual(try graph.files.text(at: "Old.md"), source)
        XCTAssertEqual(try graph.data.text(at: "usage/" + suppliedID), "old values")
        let replacement = try XCTUnwrap(a.document.frontMatter.id?.rawValue)
        XCTAssertEqual(Data(a.document.source.utf8), Data(source.replacingOccurrences(of: suppliedID, with: replacement).utf8))
    }

    func testDuplicateWithinBatchIsDetectedAndUniqueIDSourcesRemainExact() throws {
        let graph = ImportTestGraph()
        let source = "---\nid: \(suppliedID.lowercased())\ncustom: value # keep\n---\nbody"
        graph.sources.put(source, at: "/source/A.md")
        graph.sources.put(source, at: "/source/B.md")
        let report = try XCTUnwrap(graph.run(.files(["/source/B.md", "/source/A.md"])))
        XCTAssertEqual(try graph.files.text(at: "Imported/A.md"), source)
        XCTAssertFalse(report.files[0].mapping.warnings.contains(.identityReassigned))
        XCTAssertTrue(report.files[1].mapping.warnings.contains(.identityReassigned))
        XCTAssertNotEqual(try graph.library.load(at: "Imported/A.md").identity,
                          try graph.library.load(at: "Imported/B.md").identity)
    }

    func testFreshIdentityGenerationRejectsAnOccupiedGeneratedID() throws {
        let files = MemoryFileStore(), data = MemoryFileStore()
        let clock = LibraryClock(), entropy = LibraryEntropy()
        let generated = try ULID.generate(at: clock.date, entropy: entropy.value)
        try files.put("---\nid: \(generated.rawValue)\n---\nbody", at: "Occupied.md")
        try files.put("---\nid: \(suppliedID)\n---\nbody", at: "Old.md")
        let sources = ImportMemorySources(), work = ImportWorkQueue()
        sources.put("---\nid: \(suppliedID)\n---\nbody", at: "/source/x.md")
        let library = LibraryService(library: files, data: data, clock: clock, entropy: entropy)
        let service = ImportService(library: library, sources: sources, work: work, main: ImportInlineMain())
        var report: ImportReport?
        service.import(.files(["/source/x.md"])) { report = $0 }
        work.drain()
        XCTAssertEqual(report?.files[0].outcome, .skipped(.identityLimitReached))
        XCTAssertEqual(entropy.requests.count, Limits.importIdentityAttemptCap)
        XCTAssertNil(try files.stamp(at: "Imported/x.md"))
    }

    func testFolderKeepsRelativeStructureAndRejectsSymlinksAndUnsafeEntries() throws {
        let graph = ImportTestGraph()
        graph.sources.entries = [
            ImportSourceEntry(relativePath: "Nested/A.prompt"),
            ImportSourceEntry(relativePath: "B.md"),
            ImportSourceEntry(relativePath: "Link", kind: .symbolicLink),
            ImportSourceEntry(relativePath: "pipe.md", kind: .other),
            ImportSourceEntry(relativePath: "../escape.md"),
            ImportSourceEntry(relativePath: "/absolute.md"),
            ImportSourceEntry(relativePath: "_drafts/hidden.md"),
            ImportSourceEntry(relativePath: ".git/ignored.md"),
            ImportSourceEntry(relativePath: "extra.txt")
        ]
        graph.sources.put("---\ninput:\n  schema:\n    name: string\n---\n{{name}}", at: "/selected/Nested/A.prompt")
        graph.sources.put("body", at: "/selected/B.md")
        let report = try XCTUnwrap(graph.run(.folder("/selected/"), into: "Custom/Sub"))
        XCTAssertEqual(report.createdCount, 2)
        XCTAssertEqual(report.skippedCount, 7)
        XCTAssertEqual(graph.sources.listed, ["/selected"])
        XCTAssertEqual(graph.sources.reads.map(\.0), ["/selected/B.md", "/selected/Nested/A.prompt"])
        XCTAssertNotNil(try graph.files.stamp(at: "Custom/Sub/Nested/A.md"))
        XCTAssertNotNil(try graph.files.stamp(at: "Custom/Sub/B.md"))
        XCTAssertTrue(report.files.contains { $0.outcome == .skipped(.symbolicLink) })
        XCTAssertTrue(report.files.contains { $0.outcome == .skipped(.notRegularFile) })
    }

    func testMixedFailuresRetainPartialResultsAndMappedDetails() throws {
        let graph = ImportTestGraph()
        graph.sources.put("good", at: "/source/A.md")
        graph.sources.files[Data("/source/B.md".utf8)] = Data([0xff])
        graph.sources.files[Data("/source/C.md".utf8)] = Data(repeating: 65, count: Limits.importFileCapBytes + 1)
        graph.sources.readErrors[Data("/source/D.md".utf8)] = .ioFailure
        graph.sources.put("---\ninputs:\n  name: {type: string}\n---\n{{name}}", at: "/source/E.prompty")
        graph.files.onCreate = { path in if path == "Imported/E.md" { throw FileStoreError.ioFailure } }
        let report = try XCTUnwrap(graph.run(.files(["/source/E.prompty", "/source/C.md", "/source/D.md", "/source/B.md", "/source/A.md"])))
        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 4)
        XCTAssertEqual(report.files.map(\.outcome), [.created(path: "Imported/A.md"), .skipped(.invalidUTF8),
            .skipped(.fileTooLarge), .skipped(.source(.ioFailure)), .skipped(.fileStore(.ioFailure))])
        XCTAssertEqual(report.files[4].mapping.mappings.map(\.fieldName), ["name"])
        XCTAssertEqual(try graph.files.text(at: "Imported/A.md"), "good")
    }

    func testDeterministicOrderingAndDuplicateSelectionsUseExactBytes() throws {
        let composed = "/source/é.md", decomposed = "/source/e\u{301}.md"
        func perform(_ paths: [String]) throws -> ImportReport {
            let graph = ImportTestGraph()
            graph.sources.put("composed", at: composed)
            graph.sources.put("decomposed", at: decomposed)
            return try XCTUnwrap(graph.run(.files(paths)))
        }
        let report = try perform([composed, decomposed, composed])
        XCTAssertEqual(report, try perform([composed, composed, decomposed]))
        XCTAssertEqual(report.createdCount, 2)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.files[2].outcome, .skipped(.duplicateSource))
        XCTAssertEqual(Data(report.files[0].sourcePath.utf8), Data(decomposed.utf8))
    }

    func testEnumerationAndInvalidDestinationsFailBeforeReading() throws {
        let graph = ImportTestGraph()
        graph.sources.listError = .ioFailure
        XCTAssertEqual(graph.run(.folder("/selected"))?.failure, .source(.ioFailure))
        XCTAssertTrue(graph.sources.reads.isEmpty)
        for target in ["", "../escape", "/absolute", ".hidden", "_drafts", "A//B", "A/../B", "A\\B",
                       "/\u{301}absolute", "A//\u{301}B", "A\\\u{301}B", "_\u{301}drafts", ".\u{301}hidden"] {
            let report = try XCTUnwrap(graph.run(.files(["/source/A.md"]), into: target))
            XCTAssertEqual(report.failure, .invalidPath, target)
            XCTAssertTrue(report.files.isEmpty)
        }
        XCTAssertTrue(graph.sources.reads.isEmpty)
    }

    func testRetirementDropsQueuedWorkAndQueuedCompletions() throws {
        let graph = ImportTestGraph()
        graph.sources.put("body", at: "/source/A.md")
        var completions = 0
        graph.service.import(.files(["/source/A.md"])) { _ in completions += 1 }
        graph.work.drain()
        graph.service.deactivate()
        graph.main.drain()
        XCTAssertEqual(completions, 0)
        XCTAssertNotNil(try graph.files.stamp(at: "Imported/A.md"))
        graph.service.import(.files(["/source/A.md"])) { _ in completions += 1 }
        graph.work.drain()
        XCTAssertEqual(graph.sources.reads.count, 1)
    }

    func testEmptySelectionCompletesWithAnEmptyReport() throws {
        let graph = ImportTestGraph()
        let report = try XCTUnwrap(graph.run(.files([])))
        XCTAssertEqual(report, ImportReport(files: [], failure: nil))
        XCTAssertTrue(graph.sources.reads.isEmpty)
    }

    func testSlashBeforeACombiningMarkStillSeparatesPathComponents() throws {
        let graph = ImportTestGraph()
        let filename = "\u{301}x.md"
        graph.sources.put("direct", at: "/source/" + filename)
        let direct = try XCTUnwrap(graph.run(.files(["/source/" + filename])))
        XCTAssertEqual(direct.files[0].outcome, .created(path: "Imported/" + filename))
        XCTAssertEqual(LibraryPath.filename("Nested/" + filename), filename)
        graph.sources.entries = [ImportSourceEntry(relativePath: ".hidden/" + filename)]
        graph.sources.put("hidden", at: "/source/.hidden/" + filename)
        let folder = try XCTUnwrap(graph.run(.folder("/source")))
        XCTAssertEqual(folder.files[0].outcome, .skipped(.invalidPath))
        XCTAssertEqual(graph.sources.reads.count, 1)
    }
}
