import Foundation
import XCTest
@testable import MonkeysPawCore

final class ValuesStoreTests: XCTestCase {
    private var files: MemoryFileStore!
    private var store: ValuesStore!
    private let identity = PromptIdentity(path: "a.md", id: nil)
    private let destination = PromptIdentity(path: "b.md", id: nil)

    override func setUp() {
        files = MemoryFileStore()
        store = ValuesStore(files: files)
    }

    func testFormatPrivateFlagRoundtripAndMerge() throws {
        XCTAssertEqual(try store.rememberedValues(for: identity), [:])
        try store.record(identity: identity, values: ["z": "last", "a": "first"])
        XCTAssertEqual(try files.text(at: "values.json"),
                       "{\"values\":{\"\(try identity.storageKey)\":{\"a\":\"first\",\"z\":\"last\"}},\"version\":1}")
        XCTAssertTrue(files.isPrivate(at: "values.json"))
        try store.record(identity: destination, values: ["other": "entry"])
        try store.record(identity: identity, values: ["a": "changed", "empty": ""])
        let reopened = ValuesStore(files: files)
        XCTAssertEqual(try reopened.rememberedValues(for: identity), ["a": "changed", "z": "last", "empty": ""])
        XCTAssertEqual(try reopened.rememberedValues(for: destination), ["other": "entry"])
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["values.json"])
    }

    func testArbitraryFieldNamesAndTextRoundtrip() throws {
        let values = ["a\"b\n☃": "\"quoted\"\n\\\u{0}{{raw}}", "": "", "👋": "你好"]
        try store.record(identity: identity, values: values)
        XCTAssertEqual(try store.rememberedValues(for: identity), values)
    }

    func testEmptyWriteDoesNotAccessOrCreateStateEvenWhenCorrupt() throws {
        try store.record(identity: identity, values: [:])
        XCTAssertEqual(files.accessCount, 0)
        try files.put("corrupt", at: "values.json")
        let accesses = files.accessCount
        try store.record(identity: identity, values: [:])
        XCTAssertEqual(files.accessCount, accesses)
        XCTAssertEqual(try files.text(at: "values.json"), "corrupt")
    }

    func testRemoveWholeMapPreservesOtherIdentitiesAndFields() throws {
        let other = PromptIdentity(path: "c.md", id: nil)
        let retained = ["current": "kept", "stale": "old text", "empty": "", "a\"b\n☃": "{{raw}}"]
        try store.record(identity: identity, values: ["current": "forgotten", "stale": "removed", "empty": ""])
        try store.record(identity: destination, values: retained)
        try store.record(identity: other, values: ["field": "another prompt"])

        try store.remove(identity: identity)

        let reopened = ValuesStore(files: files)
        XCTAssertEqual(try reopened.rememberedValues(for: identity), [:])
        XCTAssertEqual(try reopened.rememberedValues(for: destination), retained)
        XCTAssertEqual(try reopened.rememberedValues(for: other), ["field": "another prompt"])
        XCTAssertTrue(files.isPrivate(at: "values.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "values.json")) as? [String: Any])
        let maps = try XCTUnwrap(object["values"] as? [String: [String: String]])
        XCTAssertNil(maps[try identity.storageKey])
        XCTAssertEqual(maps.count, 2)
    }

    func testRemoveAbsentIdentityDoesNotWriteOrCreateState() throws {
        files.failNextWrite = true
        try store.remove(identity: identity)
        XCTAssertEqual(files.accessCount, 1)
        XCTAssertTrue(files.failNextWrite)
        XCTAssertNil(try files.stamp(at: "values.json"))

        files.failNextWrite = false
        try files.put("{ \"version\": 1, \"values\": {\"\(try destination.storageKey)\": {\"field\": \"kept\"}} }",
                      at: "values.json")
        let before = try files.read(at: "values.json")
        let stamp = try files.stamp(at: "values.json")
        let accesses = files.accessCount
        files.failNextWrite = true

        try store.remove(identity: identity)

        XCTAssertEqual(files.accessCount, accesses + 1)
        XCTAssertTrue(files.failNextWrite)
        XCTAssertEqual(try files.read(at: "values.json"), before)
        XCTAssertEqual(try files.stamp(at: "values.json"), stamp)
    }

    func testRemoveLastIdentityIncludingEmptyMapKeepsPrivateEmptyVersionedFile() throws {
        let key = try identity.storageKey
        for fields in ["{}", "{\"stale\":\"forgotten\"}"] {
            try files.put("{\"values\":{\"\(key)\":\(fields)},\"version\":1}", at: "values.json")
            try store.remove(identity: identity)
            XCTAssertEqual(try files.text(at: "values.json"), "{\"values\":{},\"version\":1}")
            XCTAssertTrue(files.isPrivate(at: "values.json"))
            XCTAssertEqual(try store.rememberedValues(for: identity), [:])
        }
    }

    func testRemoveAllClearsEveryIdentityAndAllowsNewRecords() throws {
        try store.record(identity: identity, values: ["field": "first", "stale": "old"])
        try store.record(identity: destination, values: ["field": "second"])

        try store.removeAll()

        XCTAssertEqual(try files.text(at: "values.json"), "{\"values\":{},\"version\":1}")
        XCTAssertTrue(files.isPrivate(at: "values.json"))
        let reopened = ValuesStore(files: files)
        XCTAssertEqual(try reopened.rememberedValues(for: identity), [:])
        XCTAssertEqual(try reopened.rememberedValues(for: destination), [:])
        try reopened.record(identity: identity, values: ["field": "new"])
        XCTAssertEqual(try reopened.rememberedValues(for: identity), ["field": "new"])
        XCTAssertEqual(try reopened.rememberedValues(for: destination), [:])
    }

    func testRemoveAllRecoversMissingUnreadableAndRejectedStateWithoutReading() throws {
        let states: [Data?] = [nil,
                              Data("{\"values\":{\"key\":{\"field\":\"previous\"}},\"version\":1}".utf8),
                              Data("private corrupt text".utf8),
                              Data("{\"values\":{},\"version\":2}".utf8),
                              Data("{\"values\":{\"key\":{\"field\":7}},\"version\":1}".utf8),
                              Data("{\"values\":{},\"version\":true}".utf8),
                              Data(repeating: 0x20, count: Limits.valuesFileCapBytes + 1)]
        for state in states {
            let resetFiles = MemoryFileStore()
            if let state { try resetFiles.write(state, at: "values.json") }
            let reset = ValuesStore(files: resetFiles)
            let accesses = resetFiles.accessCount
            resetFiles.onRead = { _ in
                XCTFail("Clear all must bypass the rejected or unreadable state.")
                throw FileStoreError.ioFailure
            }

            try reset.removeAll()

            XCTAssertEqual(resetFiles.accessCount, accesses + 1)
            XCTAssertTrue(resetFiles.isPrivate(at: "values.json"))
            resetFiles.onRead = nil
            XCTAssertEqual(try resetFiles.text(at: "values.json"), "{\"values\":{},\"version\":1}")
            XCTAssertEqual(try reset.rememberedValues(for: identity), [:])
        }
    }

    func testMigrationUnchangedMovedWholeMapConflictAndReversal() throws {
        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .unchanged)
        XCTAssertNil(try files.stamp(at: "values.json"))
        try store.record(identity: identity, values: ["one": "1", "two": "2"])
        let original = try files.read(at: "values.json")
        XCTAssertEqual(try store.migrateKey(from: identity, to: identity), .unchanged)
        XCTAssertEqual(try files.read(at: "values.json"), original)
        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .migrated)
        XCTAssertEqual(try store.rememberedValues(for: identity), [:])
        XCTAssertEqual(try store.rememberedValues(for: destination), ["one": "1", "two": "2"])
        XCTAssertTrue(files.isPrivate(at: "values.json"))
        XCTAssertEqual(try store.migrateKey(from: destination, to: identity), .migrated)
        XCTAssertEqual(try files.read(at: "values.json"), original)
        try store.record(identity: destination, values: ["occupied": "yes"])
        let before = try files.read(at: "values.json")
        XCTAssertThrowsError(try store.migrateKey(from: identity, to: destination)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try files.read(at: "values.json"), before)
    }

    func testCorruptUnsupportedAndOverCapStateFailClosedForEveryReadModifyOperation() throws {
        let invalid = [Data("private corrupt text".utf8),
                       Data("{\"values\":{},\"version\":2}".utf8),
                       Data("{\"values\":{\"key\":{\"field\":7}},\"version\":1}".utf8),
                       Data("{\"values\":{},\"version\":true}".utf8),
                       Data(repeating: 0x20, count: Limits.valuesFileCapBytes + 1)]
        for bytes in invalid {
            try files.write(bytes, at: "values.json")
            let operations: [() throws -> Void] = [
                { _ = try self.store.rememberedValues(for: self.identity) },
                { try self.store.record(identity: self.identity, values: ["new": "value"]) },
                { try self.store.remove(identity: self.identity) },
                { _ = try self.store.migrateKey(from: self.identity, to: self.destination) }
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) {
                    XCTAssertEqual($0 as? LibraryError, .operationFailed)
                    XCTAssertEqual(String(describing: $0), "operationFailed")
                }
                XCTAssertEqual(try files.read(at: "values.json"), bytes)
            }
        }
    }

    func testRemoveAndRemoveAllWriteFailuresPreserveExactStateAndTypedErrors() throws {
        try store.record(identity: identity, values: ["field": "forgotten only after success"])
        try store.record(identity: destination, values: ["field": "kept"])
        let before = try files.read(at: "values.json")
        let stamp = try files.stamp(at: "values.json")
        let operations: [() throws -> Void] = [
            { try self.store.remove(identity: self.identity) },
            { try self.store.removeAll() }
        ]
        for operation in operations {
            files.failNextWrite = true
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            }
            XCTAssertEqual(try files.read(at: "values.json"), before)
            XCTAssertEqual(try files.stamp(at: "values.json"), stamp)
        }
    }

    func testFailedRemoveAllPreservesRejectedBytesAndMissingState() throws {
        let states: [Data?] = [nil, Data("private corrupt text".utf8),
                              Data("{\"values\":{},\"version\":2}".utf8),
                              Data(repeating: 0x20, count: Limits.valuesFileCapBytes + 1)]
        for state in states {
            let resetFiles = MemoryFileStore()
            if let state { try resetFiles.write(state, at: "values.json") }
            let stamp = try resetFiles.stamp(at: "values.json")
            resetFiles.failNextWrite = true

            XCTAssertThrowsError(try ValuesStore(files: resetFiles).removeAll()) {
                XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            }

            XCTAssertEqual(try resetFiles.stamp(at: "values.json"), stamp)
            if let state { XCTAssertEqual(try resetFiles.read(at: "values.json"), state) }
            else { XCTAssertTrue(try resetFiles.listFiles().isEmpty) }
        }
    }

    func testRemoveReadAndInvalidIdentityFailuresNeverWrite() throws {
        try store.record(identity: identity, values: ["field": "kept"])
        let before = try files.read(at: "values.json")
        for error in [FileStoreError.ioFailure, .outsideRoot, .notRegularFile] {
            files.onRead = { _ in throw error }
            files.failNextWrite = true
            XCTAssertThrowsError(try store.remove(identity: identity)) {
                XCTAssertEqual($0 as? FileStoreError, error)
            }
            XCTAssertTrue(files.failNextWrite)
            files.onRead = nil
            XCTAssertEqual(try files.read(at: "values.json"), before)
        }

        let accesses = files.accessCount
        XCTAssertThrowsError(try store.remove(identity: .local("private/path"))) {
            XCTAssertEqual($0 as? LibraryError, .invalidIdentity)
            XCTAssertEqual(String(describing: $0), "invalidIdentity")
        }
        XCTAssertEqual(files.accessCount, accesses)
        files.onRead = { _ in throw NSError(domain: "private value/path", code: 1) }
        XCTAssertThrowsError(try store.remove(identity: identity)) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
            XCTAssertEqual(String(describing: $0), "operationFailed")
        }
        XCTAssertTrue(files.failNextWrite)
        files.onRead = nil
        XCTAssertEqual(try files.read(at: "values.json"), before)
    }

    func testMigrationAfterForgetPreservesUnchangedWholeMapAndConflictBehavior() throws {
        let retained = ["field": "kept", "stale": "also kept", "empty": ""]
        try store.record(identity: identity, values: ["field": "forgotten"])
        try store.record(identity: destination, values: retained)
        try store.remove(identity: identity)
        let afterForget = try files.read(at: "values.json")

        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .unchanged)
        XCTAssertEqual(try files.read(at: "values.json"), afterForget)
        XCTAssertEqual(try store.migrateKey(from: destination, to: identity), .migrated)
        XCTAssertEqual(try store.rememberedValues(for: destination), [:])
        XCTAssertEqual(try store.rememberedValues(for: identity), retained)
        try store.record(identity: destination, values: ["occupied": "yes"])
        let beforeConflict = try files.read(at: "values.json")
        XCTAssertThrowsError(try store.migrateKey(from: identity, to: destination)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try files.read(at: "values.json"), beforeConflict)

        try store.removeAll()
        let afterReset = try files.read(at: "values.json")
        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .unchanged)
        XCTAssertEqual(try store.migrateKey(from: destination, to: identity), .unchanged)
        XCTAssertEqual(try files.read(at: "values.json"), afterReset)
    }

    func testLibraryMoveAfterForgetRollsBackRemainingStateWithoutResurrectingForgottenMaps() throws {
        let library = MemoryFileStore()
        let service = LibraryService(library: library, data: files, clock: LibraryClock(),
                                     entropy: LibraryEntropy(), keyedStores: [store])
        try library.put("{{field}}", at: "a.md")
        try store.record(identity: identity, values: ["field": "kept", "stale": "old"])
        try store.record(identity: destination, values: ["field": "forgotten"])
        try store.remove(identity: destination)
        let beforeFailure = try files.read(at: "values.json")
        library.failMoveNumber = 1

        XCTAssertThrowsError(try service.move(from: "a.md", to: "b.md")) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try files.read(at: "values.json"), beforeFailure)
        XCTAssertEqual(try library.text(at: "a.md"), "{{field}}")
        XCTAssertNil(try library.stamp(at: "b.md"))
        XCTAssertEqual(try store.rememberedValues(for: destination), [:])

        try store.remove(identity: identity)
        let afterForget = try files.read(at: "values.json")
        library.failMoveNumber = 2
        XCTAssertThrowsError(try service.move(from: "a.md", to: "b.md")) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try files.read(at: "values.json"), afterForget)
        let moved = try service.move(from: "a.md", to: "b.md")
        XCTAssertEqual(try store.rememberedValues(for: moved.identity), [:])
        XCTAssertEqual(try files.read(at: "values.json"), afterForget)
    }

    func testEncodedCapIncludesJSONOverheadAndFailedWriteRetainsExactState() throws {
        try store.record(identity: identity, values: ["field": "old"])
        let before = try files.read(at: "values.json")
        let overhead = before.count - "old".utf8.count
        let maximum = String(repeating: "x", count: Limits.valuesFileCapBytes - overhead)
        try store.record(identity: identity, values: ["field": maximum])
        let atCap = try files.read(at: "values.json")
        XCTAssertEqual(atCap.count, Limits.valuesFileCapBytes)
        XCTAssertEqual(try store.rememberedValues(for: identity), ["field": maximum])
        XCTAssertThrowsError(try store.record(identity: identity, values: ["field": maximum + "x"])) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
        XCTAssertEqual(try files.read(at: "values.json"), atCap)
        files.failNextWrite = true
        XCTAssertThrowsError(try store.record(identity: identity, values: ["field": "new"])) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try files.read(at: "values.json"), atCap)
    }

    func testFailedMigrationRetainsBothMapsAndInvalidIdentityFailsSanitized() throws {
        try store.record(identity: identity, values: ["field": "kept"])
        let original = try files.read(at: "values.json")
        files.failNextWrite = true
        XCTAssertThrowsError(try store.migrateKey(from: identity, to: destination)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try files.read(at: "values.json"), original)
        for operation in [{ try self.store.rememberedValues(for: .local("private/path")) },
                          { try self.store.record(identity: .local("private/path"), values: ["f": "v"]); return [:] }] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? LibraryError, .invalidIdentity)
                XCTAssertEqual(String(describing: $0), "invalidIdentity")
            }
        }
        files.onRead = { _ in throw NSError(domain: "private value/path", code: 1) }
        XCTAssertThrowsError(try store.rememberedValues(for: identity)) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
            XCTAssertEqual(String(describing: $0), "operationFailed")
        }
    }

    func testLibraryAssignmentMoveAndRollbackUseRememberedKeyMigration() throws {
        let library = MemoryFileStore()
        let service = LibraryService(library: library, data: files, clock: LibraryClock(),
                                     entropy: LibraryEntropy(), keyedStores: [store])
        try library.put("{{field}}", at: "a.md")
        try store.record(identity: identity, values: ["field": "saved"])
        let moved = try service.move(from: "a.md", to: "b.md")
        XCTAssertEqual(try store.rememberedValues(for: identity), [:])
        XCTAssertEqual(try store.rememberedValues(for: moved.identity), ["field": "saved"])
        let before = try files.read(at: "values.json")
        library.failNextWrite = true
        XCTAssertThrowsError(try service.assignIdentity(to: "b.md"))
        XCTAssertEqual(try files.read(at: "values.json"), before)
        let assigned = try service.assignIdentity(to: "b.md")
        XCTAssertEqual(try store.rememberedValues(for: assigned.identity), ["field": "saved"])
        XCTAssertEqual(try store.rememberedValues(for: moved.identity), [:])
        XCTAssertTrue(files.isPrivate(at: "values.json"))
    }

    func testConcurrentReadMergeWritesDoNotLoseOtherFields() throws {
        // FileStore is used only behind ValuesStore's lock in this exercise.
        // Final reads occur after concurrentPerform's barrier.
        DispatchQueue.concurrentPerform(iterations: 40) { number in
            do { try store.record(identity: identity, values: ["field\(number)": "\(number)"]) }
            catch { XCTFail("Concurrent values write failed.") }
        }
        XCTAssertEqual(try store.rememberedValues(for: identity).count, 40)
    }
}
