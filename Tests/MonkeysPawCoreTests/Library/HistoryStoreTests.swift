import Foundation
import XCTest
@testable import MonkeysPawCore

final class HistoryStoreTests: XCTestCase {
    private var files: MemoryFileStore!
    private var store: HistoryStore!
    private let identity = PromptIdentity(path: "a.md", id: nil)
    private let date = Date(timeIntervalSince1970: 1.234)

    override func setUp() {
        files = MemoryFileStore()
        store = HistoryStore(files: files)
    }

    func testMalformedFilenamesAreRejectedWithoutAccessingFiles() throws {
        let directory = "history/" + (try identity.storageKey)
        try files.put("Keep", at: directory + "/not-a-revision.md")
        try files.put("Keep too", at: directory + "/19701301T000001.234Z-000000.md")
        let before = try files.listFiles()
        let accesses = files.accessCount
        let filenames = ["", "/", "..", "/19700101T000001.234Z-000000.md",
                         "../19700101T000001.234Z-000000.md", "nested/19700101T000001.234Z-000000.md",
                         "19700101T000001.234Z-00000.md", "19700101T000001.234Z-0000000.md",
                         "19701301T000001.234Z-000000.md", "19700132T000001.234Z-000000.md",
                         "19700101T000001.234Z-00000x.md", "19700101T000001.234Z-000000.txt",
                         "not-a-revision.md"]
        for filename in filenames {
            let revision = HistoryRevision(identity: identity, filename: filename, timestamp: date)
            XCTAssertThrowsError(try store.remove(revision), filename) {
                XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
            }
            XCTAssertEqual(files.accessCount, accesses, filename)
            XCTAssertThrowsError(try store.read(revision), filename) {
                XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
            }
            XCTAssertEqual(files.accessCount, accesses, filename)
        }
        XCTAssertEqual(try files.listFiles(), before)
        XCTAssertEqual(try files.text(at: directory + "/not-a-revision.md"), "Keep")
        XCTAssertEqual(try files.text(at: directory + "/19701301T000001.234Z-000000.md"), "Keep too")
    }

    func testReadIgnoresCallerTimestampWithoutListingFiles() throws {
        let bytes = Data("Revision\r\n".utf8)
        let revision = try store.snapshot(bytes, for: identity, at: date)
        let drifted = HistoryRevision(identity: identity, filename: revision.filename,
                                      timestamp: revision.timestamp.addingTimeInterval(1))
        let listings = files.listCount
        XCTAssertEqual(try store.read(revision), bytes)
        XCTAssertEqual(try store.read(drifted), bytes)
        XCTAssertEqual(files.listCount, listings)
    }

    func testReadMissingRevisionReportsNotFoundWithoutListingFiles() throws {
        let revision = HistoryRevision(identity: identity, filename: "19700101T000001.234Z-000000.md",
                                       timestamp: date)
        XCTAssertThrowsError(try store.read(revision)) {
            XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
        }
        XCTAssertEqual(files.listCount, 0)
    }

    func testRemoveValidRevisionPreservesOtherFilesWithoutListing() throws {
        let revision = try store.snapshot(Data("Revision".utf8), for: identity, at: date)
        try files.put("Settings", at: "settings.json")
        let listings = files.listCount
        try store.remove(revision)
        XCTAssertEqual(files.listCount, listings)
        XCTAssertNil(try files.stamp(at: "history/" + (try identity.storageKey) + "/" + revision.filename))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["settings.json"])
        XCTAssertEqual(try files.text(at: "settings.json"), "Settings")
    }

    func testRemovingRevisionTwiceReportsRevisionNotFoundWithoutListing() throws {
        let revision = try store.snapshot(Data("Revision".utf8), for: identity, at: date)
        let listings = files.listCount
        try store.remove(revision)
        XCTAssertThrowsError(try store.remove(revision)) {
            XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
        }
        XCTAssertEqual(files.listCount, listings)
    }

    func testReadExternallyDeletedRevisionReportsRevisionNotFoundWithoutListing() throws {
        let revision = try store.snapshot(Data("Revision".utf8), for: identity, at: date)
        let listings = files.listCount
        try files.delete(at: "history/" + (try identity.storageKey) + "/" + revision.filename)
        XCTAssertThrowsError(try store.read(revision)) {
            XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
        }
        XCTAssertEqual(files.listCount, listings)
    }

    func testReadRevisionDeletedAfterStampReportsRevisionNotFoundWithoutListing() throws {
        let revision = try store.snapshot(Data("Revision".utf8), for: identity, at: date)
        let listings = files.listCount
        // Simulate an external deletion between the stamp probe and byte read.
        files.onRead = { [unowned self] in try self.files.delete(at: $0) }
        XCTAssertThrowsError(try store.read(revision)) {
            XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
        }
        XCTAssertEqual(files.listCount, listings)
    }

    func testReadAndRemovePreserveOtherFileStoreErrors() throws {
        let revision = try store.snapshot(Data("Revision".utf8), for: identity, at: date)
        files.onRead = { _ in throw FileStoreError.ioFailure }
        XCTAssertThrowsError(try store.read(revision)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        files.failNextDelete = true
        XCTAssertThrowsError(try store.remove(revision)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
    }
}
