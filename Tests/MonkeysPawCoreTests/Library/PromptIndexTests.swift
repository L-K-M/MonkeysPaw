import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptIndexTests: XCTestCase {
    private var library: MemoryFileStore!
    private var data: MemoryFileStore!
    private var clock: LibraryClock!
    private var usage: UsageStore!
    private var service: LibraryService!
    private var index: PromptIndex!

    override func setUp() {
        library = MemoryFileStore()
        data = MemoryFileStore()
        clock = LibraryClock()
        clock.date = Date(timeIntervalSince1970: 1_800_000_000)
        usage = UsageStore(files: data, clock: clock)
        service = LibraryService(library: library, data: data, clock: clock,
                                 entropy: LibraryEntropy(), keyedStores: [usage])
        index = PromptIndex(service: service, usage: usage, clock: clock)
    }

    func testRebuildAndSearchAllFieldsExcludeNonMatchesAndPreserveIdentity() throws {
        try put("a.md", title: "Review", tags: ["code"], description: "Correctness", body: "Python")
        try put("notes/b.md", title: "Other", body: "Something else")
        try library.put("ignored", at: "_draft.md")
        XCTAssertTrue(index.search("").isEmpty)
        try index.rebuild()
        XCTAssertEqual(paths(""), ["notes/b.md", "a.md"])
        for (query, field) in [("rvw", PromptSearchField.title), ("code", .tags),
                               ("correctness", .description), ("python", .body)] {
            let result = try XCTUnwrap(index.search(query).first)
            XCTAssertEqual(result.relativePath, "a.md")
            XCTAssertEqual(result.identity, try service.load(at: "a.md").identity)
            XCTAssertEqual(result.matchedFields, [field])
            XCTAssertGreaterThan(result.score, 0)
        }
        XCTAssertEqual(paths("notes"), ["notes/b.md"])
        XCTAssertEqual(paths("#CODE rvw python"), ["a.md"])
        XCTAssertTrue(paths("#cod").isEmpty)
        XCTAssertTrue(paths("rvw nonexistent").isEmpty)
        let libraryReads = library.accessCount
        let dataReads = data.accessCount
        _ = index.search("rvw")
        XCTAssertEqual(library.accessCount, libraryReads)
        XCTAssertEqual(data.accessCount, dataReads, "Search uses only in-memory events.")
        try library.delete(at: "a.md")
        try index.rebuild()
        XCTAssertEqual(paths(""), ["notes/b.md"])
    }

    func testApplyCreatedModifiedDeletedAndReadsOnlyChangedPaths() throws {
        try put("a.md", title: "Before")
        try put("b.md", title: "Delete")
        try index.rebuild()
        try put("a.md", title: "After", tags: ["edited"])
        try put("c.md", title: "Created")
        try library.delete(at: "b.md")
        let lists = library.listCount
        try index.apply(LibraryChangeSet(created: ["c.md"], modified: ["a.md"], deleted: ["b.md"]))
        XCTAssertEqual(paths(""), ["a.md", "c.md"])
        XCTAssertEqual(paths("#edited after"), ["a.md"])
        XCTAssertTrue(paths("before").isEmpty)
        XCTAssertEqual(library.listCount, lists)
        try index.apply(LibraryChangeSet())
        XCTAssertEqual(paths(""), ["a.md", "c.md"])
    }

    func testApplyDropsMissingPathsBeforeLoadAndDuringStampReadRace() throws {
        try put("a.md", title: "Before")
        try index.rebuild()
        try library.delete(at: "a.md")
        try index.apply(LibraryChangeSet(created: ["gone.md"], modified: ["a.md"]))
        XCTAssertTrue(paths("").isEmpty)
        try put("a.md", title: "Before")
        try index.rebuild()
        library.onRead = { [weak library] path in
            library?.onRead = nil
            try library?.delete(at: path)
        }
        try index.apply(LibraryChangeSet(modified: ["a.md"]))
        XCTAssertTrue(paths("").isEmpty)
    }

    func testApplyRetriesOneConcurrentModificationButReportsPersistentConflicts() throws {
        try put("a.md", title: "Before")
        try index.rebuild()
        library.onRead = { [weak library] path in
            library?.onRead = nil
            try library?.put("New body", at: path)
        }
        try index.apply(LibraryChangeSet(modified: ["a.md"]))
        XCTAssertEqual(paths("new"), ["a.md"])
        library.onRead = { [weak library] path in try library?.put("Still changing", at: path) }
        XCTAssertThrowsError(try index.apply(LibraryChangeSet(modified: ["a.md"]))) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        XCTAssertEqual(paths("new"), ["a.md"])
    }

    func testInvalidEntriesKeepAvailableFieldsIssuesAndReadOnlyState() throws {
        try library.put("---\ntitle: [broken\n---\nSearchable", at: "bad.md")
        try library.write(Data([0xff, 0xfe]), at: "bytes.md")
        try library.write(Data(repeating: 0x78, count: Limits.maxPromptBytes + 1), at: "large.md")
        try library.put("---\ntitle: Future\nformat: 2\n---\nBody", at: "future.md")
        try index.rebuild()
        let results = index.search("")
        XCTAssertEqual(Set(results.map(\.relativePath)), ["bad.md", "bytes.md", "large.md", "future.md"])
        XCTAssertEqual(index.search("bad").first?.entry.issues.map(\.code), [.invalidYAML])
        XCTAssertEqual(index.search("bytes").first?.entry.issues.map(\.code), [.invalidUTF8])
        XCTAssertEqual(index.search("large").first?.entry.issues.map(\.code), [.sourceTooLarge])
        XCTAssertEqual(paths("searchable"), ["bad.md"])
        XCTAssertTrue(try XCTUnwrap(index.search("future").first).entry.document.isReadOnly)
        try library.write(Data([0xff]), at: "new.md")
        try index.apply(LibraryChangeSet(created: ["new.md"]))
        XCTAssertEqual(index.search("new").first?.entry.issues.map(\.code), [.invalidUTF8])
        try library.put("---\ntitle: [broken\n---\nChanged", at: "bytes.md")
        try index.apply(LibraryChangeSet(modified: ["bytes.md"]))
        XCTAssertEqual(paths("changed"), ["bytes.md"])
        XCTAssertEqual(index.search("bytes").first?.entry.issues.map(\.code), [.invalidYAML])
    }

    func testUnreadableEntriesFailAsLibraryEntriesDoAndKeepLastCompleteIndex() throws {
        try put("a.md", title: "Before")
        try put("z.md", title: "Keep")
        try index.rebuild()
        library.onRead = { _ in throw FileStoreError.ioFailure }
        XCTAssertThrowsError(try service.entries()) { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
        XCTAssertThrowsError(try index.rebuild()) { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
        XCTAssertThrowsError(try index.apply(LibraryChangeSet(modified: ["a.md"], deleted: ["z.md"]))) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(paths(""), ["a.md", "z.md"])
        library.onRead = { _ in throw NSError(domain: "private path and content", code: 1) }
        XCTAssertThrowsError(try index.apply(LibraryChangeSet(modified: ["a.md"]))) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
    }

    func testCorruptUsageFailsRebuildAndApplyAndKeepsLastCompleteIndex() throws {
        try put("a.md", title: "n")
        try put("b.md", title: "n")
        try index.rebuild()
        let identity = try service.load(at: "b.md").identity
        try index.recordUse(of: identity)
        let previous = index.search("n")
        XCTAssertEqual(previous.map(\.relativePath), ["b.md", "a.md"])
        XCTAssertEqual(previous.map(\.score), [8, 4])

        try put("a.md", title: "After")
        try put("c.md", title: "Created")
        try data.put("{malformed", at: "usage/" + identity.storageKey)
        XCTAssertThrowsError(try index.rebuild()) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
        XCTAssertEqual(index.search("n").map(\.relativePath), previous.map(\.relativePath))
        XCTAssertEqual(index.search("n").map(\.score), previous.map(\.score))
        XCTAssertTrue(paths("after").isEmpty)
        XCTAssertTrue(paths("created").isEmpty)

        XCTAssertThrowsError(try index.apply(LibraryChangeSet(created: ["c.md"], modified: ["b.md"],
                                                            deleted: ["a.md"]))) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
        XCTAssertEqual(index.search("n").map(\.relativePath), previous.map(\.relativePath))
        XCTAssertEqual(index.search("n").map(\.score), previous.map(\.score))
        XCTAssertTrue(paths("created").isEmpty)
    }

    func testRankingFormulaFavoritesAndDecayAtInjectedClock() throws {
        try put("used.md", title: "n")
        try put("favorite.md", title: "n", favorite: true)
        let used = try service.load(at: "used.md").identity
        for age: Double in [0, 14, 28] {
            try usage.recordUse(identity: used, at: clock.date.addingTimeInterval(-age * 86_400))
        }
        try index.rebuild()
        var results = index.search("n")
        XCTAssertEqual(results.map(\.relativePath), ["used.md", "favorite.md"])
        XCTAssertEqual(results[0].score, 4 * (1 + 1 + 0.5 + 0.25), accuracy: 1e-12)
        XCTAssertEqual(results[1].score, 4 * 1.5, accuracy: 1e-12)
        clock.date = clock.date.addingTimeInterval(14 * 86_400)
        results = index.search("n")
        XCTAssertEqual(results[0].score, 4 * (1 + 0.5 + 0.25 + 0.125), accuracy: 1e-12)
        clock.date = clock.date.addingTimeInterval(14 * 86_400)
        XCTAssertEqual(paths("n").first, "favorite.md")
    }

    func testRankingCapIsAppliedBeforeFavoriteMultiplication() throws {
        try put("favorite.md", title: "n", favorite: true)
        let identity = try service.load(at: "favorite.md").identity
        for _ in 0..<40 { try usage.recordUse(identity: identity) }
        try index.rebuild()
        XCTAssertEqual(index.search("n").first?.score, 4 * 33 * 1.5)
        XCTAssertEqual(index.search("").first?.score, 32)
    }

    func testEmptyQueryOrderingAndStableTitlePathByteTies() throws {
        try put("recent.md", title: "Z")
        try put("favorite.md", title: "Z", favorite: true)
        try put("b.md", title: "a")
        try put("a.md", title: "a")
        try put("uppercase.md", title: "A")
        try put("accent.md", title: "é")
        try index.rebuild()
        try index.recordUse(of: service.load(at: "recent.md").identity)
        let expected = ["recent.md", "favorite.md", "uppercase.md", "a.md", "b.md", "accent.md"]
        XCTAssertEqual(paths(""), expected)
        XCTAssertEqual(paths("\t \n"), expected)
        XCTAssertEqual(index.search("").map(\.score), [1, 0, 0, 0, 0, 0])
        for _ in 0..<5 {
            XCTAssertEqual(paths("a"), ["uppercase.md", "a.md", "b.md"])
            try index.rebuild()
            XCTAssertEqual(paths(""), expected)
        }
    }

    func testCanonicallyEquivalentButByteDistinctPathsAndTitlesAreNotCollapsed() throws {
        let decomposed = "e\u{301}.md"
        let composed = "é.md"
        try put(composed, title: "n")
        try put(decomposed, title: "n")
        try index.rebuild()
        XCTAssertEqual(index.search("n").map { Data($0.relativePath.utf8) }, [Data(decomposed.utf8), Data(composed.utf8)])
        try library.delete(at: composed)
        try index.apply(LibraryChangeSet(deleted: [composed]))
        XCTAssertEqual(index.search("n").map { Data($0.relativePath.utf8) }, [Data(decomposed.utf8)])
        try put("composed.md", title: "é")
        try put("decomposed.md", title: "e\u{301}")
        try index.rebuild()
        XCTAssertEqual(paths("é"), ["decomposed.md", "composed.md"])
    }

    func testRecordUseWritesThroughAndFailedPersistenceLeavesRankingUnchanged() throws {
        try put("a.md", title: "n")
        try put("b.md", title: "n")
        try index.rebuild()
        let identity = try service.load(at: "b.md").identity
        try index.recordUse(of: identity)
        XCTAssertEqual(try usage.useEvents(for: identity), [clock.date])
        XCTAssertEqual(paths("n"), ["b.md", "a.md"])
        XCTAssertEqual(index.search("n")[0].score, 8)
        data.failNextWrite = true
        XCTAssertThrowsError(try index.recordUse(of: identity)) { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
        XCTAssertEqual(index.search("n")[0].score, 8)
        XCTAssertEqual(try usage.useEvents(for: identity), [clock.date])
        let fresh = PromptIndex(service: service, usage: usage, clock: clock)
        try fresh.rebuild()
        XCTAssertEqual(fresh.search("n").map(\.score), index.search("n").map(\.score))
    }

    func testApplyReloadsMigratedIdentityUsage() throws {
        try put("a.md", title: "n")
        try index.rebuild()
        try index.recordUse(of: service.load(at: "a.md").identity)
        let moved = try service.move(from: "a.md", to: "b.md")
        try index.apply(LibraryChangeSet(created: ["b.md"], deleted: ["a.md"]))
        XCTAssertEqual(index.search("n").first?.identity, moved.identity)
        XCTAssertEqual(index.search("n").first?.score, 8)
        let assigned = try service.assignIdentity(to: "b.md")
        try index.apply(LibraryChangeSet(modified: ["b.md"]))
        XCTAssertEqual(index.search("n").first?.identity, assigned.identity)
        XCTAssertEqual(index.search("n").first?.score, 8)
    }

    func testThreeThousandEntryRebuildPerformanceSmoke() throws {
        for number in 0..<3_000 {
            let path = "folder/Prompt \(number).md"
            try library.put("Explain the supplied topic.\nUse examples and concise prose.\n", at: path)
        }
        let start = ContinuousClock.now
        try index.rebuild()
        let elapsed = start.duration(to: .now)
        print("M2d: 3,000-entry in-memory rebuild took \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(3), "3,000-entry rebuild took \(elapsed); §5.4 smoke bound gives slower CI hosts headroom.")
        XCTAssertEqual(index.search("").count, 3_000)
        XCTAssertEqual(library.listCount, 1)
        XCTAssertEqual(data.listCount, 0, "Usage lookups must not scan data per entry.")
    }

    private func paths(_ query: String) -> [String] { index.search(query).map(\.relativePath) }

    private func put(_ path: String, title: String, tags: [String] = [], description: String = "",
                     favorite: Bool = false, body: String = "") throws {
        let tagList = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        try library.put("---\ntitle: \"\(title)\"\ntags: [\(tagList)]\ndescription: \"\(description)\"\nfavorite: \(favorite)\n---\n" + body,
                        at: path)
    }
}
