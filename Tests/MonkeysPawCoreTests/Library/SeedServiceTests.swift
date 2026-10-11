import Foundation
import XCTest
@testable import MonkeysPawCore

final class SeedServiceTests: XCTestCase {
    private var files: MemoryFileStore!
    private var data: MemoryFileStore!
    private var library: LibraryService!
    private var entropy: SeedTestEntropy!
    private var service: SeedService!

    override func setUp() {
        files = MemoryFileStore()
        data = MemoryFileStore()
        entropy = SeedTestEntropy()
        library = LibraryService(library: files, data: data, clock: LibraryClock(), entropy: entropy)
        service = SeedService(library: library)
    }

    func testEmptyLibrarySeedsAllPromptsAsFirstRealSavesWithFreshIdentities() throws {
        let summary = try service.seedIfEmpty()
        XCTAssertEqual(summary, SeedSummary(seededCount: SeedCatalog.prompts.count, skippedExistingCount: 0))
        let entries = try library.entries()
        XCTAssertEqual(entries.map(\.relativePath), SeedCatalog.prompts.map(\.relativePath))
        XCTAssertEqual(Set(entries.map(\.identity)).count, entries.count)
        XCTAssertEqual(entropy.requests, Array(repeating: Limits.ulidEntropyBytes, count: entries.count))
        for (entry, seed) in zip(entries, SeedCatalog.prompts) {
            let source = PromptCodec.parseFile(seed.bytes, filename: LibraryPath.filename(seed.relativePath))
            XCTAssertNil(source.frontMatter.id)
            XCTAssertNotNil(entry.document.frontMatter.id)
            XCTAssertTrue(entry.issues.isEmpty)
            XCTAssertEqual(Data(entry.document.body.utf8), Data(source.body.utf8))
            XCTAssertEqual(entry.document.frontMatter.title, source.frontMatter.title)
            XCTAssertEqual(entry.document.frontMatter.fields, source.frontMatter.fields)
            XCTAssertEqual(try files.text(at: entry.relativePath), try PromptCodec.write(entry.document))
            XCTAssertTrue(try library.history(for: entry.identity).isEmpty)
        }
        XCTAssertTrue(try data.listFiles().isEmpty)
        let firstBytes = try entries.map { try files.read(at: $0.relativePath) }
        let firstStamps = entries.map(\.stamp)
        XCTAssertEqual(try service.seedIfEmpty(), SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertEqual(try entries.map { try files.read(at: $0.relativePath) }, firstBytes)
        XCTAssertEqual(try library.entries().map(\.stamp), firstStamps)
        XCTAssertEqual(entropy.requests.count, entries.count)
    }

    func testOnePromptBlocksAllSeeding() throws {
        let original = Data("User prompt\r\n".utf8)
        try files.write(original, at: "mine.md")
        XCTAssertEqual(try service.seedIfEmpty(), SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["mine.md"])
        XCTAssertEqual(try files.read(at: "mine.md"), original)
        XCTAssertTrue(entropy.requests.isEmpty)
    }

    func testMalformedPromptStillBlocksSeeding() throws {
        try files.write(Data([0xff, 0xfe]), at: "broken.md")
        XCTAssertEqual(try service.seedIfEmpty(), SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["broken.md"])
        XCTAssertTrue(entropy.requests.isEmpty)
    }

    func testREADMEOnlyLibraryIsEmptyAndDocumentationSurvives() throws {
        let readme = Data("My library documentation\r\n".utf8)
        try files.write(readme, at: "README.md")
        XCTAssertEqual(try service.seedIfEmpty().seededCount, SeedCatalog.prompts.count)
        XCTAssertEqual(try files.read(at: "README.md"), readme)
        XCTAssertEqual(try library.entries().count, SeedCatalog.prompts.count)
    }

    func testNonPromptAndIgnoredFilesDoNotBlockSeeding() throws {
        let ignored = [".DS_Store", "notes.txt", "a.MD", "_drafts/prompt.md", ".git/prompt.md", "_private.md"]
        for path in ignored { try files.put("Keep", at: path) }
        XCTAssertEqual(try service.seedIfEmpty().seededCount, SeedCatalog.prompts.count)
        for path in ignored { XCTAssertEqual(try files.text(at: path), "Keep") }
    }

    func testNestedREADMEIsAPromptAndBlocksSeeding() throws {
        try files.put("Nested prompt", at: "notes/README.md")
        XCTAssertEqual(try service.seedIfEmpty(), SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertTrue(entropy.requests.isEmpty)
    }

    func testDestinationAppearingAfterListingIsSkippedWithoutChangingItsBytes() throws {
        let path = try XCTUnwrap(SeedCatalog.prompts.first?.relativePath)
        let original = Data("External prompt\r\n".utf8)
        var externalStamp: FileStamp?
        files.onCreate = { [files] candidate in
            XCTAssertEqual(candidate, path)
            files?.onCreate = nil
            try files?.write(original, at: candidate)
            externalStamp = try files?.stamp(at: candidate)
        }
        let summary = try service.seedIfEmpty()
        XCTAssertEqual(summary, SeedSummary(seededCount: SeedCatalog.prompts.count - 1, skippedExistingCount: 1))
        XCTAssertEqual(files.listCount, 1, "The injected destination appeared after the empty listing.")
        XCTAssertEqual(try files.read(at: path), original)
        XCTAssertEqual(try files.stamp(at: path), externalStamp)
        XCTAssertEqual(try library.entries().count, SeedCatalog.prompts.count)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testPartialFailureLeavesNonEmptyLibraryAndRetrySeedsNothing() throws {
        var attempts = 0
        files.onCreate = { _ in
            attempts += 1
            if attempts == 2 { throw FileStoreError.ioFailure }
        }
        XCTAssertThrowsError(try service.seedIfEmpty()) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        let entry = try XCTUnwrap(library.entries().first)
        XCTAssertEqual(try library.entries().count, 1)
        let first = try files.read(at: entry.relativePath)
        files.onCreate = nil
        XCTAssertEqual(try service.seedIfEmpty(), SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertEqual(try library.entries().count, 1)
        XCTAssertEqual(try files.read(at: entry.relativePath), first)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(entropy.requests.count, 2)
    }

    func testFailureBeforeFirstPublicationAllowsALaterRetry() throws {
        files.failNextWrite = true
        XCTAssertThrowsError(try service.seedIfEmpty()) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertEqual(try service.seedIfEmpty().seededCount, SeedCatalog.prompts.count)
    }

    func testHistoryMigrationCollisionIsAFailureRatherThanASkippedSeed() throws {
        let seed = try XCTUnwrap(SeedCatalog.prompts.first)
        let identity = PromptIdentity(path: seed.relativePath, id: nil)
        let source = "history/" + (try identity.storageKey) + "/20261010T130700.123Z-000000.md"
        let previous = Data("Previous revision".utf8)
        let external = Data("Concurrent revision".utf8)
        try data.write(previous, at: source)
        var occupied: String?
        data.onMove = { [data] _, destination in
            data?.onMove = nil
            occupied = destination
            try data?.write(external, at: destination)
        }
        XCTAssertThrowsError(try service.seedIfEmpty()) {
            XCTAssertEqual($0 as? FileStoreError, .alreadyExists)
        }
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertEqual(entropy.requests.count, 1)
        XCTAssertEqual(try data.read(at: source), previous)
        XCTAssertEqual(try data.read(at: XCTUnwrap(occupied)), external)
    }

    func testUntypedStoreFailureIsSanitizedWithoutLeakingContentOrPaths() throws {
        let marker = "sensitive-path-and-content"
        files.onCreate = { _ in
            throw NSError(domain: marker, code: 42, userInfo: [NSLocalizedDescriptionKey: marker])
        }
        XCTAssertThrowsError(try service.seedIfEmpty()) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
            XCTAssertFalse(String(describing: $0).contains(marker))
            XCTAssertFalse($0.localizedDescription.contains(marker))
        }
        XCTAssertTrue(try library.entries().isEmpty)
    }
}

private final class SeedTestEntropy: EntropySource {
    private(set) var requests = [Int]()

    func bytes(count: Int) throws -> [UInt8] {
        requests.append(count)
        return Array(repeating: UInt8(requests.count), count: count)
    }
}
