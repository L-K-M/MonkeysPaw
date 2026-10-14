import XCTest
@testable import MonkeysPawCore

final class SyncKeyedMigrationTests: XCTestCase {
    func testUnreadableJournalGateRequiresExplicitRecovery() throws {
        for restoreJournal in [false, true] {
            let gate = SyncLibraryWriteGate()
            let id = UUID()
            let state = try SyncTestValues.state()
            gate.blockForRecovery()
            XCTAssertThrowsError(try gate.begin(id, nextState: state)) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
            gate.finish(id)
            XCTAssertTrue(gate.hasUnreadableJournal)
            XCTAssertNil(gate.pendingPermit)
            XCTAssertThrowsError(try gate.requireEditable()) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
            if restoreJournal {
                gate.resume(id, nextState: state)
                XCTAssertEqual(gate.pendingPermit?.id, id)
                XCTAssertThrowsError(try gate.requireEditable()) {
                    XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
                }
                gate.finish(id)
            } else { gate.finishEmptyRecovery() }
            XCTAssertFalse(gate.hasUnreadableJournal)
            XCTAssertNoThrow(try gate.requireEditable())
        }
    }

    func testUnreadableJournalCannotBeFinishedByAnExistingPermit() throws {
        let gate = SyncLibraryWriteGate()
        let id = UUID()
        let state = try SyncTestValues.state()
        try gate.begin(id, nextState: state)
        gate.blockForRecovery()
        gate.finish(id)
        gate.finishEmptyRecovery()
        XCTAssertTrue(gate.hasUnreadableJournal)
        XCTAssertEqual(gate.pendingPermit?.id, id)
        XCTAssertEqual(gate.pendingPermit?.nextState, state)
        for candidate in [id, UUID()] {
            XCTAssertThrowsError(try gate.begin(candidate, nextState: state)) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
        }
        XCTAssertThrowsError(try gate.replace(id, with: UUID(), nextState: state)) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertThrowsError(try gate.requireEditable()) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        gate.resume(id, nextState: state)
        gate.finish(id)
        XCTAssertFalse(gate.hasUnreadableJournal)
        XCTAssertNoThrow(try gate.requireEditable())
    }

    func testHistoryMigrationRejectsInvalidIdentityRoutesBeforeAnyIO() throws {
        let source = "history/" + SyncTestValues.personalPrompt.rawValue + "/head.json"
        let destination = "history/" + SyncTestValues.groupPrompt.rawValue + "/head.json"
        let invalid = ["history/x", "history//head.json", "history/not-an-identity/head.json",
                       "history/" + SyncTestValues.device.rawValue + "/other.json"]
        for path in invalid {
            for corruptSource in [false, true] {
                let files = MemoryFileStore()
                let store = HistoryStore(files: files)
                let operations = MemorySyncFileOperations(files: files)
                let migration = SyncKeyedMigration(store: .history, change: .file(SyncKeyedFileMove(
                    source: corruptSource ? path : source, destination: corruptSource ? destination : path,
                    bytes: Data("retained history".utf8))))
                XCTAssertThrowsError(try store.isSyncMigrationUnstarted(migration), path) {
                    XCTAssertEqual($0 as? SyncError, .invalidState)
                }
                XCTAssertThrowsError(try store.applySyncMigration(migration, operations: operations), path) {
                    XCTAssertEqual($0 as? SyncError, .invalidState)
                }
                XCTAssertEqual(files.accessCount, 0, path)
                XCTAssertEqual(operations.operationCount, 0, path)
            }
        }
    }

    func testHistoryMigrationPreservesNestedUnknownFilesAndReplays() throws {
        let files = MemoryFileStore()
        let store = HistoryStore(files: files)
        let source = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        let destination = PromptIdentity.assigned(SyncTestValues.groupPrompt)
        let from = "history/" + (try source.storageKey) + "/sub/unknown.bin"
        let to = "history/" + (try destination.storageKey) + "/sub/unknown.bin"
        let bytes = Data("opaque preserved bytes".utf8)
        try files.writePrivate(bytes, at: from)
        let migrations = try store.prepareSyncMigration(from: source, to: destination,
                                                        rebindingHeadTo: nil, originalBytes: nil)
        let migration = try XCTUnwrap(migrations.first)
        XCTAssertEqual(migrations.count, 1)
        XCTAssertNoThrow(try migration.validate())
        let operations = MemorySyncFileOperations(files: files)
        XCTAssertTrue(try store.isSyncMigrationUnstarted(migration))
        try store.applySyncMigration(migration, operations: operations)
        let writes = files.writeCount
        let deletes = files.deleteCount
        let flushes = operations.flushCount
        try store.applySyncMigration(migration, operations: operations)
        XCTAssertEqual(files.writeCount, writes)
        XCTAssertEqual(files.deleteCount, deletes)
        XCTAssertGreaterThan(operations.flushCount, flushes)
        XCTAssertNil(try files.stamp(at: from))
        XCTAssertEqual(try files.read(at: to), bytes)
    }

    func testUsageMigrationRejectsAChangedDestinationAndKeepsCache() throws {
        let files = MemoryFileStore()
        let store = UsageStore(files: files, clock: LibraryClock())
        let source = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        let destination = PromptIdentity.assigned(SyncTestValues.groupPrompt)
        try store.recordUse(identity: source, at: Date(timeIntervalSince1970: 12))
        let migration = try XCTUnwrap(store.prepareSyncMigration(from: source, to: destination,
            rebindingHeadTo: nil, originalBytes: nil).first)
        let destinationPath = "usage/" + (try destination.storageKey)
        let occupied = Data("{\"events\":[99],\"version\":1}".utf8)
        try files.writePrivate(occupied, at: destinationPath)
        let writes = files.writeCount
        let operations = MemorySyncFileOperations(files: files)
        XCTAssertThrowsError(try store.applySyncMigration(migration, operations: operations)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(files.writeCount, writes)
        XCTAssertEqual(operations.operationCount, 0)
        XCTAssertEqual(try files.read(at: destinationPath), occupied)
        XCTAssertEqual(store.cachedUseEvents()[source], [Date(timeIntervalSince1970: 12)])
        XCTAssertNil(store.cachedUseEvents()[destination])
        try files.delete(at: destinationPath)
        let sourceBytes = try files.read(at: "usage/" + (try source.storageKey))
        try store.applySyncMigration(migration, operations: operations)
        let appliedWrites = files.writeCount
        let deletes = files.deleteCount
        let flushes = operations.flushCount
        try store.applySyncMigration(migration, operations: operations)
        XCTAssertEqual(files.writeCount, appliedWrites)
        XCTAssertEqual(files.deleteCount, deletes)
        XCTAssertGreaterThan(operations.flushCount, flushes)
        XCTAssertNil(try files.stamp(at: "usage/" + (try source.storageKey)))
        XCTAssertEqual(store.cachedUseEvents()[destination], [Date(timeIntervalSince1970: 12)])
        XCTAssertNil(store.cachedUseEvents()[source])
        XCTAssertEqual(try files.read(at: destinationPath), sourceBytes)
    }

    func testDecodedKeyedMovesRejectCorruptionBeforeAnyIO() throws {
        let original = SyncKeyedFileMove(source: "history/old/head.json", destination: "history/new/head.json",
                                        bytes: Data("retained".utf8))
        let corruptions = [
            ("hash", String(repeating: "0", count: 64)),
            ("destinationHash", String(repeating: "0", count: 64)),
            ("source", "../escape.md"),
            ("destination", "../escape.md"),
            ("destination", original.source)
        ]
        for (field, value) in corruptions {
            var object = try SyncTestValues.object(original)
            object[field] = value
            let move = try JSONDecoder().decode(SyncKeyedFileMove.self,
                from: JSONSerialization.data(withJSONObject: object))
            for apply in [false, true] {
                let files = MemoryFileStore()
                try files.writePrivate(original.bytes, at: original.source)
                let operations = MemorySyncFileOperations(files: files)
                let accesses = files.accessCount
                if apply {
                    XCTAssertThrowsError(try move.apply(files: files, operations: operations), field) {
                        XCTAssertEqual($0 as? SyncError, .invalidState)
                    }
                } else {
                    XCTAssertThrowsError(try move.isUnstarted(files: files), field) {
                        XCTAssertEqual($0 as? SyncError, .invalidState)
                    }
                }
                XCTAssertEqual(files.accessCount, accesses, field)
                XCTAssertEqual(operations.operationCount, 0, field)
                XCTAssertEqual(try files.read(at: original.source), original.bytes)
            }
        }
    }

    func testKeyedStoresRejectForeignMigrationsBeforeAnyIO() throws {
        let source = SyncTestValues.personalPrompt.rawValue
        let destination = SyncTestValues.groupPrompt.rawValue
        let payload = Data("{\"events\":[12],\"version\":1}".utf8)
        for kind in [SyncKeyedStoreKind.history, .usage, .values] {
            let files = MemoryFileStore()
            try files.writePrivate(payload, at: "history/" + source + "/head.json")
            try files.writePrivate(payload, at: "usage/" + source)
            let values = ValuesStore(files: files)
            try values.record(identity: .assigned(SyncTestValues.personalPrompt), values: ["field": "keep"])
            let store: SyncKeyedStore
            let migrations: [SyncKeyedMigration]
            switch kind {
            case .history:
                store = HistoryStore(files: files)
                migrations = [SyncKeyedMigration(store: .usage, change: .file(SyncKeyedFileMove(
                    source: "history/" + source + "/head.json", destination: "history/" + destination + "/head.json",
                    bytes: payload)))]
            case .usage:
                store = UsageStore(files: files, clock: LibraryClock())
                migrations = [
                    SyncKeyedMigration(store: .history, change: .file(SyncKeyedFileMove(
                        source: "history/" + source + "/head.json", destination: "history/" + destination + "/head.json",
                        bytes: payload))),
                    SyncKeyedMigration(store: .usage, change: .file(SyncKeyedFileMove(
                        source: "history/" + source + "/head.json", destination: "history/" + destination + "/head.json",
                        bytes: payload))),
                    SyncKeyedMigration(store: .usage, change: .file(SyncKeyedFileMove(
                        source: "usage/" + source, destination: "usage/not-an-identity", bytes: payload)))
                ]
            case .values:
                store = values
                migrations = [
                    SyncKeyedMigration(store: .usage, change: .values(source: source, destination: destination,
                                                                    fields: ["field": "keep"])),
                    SyncKeyedMigration(store: .values, change: .file(SyncKeyedFileMove(
                        source: "history/" + source + "/head.json", destination: "history/" + destination + "/head.json",
                        bytes: payload)))
                ]
            }
            let operations = MemorySyncFileOperations(files: files)
            for migration in migrations {
                let accesses = files.accessCount
                XCTAssertThrowsError(try store.isSyncMigrationUnstarted(migration)) {
                    XCTAssertEqual($0 as? SyncError, .invalidState)
                }
                XCTAssertEqual(files.accessCount, accesses)
                XCTAssertThrowsError(try store.applySyncMigration(migration, operations: operations)) {
                    XCTAssertEqual($0 as? SyncError, .invalidState)
                }
                XCTAssertEqual(files.accessCount, accesses)
                XCTAssertEqual(operations.operationCount, 0)
            }
        }
    }

    func testUsageMigrationValidatesCapturedBytesInsteadOfASecondRead() throws {
        let files = MemoryFileStore()
        let store = UsageStore(files: files, clock: LibraryClock())
        let source = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        let path = "usage/" + (try source.storageKey)
        let corrupt = Data("not JSON".utf8)
        try files.writePrivate(corrupt, at: path)
        var reads = 0
        files.onRead = { current in
            guard current == path else { return }
            reads += 1
            if reads == 2 { try files.put("{\"events\":[12],\"version\":1}", at: path) }
        }
        XCTAssertThrowsError(try store.prepareSyncMigration(from: source, to: .assigned(SyncTestValues.groupPrompt),
                                                           rebindingHeadTo: nil, originalBytes: nil)) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
        files.onRead = nil
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try files.read(at: path), corrupt)
    }

    func testUsageMigrationRejectsInvalidEventBytesBeforeMovingOrChangingCache() throws {
        let files = MemoryFileStore()
        let store = UsageStore(files: files, clock: LibraryClock())
        let source = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        let destination = PromptIdentity.assigned(SyncTestValues.groupPrompt)
        try store.recordUse(identity: source, at: Date(timeIntervalSince1970: 12))
        let sourcePath = "usage/" + (try source.storageKey)
        let destinationPath = "usage/" + (try destination.storageKey)
        let bytes = try files.read(at: sourcePath)
        let migration = SyncKeyedMigration(store: .usage, change: .file(SyncKeyedFileMove(
            source: sourcePath, destination: destinationPath, bytes: bytes, destinationBytes: Data("broken".utf8))))
        let operations = MemorySyncFileOperations(files: files)
        let accesses = files.accessCount
        XCTAssertThrowsError(try store.applySyncMigration(migration, operations: operations)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        XCTAssertEqual(files.accessCount, accesses)
        XCTAssertEqual(operations.operationCount, 0)
        XCTAssertEqual(store.cachedUseEvents()[source], [Date(timeIntervalSince1970: 12)])
        XCTAssertNil(store.cachedUseEvents()[destination])
        XCTAssertEqual(try files.read(at: sourcePath), bytes)
        XCTAssertNil(try files.stamp(at: destinationPath))
    }

    func testUsageSameKeySyncMigrationIsANoop() throws {
        let files = MemoryFileStore()
        let store = UsageStore(files: files, clock: LibraryClock())
        let identity = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        try store.recordUse(identity: identity)
        let accesses = files.accessCount
        XCTAssertTrue(try store.prepareSyncMigration(from: identity, to: identity,
                                                    rebindingHeadTo: nil, originalBytes: nil).isEmpty)
        XCTAssertEqual(files.accessCount, accesses)
    }

    func testEmptyHistorySourceKeepsOccupiedDestinationUntouched() throws {
        let files = MemoryFileStore()
        let store = HistoryStore(files: files)
        let path = "history/" + SyncTestValues.groupPrompt.rawValue + "/head.json"
        try files.put("existing history", at: path)
        let writes = files.writeCount
        XCTAssertTrue(try store.prepareSyncMigration(from: .assigned(SyncTestValues.personalPrompt),
            to: .assigned(SyncTestValues.groupPrompt), rebindingHeadTo: nil, originalBytes: nil).isEmpty)
        XCTAssertEqual(files.writeCount, writes)
        XCTAssertEqual(try files.text(at: path), "existing history")
    }

    func testOversizedHistoryFileFailsDuringPreparation() throws {
        let files = MemoryFileStore()
        let store = HistoryStore(files: files)
        let path = "history/" + SyncTestValues.personalPrompt.rawValue + "/revision.md"
        let bytes = Data(repeating: 65, count: Limits.syncRecordMaxBytes + 1)
        try files.writePrivate(bytes, at: path)
        let writes = files.writeCount
        XCTAssertThrowsError(try store.prepareSyncMigration(from: .assigned(SyncTestValues.personalPrompt),
            to: .assigned(SyncTestValues.groupPrompt), rebindingHeadTo: nil, originalBytes: nil)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        XCTAssertEqual(files.writeCount, writes)
        XCTAssertEqual(try files.read(at: path), bytes)
    }
}
