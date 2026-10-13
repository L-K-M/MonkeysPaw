import XCTest
@testable import MonkeysPawCore

final class SyncApplyJournalTests: XCTestCase {
    func testJournalIsPrivateDurableAndPrecedesAllLibraryMutations() throws {
        let rig = try SyncApplyTestRig()
        let edit = try rig.replacement()
        var sawPublication = false
        rig.libraryOperations.beforePublish = { _ in
            let record = try JSONDecoder().decode(SyncApplyRecord.self, from: rig.data.read(at: "sync/apply.json"))
            XCTAssertTrue(rig.data.isPrivate(at: "sync/apply.json"))
            XCTAssertTrue(record.steps[0].started)
            XCTAssertEqual(record.steps[0].edit.id, edit.id)
            XCTAssertEqual(record.steps[0].edit.bytes, edit.bytes)
            XCTAssertTrue(rig.dataOperations.flushedFiles.contains("sync/apply.json"))
            XCTAssertTrue(rig.dataOperations.flushedDirectories.contains(nil))
            XCTAssertNil(rig.states.snapshot.value)
            sawPublication = true
        }
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertTrue(sawPublication)
    }

    func testFilesAndDirectoriesPrecedeDurableStateAndJournalRemoval() throws {
        let rig = try SyncApplyTestRig()
        let edit = try rig.replacement(at: "nested/a.md")
        var events: [String] = []
        rig.libraryOperations.onOperation = { events.append("library:" + $0) }
        rig.dataOperations.onOperation = { events.append("data:" + $0) }
        rig.data.onWrite = { path in events.append("write:" + path) }
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        let file = try XCTUnwrap(events.firstIndex(of: "library:file:nested/a.md"))
        let parent = try XCTUnwrap(events.firstIndex(of: "library:directory:nested"))
        let root = try XCTUnwrap(events.firstIndex(of: "library:directory:/"))
        let stateWrite = try XCTUnwrap(events.firstIndex(of: "write:sync/state.json"))
        let stateFlush = try XCTUnwrap(events.firstIndex(of: "data:file:sync/state.json"))
        XCTAssertLessThan(file, parent)
        XCTAssertLessThan(parent, root)
        XCTAssertLessThan(root, stateWrite)
        XCTAssertLessThan(stateWrite, stateFlush)
        XCTAssertEqual(Array(events.suffix(2)), ["data:directory:sync", "data:directory:/"])
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
    }

    func testFailureAtEveryCapabilityOperationReplaysTwiceWithoutDuplicateCopies() throws {
        let baseline = try preparedRescue()
        XCTAssertEqual(try baseline.rig.journal.apply(baseline.plan), .committed)
        let dataCount = baseline.rig.dataOperations.operationCount
        let libraryCount = baseline.rig.libraryOperations.operationCount
        XCTAssertGreaterThan(dataCount, 20)
        XCTAssertGreaterThan(libraryCount, 3)
        for isData in [false, true] {
            for number in 1...(isData ? dataCount : libraryCount) {
                let fixture = try preparedRescue()
                let rig = fixture.rig
                if isData { rig.dataOperations.failOperationNumber = number }
                else { rig.libraryOperations.failOperationNumber = number }
                XCTAssertThrowsError(try rig.journal.apply(fixture.plan), "operation \(number), data \(isData)")
                let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
                XCTAssertEqual(try restarted.journal.replay(), .committed, "operation \(number), data \(isData)")
                XCTAssertEqual(try restarted.journal.replay(), .committed)
                XCTAssertEqual(try restarted.files.read(at: "a.md"), fixture.plan.edits[1].bytes)
                XCTAssertEqual(try restarted.files.read(at: "Conflicts/Copy.md"), fixture.plan.edits[0].bytes)
                XCTAssertEqual(try restarted.files.listFiles().count, 2)
                XCTAssertEqual(restarted.states.snapshot.value, fixture.plan.nextState)
                XCTAssertNil(try restarted.data.stamp(at: "sync/apply.json"))
            }
        }
    }

    func testFailureAtEveryPrivateWriteAndJournalDeleteIsRecoverable() throws {
        let baseline = try preparedRescue()
        XCTAssertEqual(try baseline.rig.journal.apply(baseline.plan), .committed)
        let writeCount = baseline.rig.data.writeCount
        for number in 1...writeCount {
            let fixture = try preparedRescue()
            fixture.rig.data.failWriteNumber = number
            XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
            let restarted = try SyncApplyTestRig(files: fixture.rig.files, data: fixture.rig.data)
            if restarted.journal.pending == nil {
                XCTAssertNil(restarted.states.snapshot.value)
                XCTAssertEqual(try restarted.files.read(at: "a.md"), SyncApplyTestRig.bytes("Losing local"))
                XCTAssertEqual(try restarted.journal.apply(fixture.plan), .committed)
            } else {
                XCTAssertEqual(try restarted.journal.replay(), .committed)
            }
            XCTAssertEqual(try restarted.journal.replay(), .committed)
            XCTAssertEqual(restarted.states.snapshot.value, fixture.plan.nextState)
        }
        let fixture = try preparedRescue()
        fixture.rig.data.failNextDelete = true
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
        XCTAssertNotNil(try fixture.rig.data.stamp(at: "sync/apply.json"))
        let restarted = try SyncApplyTestRig(files: fixture.rig.files, data: fixture.rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
    }

    func testPostRenameFlushFailureReportsAppliedAndNeverAcknowledges() throws {
        let rig = try SyncApplyTestRig()
        let old = SyncApplyTestRig.bytes("Old")
        try rig.files.write(old, at: "a.md")
        let edit = try rig.replacement()
        rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit]))) {
            let error = $0 as? SyncFileOperationError
            XCTAssertEqual(error?.effect, .applied)
            XCTAssertEqual(error?.displacedBytes, old)
        }
        XCTAssertEqual(try rig.files.read(at: "a.md"), edit.bytes)
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNotNil(rig.journal.pending)
        XCTAssertThrowsError(try rig.library.load(at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        rig.libraryOperations.failFlushNumber = nil
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(rig.libraryOperations.modes["a.md"], .normal)
    }

    func testTrashFlushFailureResumesWithoutRemovingAReplacement() throws {
        for replaced in [false, true] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
            let edit = try rig.mutations.trash(XCTUnwrap(rig.mutations.read(at: "a.md")))
            rig.libraryOperations.failFlushNumber = 1
            XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit])))
            XCTAssertNil(try rig.files.stamp(at: "a.md"))
            let replacement = SyncApplyTestRig.bytes("Unrelated", id: SyncTestValues.groupPrompt)
            if replaced { try rig.files.write(replacement, at: "a.md") }
            let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
            let expected: SyncApplyOutcome = replaced ? .replanAsConflict(operationID: edit.id) : .committed
            XCTAssertEqual(try restarted.journal.replay(), expected)
            XCTAssertEqual(try restarted.journal.replay(), expected)
            if replaced { XCTAssertEqual(try rig.files.read(at: "a.md"), replacement) }
        }
    }

    func testReadOnlyPublicationReplayReestablishesMode() throws {
        let rig = try SyncApplyTestRig()
        let edit = try rig.mutations.publication(SyncApplyTestRig.bytes("Viewer"), at: "Groups/Team/a.md", expecting: nil,
            transition: SyncIdentityTransition(from: nil, to: .assigned(SyncTestValues.personalPrompt)), mode: .readOnly)
        // Only the byte operation matters here; group policy/state is Y5/Y9.
        let plan = SyncApplyPlan(expectedState: nil, nextState: try SyncState(binding: rig.binding), edits: [edit])
        rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan))
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(restarted.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
    }

    func testUncertainStateFlushNeverAcknowledgesAndReplayReflushesIt() throws {
        let rig = try SyncApplyTestRig()
        let edit = try rig.replacement()
        let plan = try rig.plan([edit])
        rig.dataOperations.onOperation = { operation in
            if operation == "file:sync/state.json" {
                rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
            }
        }
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertEqual(rig.states.snapshot.error, .durabilityUncertain)
        XCTAssertNotNil(rig.journal.pending)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertTrue(restarted.dataOperations.flushedFiles.contains("sync/state.json"))
        XCTAssertEqual(restarted.states.snapshot.value, plan.nextState)
    }

    func testJournalRemovalFlushFailureBlocksAcknowledgementCache() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        var stateWritten = false
        var stateDurable = false
        rig.dataOperations.onOperation = { operation in
            if operation == "file:sync/state.json" { stateWritten = true }
            if stateWritten, operation == "directory:/" { stateDurable = true }
            if stateDurable, operation == "directory:sync" {
                rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
            }
        }
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertEqual(rig.states.snapshot.error, .durabilityUncertain)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(restarted.states.snapshot.value, plan.nextState)
    }

    func testInterruptedIdentityMigrationResumesEveryFileAndValuesStep() throws {
        let baseline = try preparedAdoption()
        XCTAssertEqual(try baseline.rig.journal.apply(baseline.plan), .committed)
        for number in 1...baseline.rig.dataOperations.operationCount {
            let fixture = try preparedAdoption()
            // Setup already flushed state? No: only the journal uses this fake.
            fixture.rig.dataOperations.failOperationNumber = number
            XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan), "operation \(number)")
            let restarted = try SyncApplyTestRig(files: fixture.rig.files, data: fixture.rig.data)
            XCTAssertEqual(try restarted.journal.replay(), .committed, "operation \(number)")
            XCTAssertEqual(try restarted.journal.replay(), .committed)
            let new = PromptIdentity.assigned(SyncTestValues.personalPrompt)
            let old = PromptIdentity(path: "a.md", id: nil)
            XCTAssertEqual(try restarted.library.history(for: new).count, 2)
            XCTAssertTrue(try restarted.library.history(for: old).isEmpty)
            XCTAssertEqual(try restarted.usage.useEvents(for: new).count, 1)
            XCTAssertTrue(try restarted.usage.useEvents(for: old).isEmpty)
            XCTAssertEqual(try restarted.values.rememberedValues(for: new), ["field": "remembered"])
            XCTAssertEqual(try restarted.values.rememberedValues(for: old), [:])
        }
    }

    func testCooperatingKeyedWritesCannotChangeAnApplyBaseline() throws {
        let fixture = try preparedAdoption()
        let old = PromptIdentity(path: "a.md", id: nil)
        fixture.rig.libraryOperations.beforePublish = { _ in
            let mutations: [() throws -> Void] = [
                { try fixture.rig.values.record(identity: old, values: ["field": "new delivery"]) },
                { try fixture.rig.values.remove(identity: old) },
                { try fixture.rig.values.removeAll() },
                { _ = try fixture.rig.values.migrateKey(from: old, to: .assigned(SyncTestValues.device)) },
                { _ = try fixture.rig.usage.recordUse(identity: old) },
                { _ = try fixture.rig.usage.migrateKey(from: old, to: .assigned(SyncTestValues.device)) }
            ]
            for mutation in mutations {
                XCTAssertThrowsError(try mutation()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
            }
        }
        XCTAssertEqual(try fixture.rig.journal.apply(fixture.plan), .committed)
        let new = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        XCTAssertEqual(try fixture.rig.values.rememberedValues(for: new), ["field": "remembered"])
        XCTAssertEqual(try fixture.rig.usage.useEvents(for: new).count, 1)
        XCTAssertNoThrow(try fixture.rig.values.record(identity: new, values: ["field": "later delivery"]))
        XCTAssertNoThrow(try fixture.rig.usage.recordUse(identity: new))
    }

    func testJournalAndKeyedStoreIOCanAcquireLibraryLock() throws {
        let fixture = try preparedAdoption()
        let rig = fixture.rig
        var probed = Set<String>()
        rig.dataOperations.onOperation = { operation in
            guard operation.hasPrefix("file:"), probed.insert(operation).inserted else { return }
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { completed.signal() }
                do { _ = try rig.library.load(at: "a.md"); XCTFail("Recovery gate must block editing") }
                catch { XCTAssertEqual(error as? LibraryError, .recoveryRequired) }
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 1), .success, operation)
        }
        XCTAssertEqual(try rig.journal.apply(fixture.plan), .committed)
        XCTAssertTrue(probed.contains("file:sync/apply.json"))
        XCTAssertTrue(probed.contains("file:values.json"))
        XCTAssertTrue(probed.contains("file:sync/state.json"))
        XCTAssertTrue(probed.contains { $0.hasPrefix("file:history/") })
        XCTAssertNoThrow(try rig.library.load(at: "a.md"))
    }

    func testCorruptFutureAndTamperedJournalFailClosedBeforeLibraryIO() throws {
        let fixture = try preparedRescue()
        fixture.rig.libraryOperations.failOperationNumber = 1
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
        let record = try fixture.rig.data.read(at: "sync/apply.json")
        for variant in 0...2 {
            let data = MemoryFileStore()
            if variant == 0 { try data.put("broken", at: "sync/apply.json") }
            else {
                var object = try JSONSerialization.jsonObject(with: record) as! [String: Any]
                if variant == 1 { object["version"] = 99 }
                else {
                    var steps = object["steps"] as! [[String: Any]]
                    var edit = steps[0]["edit"] as! [String: Any]
                    edit["hash"] = String(repeating: "0", count: 64)
                    steps[0]["edit"] = edit
                    object["steps"] = steps
                }
                try SyncTestValues.write(object, to: data, path: "sync/apply.json")
            }
            let files = MemoryFileStore()
            let library = LibraryService(library: files, data: data, clock: LibraryClock(), entropy: LibraryEntropy())
            let dataOps = MemorySyncFileOperations(files: data)
            XCTAssertThrowsError(try SyncApplyJournal(files: data, operations: dataOps,
                mutations: SyncLibraryMutations(library: library, operations: MemorySyncFileOperations(files: files)),
                states: SyncStateStore(files: data, operations: dataOps)))
            XCTAssertEqual(files.accessCount, 0)
            XCTAssertThrowsError(try library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        }
    }

    func testWrongAccountStateCannotApplyOrAcknowledge() throws {
        let rig = try SyncApplyTestRig()
        try rig.states.reset(for: SyncTestValues.binding(userID: SyncTestValues.otherUser))
        let edit = try rig.replacement()
        let plan = SyncApplyPlan(expectedState: nil, nextState: try SyncState(binding: rig.binding), edits: [edit])
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
        XCTAssertTrue(try rig.files.listFiles().isEmpty)
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
    }

    func testJournalAndRetainedByteDiagnosticsAreRedacted() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.put("SENTINEL-PRIVATE-CONTENT", at: "a.md")
        let edit = try rig.replacement()
        let plan = try rig.plan([edit])
        let record = try SyncApplyRecord(plan: plan, steps: [SyncApplyStep(edit: edit, migrations: [])])
        for description in [String(describing: record), String(reflecting: record), String(reflecting: edit),
                            String(reflecting: edit.expected!)] {
            XCTAssertFalse(description.contains("SENTINEL"))
        }
    }

    func testConflictReplanArchivesOldIntentAndRetainsBothLocalVersions() throws {
        let rig = try SyncApplyTestRig()
        let old = SyncApplyTestRig.bytes("Old local")
        try rig.files.write(old, at: "a.md")
        let originalPlan = try rig.plan([rig.replacement()])
        let changed = SyncApplyTestRig.bytes("New local")
        try rig.files.write(changed, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(originalPlan), .replanAsConflict(operationID: originalPlan.edits[0].id))
        let file = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let copy = try rig.mutations.rescue(file, at: "Conflicts/New.md", freshID: SyncTestValues.groupPrompt)
        let replanned = try rig.plan([copy, rig.replacement()])
        XCTAssertEqual(try rig.journal.replan(replanned), .committed)
        XCTAssertEqual(try rig.journal.replay(), .committed)
        let archived = try JSONDecoder().decode(SyncApplyRecord.self,
            from: rig.data.read(at: "sync/retained/" + originalPlan.id.uuidString.lowercased() + "-journal.json"))
        XCTAssertEqual(archived.steps[0].edit.expected?.bytes, old)
        XCTAssertEqual(try rig.data.read(at: "sync/retained/" + copy.id.uuidString.lowercased() + ".bin"), changed)
        XCTAssertEqual(try rig.files.read(at: "Conflicts/New.md"), copy.bytes)
        XCTAssertEqual(try rig.files.read(at: "a.md"), replanned.edits[1].bytes)
    }

    func testReplanCannotDiscardInterruptedIdentityMigration() throws {
        let fixture = try preparedAdoption()
        fixture.rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
        let previousID = fixture.rig.journal.pending?.id
        let replacement = try fixture.rig.plan([])
        XCTAssertThrowsError(try fixture.rig.journal.replan(replacement)) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertEqual(fixture.rig.journal.pending?.id, previousID)
        let restarted = try SyncApplyTestRig(files: fixture.rig.files, data: fixture.rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
    }

    func testChangedFileBeforeAdoptionPublicationCanReplanUntouchedMigrations() throws {
        let fixture = try preparedAdoption()
        try fixture.rig.files.put("New local edit", at: "a.md")
        XCTAssertEqual(try fixture.rig.journal.apply(fixture.plan), .replanAsConflict(operationID: fixture.plan.edits[0].id))
        let next = try fixture.rig.plan([fixture.rig.replacement(body: "New local edit")])
        XCTAssertEqual(try fixture.rig.journal.replan(next), .committed)
        XCTAssertEqual(try fixture.rig.values.rememberedValues(for: .assigned(SyncTestValues.personalPrompt)),
                       ["field": "remembered"])
    }

    func testRacingStateUpdateReturnsTypedConflict() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        var changed = false
        rig.dataOperations.onOperation = { operation in
            guard !changed, operation == "file:sync/apply.json", rig.libraryOperations.modes["a.md"] != nil else { return }
            changed = true
            try! rig.states.update(for: rig.binding) { $0.cursors[.user(SyncTestValues.user)] = "another writer" }
        }
        XCTAssertEqual(try rig.journal.apply(plan), .replanAsConflict(operationID: plan.id))
        XCTAssertEqual(rig.states.snapshot.value?.cursors[.user(SyncTestValues.user)], "another writer")
        XCTAssertNotNil(rig.journal.pending)
    }

    func testFileOccupyingHistoryDestinationRejectsBeforeIdentityRewrite() throws {
        let fixture = try preparedAdoption()
        try fixture.rig.data.put("Occupied", at: "history/" + SyncTestValues.personalPrompt.rawValue)
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
        XCTAssertEqual(try fixture.rig.files.text(at: "a.md"), "Local\r\n")
        XCTAssertNil(try fixture.rig.data.stamp(at: "sync/apply.json"))
        XCTAssertNoThrow(try fixture.rig.library.load(at: "a.md"))
    }

    func testAdditionalDisplacedRetentionFailurePreservesAppliedEffectAndBytes() throws {
        for flushFails in [false, true] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
            let edit = try rig.replacement()
            let displaced = SyncApplyTestRig.bytes("Noncooperating writer")
            rig.libraryOperations.racingBytesAfterCheck = displaced
            if flushFails { rig.libraryOperations.failFlushNumber = 1 }
            rig.libraryOperations.beforePublish = { _ in rig.data.failNextWrite = true }
            XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit]))) {
                XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .applied)
                XCTAssertEqual(($0 as? SyncFileOperationError)?.displacedBytes, displaced)
            }
            XCTAssertEqual(try rig.files.read(at: "a.md"), edit.bytes)
            XCTAssertNil(rig.states.snapshot.value)
            XCTAssertNotNil(rig.journal.pending)
        }
    }

    func testExternalKeyedChangeReportsRecoveryInsteadOfImpossibleConflictReplan() throws {
        let fixture = try preparedAdoption()
        let old = PromptIdentity(path: "a.md", id: nil)
        fixture.rig.libraryOperations.beforePublish = { _ in
            // Bypass ValuesStore deliberately: an external app-data edit is
            // outside the cooperating keyed-write gate and must fail closed.
            try SyncTestValues.write(["version": 1, "values": [try old.storageKey: ["field": "external"]]],
                                     to: fixture.rig.data, path: "values.json")
        }
        XCTAssertEqual(try fixture.rig.journal.apply(fixture.plan), .recoveryRequired(operationID: fixture.plan.id))
        XCTAssertEqual(try fixture.rig.journal.replay(), .recoveryRequired(operationID: fixture.plan.id))
        XCTAssertEqual(try fixture.rig.values.rememberedValues(for: old), ["field": "external"])
        XCTAssertNotNil(fixture.rig.journal.pending)
    }

    func testSharedKeyedStoresKeepEveryLiveLibraryGate() throws {
        let fixture = try preparedAdoption()
        fixture.rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan))
        let other = LibraryService(library: MemoryFileStore(), data: fixture.rig.data, clock: LibraryClock(),
            entropy: LibraryEntropy(), keyedStores: [fixture.rig.usage, fixture.rig.values])
        XCTAssertThrowsError(try fixture.rig.values.record(identity: .assigned(SyncTestValues.device), values: ["field": "value"])) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertThrowsError(try fixture.rig.usage.recordUse(identity: .assigned(SyncTestValues.device))) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        fixture.rig.libraryOperations.failFlushNumber = nil
        XCTAssertEqual(try fixture.rig.journal.replay(), .committed)
        XCTAssertNoThrow(try fixture.rig.values.record(identity: .assigned(SyncTestValues.device), values: ["field": "value"]))
        XCTAssertNoThrow(try other.entries())
    }

    private func preparedRescue() throws -> (rig: SyncApplyTestRig, plan: SyncApplyPlan) {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Losing local"), at: "a.md")
        let file = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let rescue = try rig.mutations.rescue(file, at: "Conflicts/Copy.md", freshID: SyncTestValues.groupPrompt)
        return (rig, try rig.plan([rescue, rig.replacement()]))
    }

    private func preparedAdoption() throws -> (rig: SyncApplyTestRig, plan: SyncApplyPlan) {
        let rig = try SyncApplyTestRig()
        try rig.files.put("Local\r\n", at: "a.md")
        let old = PromptIdentity(path: "a.md", id: nil)
        let history = HistoryStore(files: rig.data)
        _ = try history.snapshot(Data("Revision 1".utf8), for: old, at: Date(timeIntervalSince1970: 1))
        _ = try history.snapshot(Data("Revision 2".utf8), for: old, at: Date(timeIntervalSince1970: 2))
        try rig.values.record(identity: old, values: ["field": "remembered"])
        try rig.usage.recordUse(identity: old)
        return (rig, try rig.plan([rig.replacement(body: "Local\r\n")]))
    }
}
