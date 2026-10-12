import Foundation
import XCTest
@testable import MonkeysPawCore

final class LibraryCreateTests: XCTestCase {
    private var files: MemoryFileStore!
    private var data: MemoryFileStore!
    private var clock: LibraryClock!
    private var entropy: LibraryEntropy!
    private var keyed: MemoryKeyedStore!
    private var service: LibraryService!

    override func setUp() {
        files = MemoryFileStore()
        data = MemoryFileStore()
        clock = LibraryClock()
        entropy = LibraryEntropy()
        keyed = MemoryKeyedStore()
        service = LibraryService(library: files, data: data, clock: clock, entropy: entropy, keyedStores: [keyed])
    }

    func testTitleCreationPreservesAFileArrivingAfterTheNameProbe() throws {
        let original = Data([0xff, 0xfe, 0x0a, 0x00])
        let occupiedLocal = PromptIdentity(path: "New.md", id: nil)
        keyed.values[occupiedLocal] = "External state"
        files.onStamp = { [files] path, stamp in
            guard path == "New.md", stamp == nil else { return }
            files?.onStamp = nil
            try files?.write(original, at: path)
        }

        let entry = try service.createPrompt(titled: "New", body: "New body\r\n")

        XCTAssertEqual(try files.read(at: "New.md"), original)
        XCTAssertEqual(entry.relativePath, "New 2.md")
        XCTAssertEqual(entry.document.frontMatter.title, "New")
        XCTAssertEqual(entry.document.body, "New body\r\n")
        XCTAssertNotNil(entry.document.frontMatter.id)
        XCTAssertEqual(keyed.values, [occupiedLocal: "External state"])
        XCTAssertTrue(try service.history(for: entry.identity).isEmpty)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testTitleCreationBoundsOccupiedDestinationRetries() throws {
        let original = Data("External bytes\r\n".utf8)
        let occupiedLocal = PromptIdentity(path: "New.md", id: nil)
        keyed.values[occupiedLocal] = "External state"
        var occupiedPaths = [String]()
        files.onStamp = { [files] path, stamp in
            guard stamp == nil else { return }
            occupiedPaths.append(path)
            try files?.write(original, at: path)
        }

        XCTAssertThrowsError(try service.createPrompt(titled: "New", body: "New body")) {
            XCTAssertEqual($0 as? LibraryError, .copyLimitReached)
        }
        files.onStamp = nil

        XCTAssertEqual(occupiedPaths.count, Limits.libraryCreateAttemptCap)
        XCTAssertEqual(occupiedPaths.first, "New.md")
        XCTAssertEqual(occupiedPaths.last, "New \(Limits.libraryCreateAttemptCap).md")
        for path in occupiedPaths {
            XCTAssertEqual(try files.read(at: path), original)
        }
        XCTAssertEqual(keyed.values, [occupiedLocal: "External state"])
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testTitleCreationAdvancesWhenARacedDestinationIsRemovedBeforeRetry() throws {
        var attempts = [String]()
        files.onCreate = { [files] path in
            attempts.append(path)
            guard path == "New.md" else { return }
            try files?.put("External", at: path)
            try files?.delete(at: path)
            // The external file existed at publication but disappeared before the error returned.
            throw FileStoreError.alreadyExists
        }
        defer { files.onCreate = nil }

        let entry = try service.createPrompt(titled: "New", body: "Body")

        XCTAssertEqual(attempts, ["New.md", "New 2.md"])
        XCTAssertEqual(entry.relativePath, "New 2.md")
        XCTAssertNil(try files.stamp(at: "New.md"))
    }

    func testTitleCreationReturnsTypedExhaustionAtTheLastAlternateName() throws {
        try files.put("Existing", at: "New.md")
        for suffix in 2...Limits.libraryCopyCandidateCap {
            try files.put("Existing", at: "New \(suffix).md")
        }
        let lastPath = "New \(Limits.libraryCopyCandidateCap + 1).md"
        var attempts = [String]()
        files.onCreate = { [files] path in
            attempts.append(path)
            try files?.put("External", at: path)
        }
        defer { files.onCreate = nil }

        XCTAssertThrowsError(try service.createPrompt(titled: "New", body: "Body")) {
            XCTAssertEqual($0 as? LibraryError, .copyLimitReached)
        }

        XCTAssertEqual(attempts, [lastPath])
        XCTAssertEqual(try files.text(at: lastPath), "External")
        XCTAssertEqual(try files.listFiles().count, Limits.libraryCopyCandidateCap + 1)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testTitleCreationDoesNotRetryAnIOFailure() throws {
        var attempts = [String]()
        files.onCreate = { path in
            attempts.append(path)
            throw FileStoreError.ioFailure
        }

        XCTAssertThrowsError(try service.createPrompt(titled: "New", body: "Body")) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }

        XCTAssertEqual(attempts, ["New.md"])
        XCTAssertTrue(try files.listFiles().isEmpty)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testTitleCreationKeepsNormalFirstSaveBytesIdentityAndMigration() throws {
        let title = "  a/b: \"name\"  "
        let body = "  Body 👋\r\n\r\n"
        let path = PromptCreation.relativePath(title: title, now: clock.date)
        let local = PromptIdentity(path: path, id: nil)
        keyed.values[local] = "Remembered state"

        let entry = try service.createPrompt(titled: title, body: body)

        let id = try ULID.generate(at: clock.date, entropy: entropy.value)
        let draft = try PromptCodec.newDocument(title: title, body: body)
        let expected = try PromptCodec.assigningIdentity(id, to: draft)
        XCTAssertEqual(entry.relativePath, path)
        XCTAssertEqual(entry.identity, .assigned(id))
        XCTAssertEqual(entry.document.frontMatter.title, title)
        XCTAssertEqual(Data(entry.document.body.utf8), Data(body.utf8))
        XCTAssertEqual(try files.text(at: path), try PromptCodec.write(expected))
        XCTAssertTrue(try files.text(at: path).hasPrefix("---\nid: \(id.rawValue)\ntitle:"))
        XCTAssertEqual(entropy.requests, [Limits.ulidEntropyBytes])
        XCTAssertNil(keyed.values[local])
        XCTAssertEqual(keyed.values[entry.identity], "Remembered state")
        XCTAssertTrue(try service.history(for: entry.identity).isEmpty)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testCreateIsARealSaveWithIdentityMigrationAndExactBodyButNoSnapshot() throws {
        let path = "nested/new.md"
        let local = PromptIdentity(path: path, id: nil)
        keyed.values[local] = "Remembered state"
        let body = "  Body 👋\r\n\r\n"
        let document = PromptCodec.parse("---\ntitle: New\nextra: kept\n---\n" + body, filename: "new.md")
        let entry = try service.create(document, at: path)
        let expectedID = try ULID.generate(at: clock.date, entropy: entropy.value)
        XCTAssertEqual(entry.identity, .assigned(expectedID))
        XCTAssertEqual(entropy.requests, [Limits.ulidEntropyBytes])
        XCTAssertEqual(Data(entry.document.body.utf8), Data(body.utf8))
        XCTAssertEqual(try files.text(at: path), try PromptCodec.write(entry.document))
        XCTAssertTrue(try files.text(at: path).contains("extra: kept\n"))
        XCTAssertNil(keyed.values[local])
        XCTAssertEqual(keyed.values[entry.identity], "Remembered state")
        XCTAssertTrue(try service.history(for: entry.identity).isEmpty)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testCreatePreservesASuppliedIdentityWithoutGeneratingAnother() throws {
        let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let document = PromptCodec.parse("---\nid: \(id)\n---\nBody", filename: "a.md")
        let entry = try service.create(document, at: "a.md")
        XCTAssertEqual(entry.document.frontMatter.id?.rawValue, id)
        XCTAssertTrue(entropy.requests.isEmpty)
    }

    func testOccupiedDestinationIsNeverReadChangedOrSnapshotted() throws {
        let originals = [Data("Plain body".utf8), Data("---\ntitle: [broken\n---\nBody".utf8),
                         Data([0xff, 0xfe]), Data("---\nformat: 999\n---\nFuture".utf8)]
        let document = PromptCodec.parse("Replacement", filename: "a.md")
        for (index, original) in originals.enumerated() {
            let path = "occupied\(index).md"
            try files.write(original, at: path)
            let stamp = try files.stamp(at: path)
            files.onRead = { _ in XCTFail("Exclusive create must not read occupied bytes.") }
            XCTAssertThrowsError(try service.create(document, at: path)) {
                XCTAssertEqual($0 as? LibraryError, .destinationOccupied)
            }
            files.onRead = nil
            XCTAssertEqual(try files.read(at: path), original)
            XCTAssertEqual(try files.stamp(at: path), stamp)
        }
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testDestinationAppearingDuringCreateSurvivesAndMigrationsRollBack() throws {
        let path = "new.md"
        let local = PromptIdentity(path: path, id: nil)
        keyed.values[local] = "Old keyed state"
        let original = Data("External bytes\r\n".utf8)
        files.onCreate = { [files] path in
            files?.onCreate = nil
            try files?.write(original, at: path)
        }
        XCTAssertThrowsError(try service.create(PromptCodec.parse("New", filename: path), at: path)) {
            XCTAssertEqual($0 as? LibraryError, .destinationOccupied)
        }
        XCTAssertEqual(try files.read(at: path), original)
        XCTAssertEqual(keyed.values, [local: "Old keyed state"])
        XCTAssertEqual(keyed.migrations.count, 2)
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testFailedPublicationRollsBackStateAndReturnsTypedFailure() throws {
        let path = "new.md"
        let local = PromptIdentity(path: path, id: nil)
        keyed.values[local] = "Old keyed state"
        files.failNextWrite = true
        XCTAssertThrowsError(try service.create(PromptCodec.parse("New", filename: path), at: path)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertNil(try files.stamp(at: path))
        XCTAssertEqual(keyed.values, [local: "Old keyed state"])
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testInvalidFutureAndIgnoredDraftsCannotBeCreated() throws {
        let invalid = PromptCodec.parse("{{broken", filename: "a.md")
        let future = PromptCodec.parse("---\nformat: 2\n---\nBody", filename: "a.md")
        XCTAssertThrowsError(try service.create(invalid, at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
        }
        XCTAssertThrowsError(try service.create(future, at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(future.frontMatter.format))
        }
        XCTAssertThrowsError(try service.create(PromptCodec.parse("Body", filename: "README.md"), at: "README.md")) {
            XCTAssertEqual($0 as? LibraryError, .invalidPromptPath)
        }
        XCTAssertTrue(try files.listFiles().isEmpty)
        XCTAssertTrue(entropy.requests.isEmpty)
    }
}
