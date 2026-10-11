import Foundation
import XCTest
@testable import MonkeysPawCore

final class UsageStoreTests: XCTestCase {
    private var files: MemoryFileStore!
    private var clock: LibraryClock!
    private var store: UsageStore!
    private let identity = PromptIdentity(path: "a.md", id: nil)
    private let destination = PromptIdentity(path: "b.md", id: nil)

    override func setUp() {
        files = MemoryFileStore()
        clock = LibraryClock()
        clock.date = Date(timeIntervalSince1970: 1.25)
        store = UsageStore(files: files, clock: clock)
    }

    func testRoundtripUsesClockAndOneDeterministicFilePerIdentity() throws {
        XCTAssertEqual(try store.useEvents(for: identity), [])
        try store.recordUse(identity: identity)
        let explicit = Date(timeIntervalSince1970: 2.5)
        XCTAssertEqual(try store.recordUse(identity: identity, at: explicit), [clock.date, explicit])
        let reopened = UsageStore(files: files, clock: LibraryClock())
        XCTAssertEqual(try reopened.useEvents(for: identity), [clock.date, explicit])
        XCTAssertEqual(try files.listFiles().map(\.relativePath), [try path(identity)])
        XCTAssertEqual(try files.text(at: path(identity)), "{\"events\":[1.25,2.5],\"version\":1}")
        XCTAssertEqual(files.listCount, 1, "Usage operations must not enumerate app data.")
        try store.recordUse(identity: destination, at: explicit)
        XCTAssertEqual(try store.useEvents(for: identity), [clock.date, explicit])
        XCTAssertEqual(try store.useEvents(for: destination), [explicit])
    }

    func testCapKeepsLastRecordedEventsIncludingRepeatedAndEarlierDates() throws {
        let existing = (0..<Limits.usageEventCap).map(Double.init)
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "events": existing])
        try files.write(bytes, at: path(identity))
        let repeated = Date(timeIntervalSince1970: 0)
        try store.recordUse(identity: identity, at: repeated)
        let newest = Date(timeIntervalSince1970: Double(Limits.usageEventCap))
        let retained = try store.recordUse(identity: identity, at: newest)
        let expected = existing.dropFirst(2).map(Date.init(timeIntervalSince1970:)) + [repeated, newest]
        XCTAssertEqual(retained.count, Limits.usageEventCap)
        XCTAssertEqual(retained, expected)
        XCTAssertEqual(try store.useEvents(for: identity), expected)
    }

    func testInvalidTimestampsAndIdentitiesFailBeforeFileAccess() throws {
        for seconds in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try store.recordUse(identity: identity, at: Date(timeIntervalSince1970: seconds))) {
                XCTAssertEqual($0 as? LibraryError, .invalidTimestamp)
            }
        }
        clock.date = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try store.recordUse(identity: identity)) {
            XCTAssertEqual($0 as? LibraryError, .invalidTimestamp)
        }
        clock.date = Date(timeIntervalSince1970: 0)
        let invalid = PromptIdentity.local("../secret")
        XCTAssertThrowsError(try store.recordUse(identity: invalid)) { XCTAssertEqual($0 as? LibraryError, .invalidIdentity) }
        XCTAssertThrowsError(try store.useEvents(for: invalid)) { XCTAssertEqual($0 as? LibraryError, .invalidIdentity) }
        XCTAssertThrowsError(try store.migrateKey(from: invalid, to: identity)) {
            XCTAssertEqual($0 as? LibraryError, .invalidIdentity)
        }
        XCTAssertEqual(files.accessCount, 0)
    }

    func testCorruptUnsupportedAndOverCapFilesFailWithoutReplacingState() throws {
        let oversized = try JSONSerialization.data(withJSONObject:
            ["version": 1, "events": (0...Limits.usageEventCap).map(Double.init)])
        let invalid = [Data("sensitive invalid bytes".utf8),
                       Data("{\"version\":2,\"events\":[1]}".utf8),
                       Data("{\"version\":1,\"events\":[\"NaN\"]}".utf8),
                       Data("{\"version\":1,\"events\":[1e999]}".utf8), oversized]
        for bytes in invalid {
            try files.write(bytes, at: path(identity))
            for operation in [{ try self.store.useEvents(for: self.identity) },
                              { try self.store.recordUse(identity: self.identity) }] {
                XCTAssertThrowsError(try operation()) {
                    XCTAssertEqual($0 as? LibraryError, .operationFailed)
                    XCTAssertEqual(String(describing: $0), "operationFailed")
                }
            }
            XCTAssertEqual(try files.read(at: path(identity)), bytes)
        }
    }

    func testMigrationMovesExactFileIsReversibleAndHandlesMissingOrSameKey() throws {
        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .unchanged)
        try store.recordUse(identity: identity)
        let original = try files.read(at: path(identity))
        XCTAssertEqual(try store.migrateKey(from: identity, to: identity), .unchanged)
        XCTAssertEqual(try store.migrateKey(from: identity, to: destination), .migrated)
        XCTAssertEqual(try files.read(at: path(destination)), original)
        XCTAssertEqual(try store.useEvents(for: identity), [])
        XCTAssertEqual(try store.useEvents(for: destination), [clock.date])
        XCTAssertEqual(try store.migrateKey(from: destination, to: identity), .migrated)
        XCTAssertEqual(try files.read(at: path(identity)), original)
    }

    func testOccupiedDestinationIsNeverMergedIncludingMalformedState() throws {
        try store.recordUse(identity: identity)
        try files.put("opaque existing state", at: path(destination))
        let original = try files.read(at: path(identity))
        XCTAssertThrowsError(try store.migrateKey(from: identity, to: destination)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try files.read(at: path(identity)), original)
        XCTAssertEqual(try files.text(at: path(destination)), "opaque existing state")
        XCTAssertEqual(files.moveCount, 0)
    }

    func testTypedFailuresArePreservedAndUnknownErrorsAreSanitized() throws {
        let fault = UsageFaultStore(files)
        let tested = UsageStore(files: fault, clock: clock)
        try tested.recordUse(identity: identity)
        for operation in UsageFaultStore.Operation.allCases {
            fault.operation = operation
            for error in [FileStoreError.ioFailure as Error,
                          NSError(domain: "secret /home/private/path", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "private tool output"])] {
                fault.error = error
                XCTAssertThrowsError(try {
                    switch operation {
                    case .read: _ = try tested.useEvents(for: identity)
                    case .write: _ = try tested.recordUse(identity: identity)
                    case .stamp, .move: _ = try tested.migrateKey(from: identity, to: destination)
                    }
                }()) {
                    if error is FileStoreError { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
                    else {
                        XCTAssertEqual($0 as? LibraryError, .operationFailed)
                        XCTAssertEqual(String(describing: $0), "operationFailed")
                    }
                }
            }
        }
        fault.operation = nil
        XCTAssertEqual(try tested.useEvents(for: identity), [clock.date])
        XCTAssertEqual(try tested.useEvents(for: destination), [])
    }

    func testLibraryAssignmentAndBothKindsOfMoveUseExistingMigrationMachinery() throws {
        let library = MemoryFileStore()
        let service = LibraryService(library: library, data: files, clock: clock,
                                     entropy: LibraryEntropy(), keyedStores: [store])
        try library.put("Body", at: "a.md")
        try store.recordUse(identity: identity)
        let moved = try service.move(from: "a.md", to: "b.md")
        XCTAssertEqual(moved.identity, destination)
        XCTAssertEqual(try store.useEvents(for: identity), [])
        XCTAssertEqual(try store.useEvents(for: destination), [clock.date])
        let assigned = try service.assignIdentity(to: "b.md")
        XCTAssertEqual(try store.useEvents(for: destination), [])
        XCTAssertEqual(try store.useEvents(for: assigned.identity), [clock.date])
        let moves = files.moveCount
        let renamed = try service.move(from: "b.md", to: "c.md")
        XCTAssertEqual(renamed.identity, assigned.identity)
        XCTAssertEqual(try store.useEvents(for: renamed.identity), [clock.date])
        XCTAssertEqual(files.moveCount, moves)
    }

    func testLibraryWriteAndMoveFailuresReverseCompletedUsageMigration() throws {
        let library = MemoryFileStore()
        let service = LibraryService(library: library, data: files, clock: clock,
                                     entropy: LibraryEntropy(), keyedStores: [store])
        try library.put("Body", at: "a.md")
        try store.recordUse(identity: identity)
        library.failNextWrite = true
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md")) { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
        XCTAssertEqual(try store.useEvents(for: identity), [clock.date])
        XCTAssertEqual(try files.listFiles().map(\.relativePath), [try path(identity)])
        XCTAssertEqual(try library.text(at: "a.md"), "Body")
        library.failMoveNumber = 1
        XCTAssertThrowsError(try service.move(from: "a.md", to: "b.md")) { XCTAssertEqual($0 as? FileStoreError, .ioFailure) }
        XCTAssertEqual(try store.useEvents(for: identity), [clock.date])
        XCTAssertEqual(try store.useEvents(for: destination), [])
        XCTAssertEqual(try library.text(at: "a.md"), "Body")
    }

    func testOccupiedUsageDuringAssignmentReversesHistoryAndPreservesBothUsageFiles() throws {
        let library = MemoryFileStore()
        let entropy = LibraryEntropy()
        let service = LibraryService(library: library, data: files, clock: clock,
                                     entropy: entropy, keyedStores: [store])
        try library.put("Body", at: "a.md")
        let assigned = PromptIdentity.assigned(try ULID.generate(at: clock.date, entropy: entropy.value))
        let history = HistoryStore(files: files)
        let revision = try history.snapshot(Data("Older".utf8), for: identity, at: clock.date)
        try store.recordUse(identity: identity)
        let earlier = clock.date.addingTimeInterval(-1)
        try store.recordUse(identity: assigned, at: earlier)
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try library.text(at: "a.md"), "Body")
        XCTAssertEqual(try store.useEvents(for: identity), [clock.date])
        XCTAssertEqual(try store.useEvents(for: assigned), [earlier])
        XCTAssertEqual(try history.revisions(for: identity), [revision])
        XCTAssertEqual(try history.revisions(for: assigned), [])
    }

    func testDestinationAppearingAtMoveReportsKeyedConflict() throws {
        try store.recordUse(identity: identity)
        let fault = UsageFaultStore(files)
        fault.operation = .move
        fault.error = FileStoreError.alreadyExists
        let tested = UsageStore(files: fault, clock: clock)
        XCTAssertThrowsError(try tested.migrateKey(from: identity, to: destination)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try store.useEvents(for: identity), [clock.date])
    }

    private func path(_ identity: PromptIdentity) throws -> String { "usage/" + (try identity.storageKey) }
}

private final class UsageFaultStore: FileStore {
    enum Operation: CaseIterable { case read, write, stamp, move }
    var operation: Operation?
    var error: Error = FileStoreError.ioFailure
    private let backing: MemoryFileStore

    init(_ backing: MemoryFileStore) { self.backing = backing }

    func listFiles() throws -> [StoredFile] { try backing.listFiles() }
    func stamp(at path: String) throws -> FileStamp? {
        if operation == .stamp { throw error }
        return try backing.stamp(at: path)
    }
    func read(at path: String) throws -> Data {
        if operation == .read { throw error }
        return try backing.read(at: path)
    }
    func write(_ data: Data, at path: String) throws {
        if operation == .write { throw error }
        try backing.write(data, at: path)
    }
    func delete(at path: String) throws { try backing.delete(at: path) }
    func writePrivate(_ data: Data, at path: String) throws {
        if operation == .write { throw error }
        try backing.writePrivate(data, at: path)
    }
    func move(from source: String, to destination: String) throws {
        if operation == .move { throw error }
        try backing.move(from: source, to: destination)
    }
}
