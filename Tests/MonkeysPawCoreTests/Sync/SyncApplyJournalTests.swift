import XCTest
@testable import MonkeysPawCore

final class SyncApplyJournalTests: XCTestCase {
    func testRecordRejectsRenameWithoutPreparedDirectorySteps() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.put("{{name}}", at: "Groups/Old/f.md")
        let file = try XCTUnwrap(rig.mutations.read(at: "Groups/Old/f.md"))
        try rig.values.record(identity: file.identity, values: ["name": "keep"])
        let rename = try SyncDirectoryEdit(renaming: "Groups/Old",
            identity: XCTUnwrap(rig.libraryOperations.directoryIdentity(at: "Groups/Old")),
            to: "Groups/New", localFiles: [file])
        let plan = SyncApplyPlan(expectedState: nil, nextState: try SyncState(binding: rig.binding),
            edits: [], directories: [rename])
        XCTAssertThrowsError(try SyncApplyRecord(plan: plan, steps: [])) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        let migrations = try rig.mutations.prepareMigrations(for: rename)
        XCTAssertFalse(migrations.isEmpty)
        let record = try SyncApplyRecord(plan: plan, steps: [],
            directorySteps: [SyncDirectoryStep(edit: rename, migrations: migrations)])
        XCTAssertEqual(record.directorySteps.first?.migrations.count, migrations.count)
    }

    func testPreparationKeyedConflictKeepsTypedErrorAndReleasesPermit() throws {
        let fixture = try preparedAdoption()
        let rig = fixture.rig
        try rig.values.record(identity: .assigned(SyncTestValues.personalPrompt), values: ["field": "occupied"])
        let writes = rig.files.writeCount
        XCTAssertThrowsError(try rig.journal.apply(fixture.plan)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(rig.files.writeCount, writes)
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
        XCTAssertNoThrow(try rig.library.load(at: "a.md"))
        XCTAssertNoThrow(try rig.values.remove(identity: .assigned(SyncTestValues.personalPrompt)))
        XCTAssertEqual(try rig.journal.apply(fixture.plan), .committed)
    }

    func testJournalCreationWriteFailureReleasesPermitWithoutRecovery() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.data.failNextWrite = true
        XCTAssertThrowsError(try rig.journal.apply(plan)) {
            XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure))
        }
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
        XCTAssertNil(rig.journal.pending)
        XCTAssertNil(rig.mutations.pendingPermit)
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        XCTAssertNoThrow(try rig.library.entries())
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), plan.edits[0].bytes)
    }

    func testReplanPreparationConflictKeepsTypedErrorAndOriginalJournal() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        try rig.values.record(identity: .assigned(SyncTestValues.personalPrompt), values: ["field": "remembered"])
        try rig.values.record(identity: .assigned(SyncTestValues.groupPrompt), values: ["field": "occupied"])
        let first = try rig.plan([rig.replacement()])
        try rig.files.write(SyncApplyTestRig.bytes("Edited local"), at: "a.md")
        XCTAssertEqual(try rig.journal.apply(first), .replanAsConflict(operationID: first.edits[0].id))
        let original = try rig.data.read(at: "sync/apply.json")
        let current = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let edit = try rig.mutations.publication(SyncApplyTestRig.bytes("Server", id: SyncTestValues.groupPrompt),
            at: "a.md", expecting: current, transition: SyncIdentityTransition(from: current.identity,
                to: .assigned(SyncTestValues.groupPrompt)), kind: .adopt)
        let replacement = try rig.plan([edit])
        XCTAssertThrowsError(try rig.journal.replan(replacement)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try rig.data.read(at: "sync/apply.json"), original)
        XCTAssertEqual(rig.journal.pending?.id, first.id)
        XCTAssertNil(try rig.data.stamp(at: "sync/retained/" + first.id.uuidString.lowercased() + "-journal.json"))
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
    }

    func testFailedJournalInitializationCanRecoverOnTheSameLibrary() throws {
        for restoreJournal in [false, true] {
            let rig = try SyncApplyTestRig()
            let edit = try rig.replacement()
            let plan = try rig.plan([edit])
            let record = try SyncApplyRecord(plan: plan, steps: [SyncApplyStep(edit: edit, migrations: [])])
            try rig.data.put("corrupt", at: "sync/apply.json")
            XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                    mutations: rig.mutations, states: rig.states)) {
                XCTAssertEqual($0 as? SyncError, .corruptFile)
            }
            XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
            // Model explicit restoration/reset after retaining the damaged file.
            if restoreJournal { try rig.data.writePrivate(JSONEncoder().encode(record), at: "sync/apply.json") }
            else { try rig.data.delete(at: "sync/apply.json") }
            let repaired = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                               mutations: rig.mutations, states: rig.states)
            XCTAssertEqual(try repaired.replay(), .committed)
            XCTAssertNoThrow(try rig.library.entries())
            XCTAssertNoThrow(try rig.values.record(identity: .assigned(SyncTestValues.device), values: ["field": "value"]))
            if restoreJournal { XCTAssertEqual(try rig.files.read(at: "a.md"), edit.bytes) }
            else { XCTAssertNil(try rig.files.stamp(at: "a.md")) }
        }
    }

    func testCorruptJournalResetMustFlushBeforeReleasingRecoveryGate() throws {
        let rig = try SyncApplyTestRig()
        try rig.data.put("corrupt", at: "sync/apply.json")
        XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                mutations: rig.mutations, states: rig.states)) {
            XCTAssertEqual($0 as? SyncError, .corruptFile)
        }
        try rig.data.delete(at: "sync/apply.json")
        rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount + 1
        XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                mutations: rig.mutations, states: rig.states)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        rig.dataOperations.failOperationNumber = nil
        let repaired = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                           mutations: rig.mutations, states: rig.states)
        XCTAssertEqual(try repaired.replay(), .committed)
        XCTAssertEqual(rig.dataOperations.flushedDirectories, [RelativePath("sync"), nil])
        XCTAssertNoThrow(try rig.library.entries())
    }

    func testLiveJournalCannotBeginUntilEmptyRecoveryIsDurable() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        try rig.data.put("corrupt", at: "sync/apply.json")
        XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                mutations: rig.mutations, states: rig.states)) {
            XCTAssertEqual($0 as? SyncError, .corruptFile)
        }
        try rig.data.delete(at: "sync/apply.json")
        let writes = rig.data.writeCount
        XCTAssertThrowsError(try rig.journal.apply(plan)) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertEqual(rig.data.writeCount, writes)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount + 1
        XCTAssertThrowsError(try rig.journal.replay()) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        XCTAssertTrue(rig.mutations.hasUnreadableJournal)
        XCTAssertThrowsError(try rig.library.entries()) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        rig.dataOperations.failOperationNumber = nil
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(rig.dataOperations.flushedDirectories, [RelativePath("sync"), nil])
        XCTAssertFalse(rig.mutations.hasUnreadableJournal)
        XCTAssertNoThrow(try rig.library.entries())
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), plan.edits[0].bytes)
    }

    func testUncertainReplanRecoversReplacementWithTheSamePermitGraph() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let first = try rig.plan([rig.replacement()])
        try rig.files.write(SyncApplyTestRig.bytes("Changed"), at: "a.md")
        XCTAssertEqual(try rig.journal.apply(first), .replanAsConflict(operationID: first.edits[0].id))
        let replacement = try rig.plan([rig.replacement(body: "Replanned")])
        rig.dataOperations.onOperation = { operation in
            guard operation == "file:sync/apply.json" else { return }
            rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
        }
        XCTAssertThrowsError(try rig.journal.replan(replacement)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        rig.dataOperations.onOperation = nil
        rig.dataOperations.failOperationNumber = nil
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), replacement.edits[0].bytes)
        XCTAssertNoThrow(try rig.library.entries())
        XCTAssertNoThrow(try rig.values.removeAll())
    }

    func testAbandonedUncertainReplanCanRecoverWithTheSameLibrary() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let first = try rig.plan([rig.replacement()])
        try rig.files.write(SyncApplyTestRig.bytes("Changed"), at: "a.md")
        let replacement = try rig.plan([rig.replacement(body: "Replanned")])
        do {
            let abandoned = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                 mutations: rig.mutations, states: rig.states)
            XCTAssertEqual(try abandoned.apply(first), .replanAsConflict(operationID: first.edits[0].id))
            rig.dataOperations.onOperation = { operation in
                guard operation == "file:sync/apply.json" else { return }
                rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
            }
            XCTAssertThrowsError(try abandoned.replan(replacement)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        }
        rig.dataOperations.onOperation = nil
        rig.dataOperations.failOperationNumber = nil
        let recovered = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                            mutations: rig.mutations, states: rig.states)
        XCTAssertEqual(try recovered.replay(), .committed)
        XCTAssertEqual(try recovered.replay(), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), replacement.edits[0].bytes)
        XCTAssertNoThrow(try rig.library.entries())
        XCTAssertNoThrow(try rig.values.removeAll())
    }

    func testAbandonedJournalRemovalFailureRecoversOnTheSameLibrary() throws {
        for retryFails in [false, true] {
            let rig = try SyncApplyTestRig()
            let plan = try rig.plan([rig.replacement()])
            var stateWritten = false
            var stateDurable = false
            do {
                let abandoned = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                     mutations: rig.mutations, states: rig.states)
                rig.dataOperations.onOperation = { operation in
                    if operation == "file:sync/state.json" { stateWritten = true }
                    if stateWritten, operation == "directory:/" { stateDurable = true }
                    if stateDurable, operation == "directory:sync" {
                        rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
                    }
                }
                XCTAssertThrowsError(try abandoned.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
            }
            XCTAssertTrue(stateDurable)
            XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
            XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
            rig.dataOperations.onOperation = nil
            rig.dataOperations.failOperationNumber = nil
            if retryFails {
                rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount + 1
                XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                         mutations: rig.mutations, states: rig.states)) {
                    XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
                }
                XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
                rig.dataOperations.failOperationNumber = nil
            }
            let recovered = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                mutations: rig.mutations, states: rig.states)
            XCTAssertEqual(try recovered.replay(), .committed)
            XCTAssertEqual(rig.states.snapshot.value, plan.nextState)
            XCTAssertNil(rig.states.snapshot.error)
            XCTAssertNoThrow(try rig.library.entries())
            XCTAssertNoThrow(try rig.values.removeAll())
        }
    }

    func testMissingUncommittedJournalCannotReportCompletedRecovery() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.libraryOperations.failFlushNumber = 1
        do {
            let abandoned = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                 mutations: rig.mutations, states: rig.states)
            XCTAssertThrowsError(try abandoned.apply(plan)) {
                XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .durabilityFailed)
            }
        }
        let journal = try rig.data.read(at: "sync/apply.json")
        try rig.data.delete(at: "sync/apply.json")
        rig.libraryOperations.failFlushNumber = nil
        XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                 mutations: rig.mutations, states: rig.states)) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        XCTAssertNil(rig.states.snapshot.value)
        // Restoring the retained intent permits recovery without a new graph.
        try rig.data.writePrivate(journal, at: "sync/apply.json")
        let restored = try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                           mutations: rig.mutations, states: rig.states)
        XCTAssertEqual(try restored.replay(), .committed)
        XCTAssertNoThrow(try rig.library.entries())
    }

    func testFailedRecoveryFlushKeepsPermitUntilADurableRetry() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.dataOperations.failOperationNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount + 1
        XCTAssertThrowsError(try rig.journal.replay()) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        rig.dataOperations.failOperationNumber = nil
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertNoThrow(try rig.library.entries())
    }

    func testRecoveryValidatesJournalBeforeFlushOrLibraryIO() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.dataOperations.failOperationNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        rig.dataOperations.failOperationNumber = nil
        try rig.data.put("corrupt", at: "sync/apply.json")
        let accesses = rig.files.accessCount
        let operations = rig.dataOperations.operationCount
        XCTAssertThrowsError(try rig.journal.replay()) { XCTAssertEqual($0 as? SyncError, .corruptFile) }
        XCTAssertEqual(rig.files.accessCount, accesses)
        XCTAssertEqual(rig.dataOperations.operationCount, operations)
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
    }

    func testEveryApplyCapabilityFailureRecoversOnTheSameGraph() throws {
        let baseline = try preparedAdoption()
        XCTAssertEqual(try baseline.rig.journal.apply(baseline.plan), .committed)
        for isData in [false, true] {
            let count = isData ? baseline.rig.dataOperations.operationCount : baseline.rig.libraryOperations.operationCount
            for number in 1...count {
                let fixture = try preparedAdoption()
                let rig = fixture.rig
                let context = "operation \(number), data \(isData)"
                if isData { rig.dataOperations.failOperationNumber = number }
                else { rig.libraryOperations.failOperationNumber = number }
                XCTAssertThrowsError(try rig.journal.apply(fixture.plan), context) { error in
                    switch error {
                    case SyncError.durabilityUncertain, LibraryError.operationFailed:
                        XCTAssertTrue(isData, context)
                    case let error as SyncFileOperationError:
                        XCTAssertTrue([SyncFileFailureCode.ioFailure, .durabilityFailed].contains(error.code), context)
                    default: XCTFail("Unexpected capability failure: \(error), \(context)")
                    }
                }
                XCTAssertThrowsError(try rig.library.load(at: "a.md"), context) {
                    XCTAssertEqual($0 as? LibraryError, .recoveryRequired, context)
                }
                rig.dataOperations.failOperationNumber = nil
                rig.libraryOperations.failOperationNumber = nil
                XCTAssertEqual(try rig.journal.replay(), .committed, context)
                XCTAssertEqual(try rig.journal.replay(), .committed, context)
                XCTAssertEqual(try rig.files.read(at: "a.md"), fixture.plan.edits[0].bytes, context)
                XCTAssertEqual(rig.states.snapshot.value, fixture.plan.nextState, context)
                XCTAssertNil(rig.states.snapshot.error, context)
                XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"), context)
                XCTAssertNoThrow(try rig.library.load(at: "a.md"), context)
                XCTAssertNoThrow(try rig.values.record(identity: .assigned(SyncTestValues.personalPrompt),
                                                       values: ["field": "after recovery"]), context)
                XCTAssertNoThrow(try rig.usage.recordUse(identity: .assigned(SyncTestValues.personalPrompt)), context)
            }
        }
    }

    func testEmptyStateResetRequiresAPlanWithTheResetBaseline() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.libraryOperations.failOperationNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        rig.libraryOperations.failOperationNumber = nil
        try rig.states.reset(for: rig.binding)
        XCTAssertEqual(try rig.journal.replay(), .replanAsConflict(operationID: plan.id))
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        let replacement = try rig.plan([rig.replacement()])
        XCTAssertEqual(replacement.expectedState, try SyncState(binding: rig.binding))
        XCTAssertEqual(try rig.journal.replan(replacement), .committed)
    }

    func testReplanReplacementBeforePermitSwapRecoversWithFreshGraph() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let first = try rig.plan([rig.replacement()])
        try rig.files.write(SyncApplyTestRig.bytes("Changed"), at: "a.md")
        XCTAssertEqual(try rig.journal.apply(first), .replanAsConflict(operationID: first.edits[0].id))
        let replacement = try rig.plan([rig.replacement(body: "Replanned")])
        var interrupted = false
        rig.dataOperations.onOperation = { operation in
            guard operation == "directory:/" else { return }
            do {
                let record = try JSONDecoder().decode(SyncApplyRecord.self, from: rig.data.read(at: "sync/apply.json"))
                guard record.id == replacement.id else { return }
                interrupted = true
                // The replacement is on disk while the old graph still holds
                // its permit. A fresh process cannot retain that in-memory gate.
                rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
            } catch { XCTFail("Cannot inspect replacement journal: \(error)") }
        }
        XCTAssertThrowsError(try rig.journal.replan(replacement)) {
            XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
        }
        XCTAssertTrue(interrupted)
        XCTAssertThrowsError(try rig.library.load(at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(restarted.journal.pending?.id, replacement.id)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.files.read(at: "a.md"), replacement.edits[0].bytes)
        XCTAssertNoThrow(try restarted.library.load(at: "a.md"))
    }

    func testJournalLoadErrorSurvivesAnAlreadyHeldPermit() throws {
        for (json, expected) in [("broken", SyncError.corruptFile), ("{\"version\":99}", .futureVersion(99))] {
            let rig = try SyncApplyTestRig()
            try rig.data.put(json, at: "sync/apply.json")
            let owner = UUID()
            try rig.mutations.begin(owner, nextState: SyncState(binding: rig.binding))
            let accesses = rig.files.accessCount
            XCTAssertThrowsError(try SyncApplyJournal(files: rig.data, operations: rig.dataOperations,
                                                    mutations: rig.mutations, states: rig.states)) {
                XCTAssertEqual($0 as? SyncError, expected)
            }
            XCTAssertEqual(rig.files.accessCount, accesses)
            XCTAssertThrowsError(try rig.library.entries()) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
            rig.mutations.finish(owner)
            XCTAssertThrowsError(try rig.library.entries()) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
            XCTAssertEqual(rig.mutations.pendingPermit?.id, owner)
            let repairedPlan = SyncApplyPlan(id: owner, expectedState: nil,
                nextState: try SyncState(binding: rig.binding), edits: [])
            let repairedRecord = try SyncApplyRecord(plan: repairedPlan, steps: [])
            try rig.data.writePrivate(JSONEncoder().encode(repairedRecord), at: "sync/apply.json")
            XCTAssertEqual(try rig.journal.replay(), .committed)
            XCTAssertNoThrow(try rig.library.entries())
        }
    }

    func testDecodedValuesFileMigrationFailsBeforeLibraryIO() throws {
        let fixture = try preparedAdoption()
        let edit = fixture.plan.edits[0]
        let source = try XCTUnwrap(edit.transition?.source)
        let destination = try XCTUnwrap(edit.transition?.destination)
        let migration = SyncKeyedMigration(store: .history, change: .file(SyncKeyedFileMove(
            source: "history/" + source + "/head.json", destination: "history/" + destination + "/head.json",
            bytes: Data("opaque history".utf8))))
        let record = try SyncApplyRecord(plan: fixture.plan, steps: [SyncApplyStep(edit: edit, migrations: [migration])])
        var object = try SyncTestValues.object(record)
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        var migrations = try XCTUnwrap(steps[0]["migrations"] as? [[String: Any]])
        migrations[0]["store"] = "values"
        steps[0]["migrations"] = migrations
        object["steps"] = steps
        let bytes = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SyncApplyRecord.self, from: bytes)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        try fixture.rig.data.writePrivate(bytes, at: "sync/apply.json")
        let accesses = fixture.rig.files.accessCount
        XCTAssertThrowsError(try SyncApplyJournal(files: fixture.rig.data, operations: fixture.rig.dataOperations,
                                                mutations: fixture.rig.mutations, states: fixture.rig.states)) {
            XCTAssertEqual($0 as? SyncError, .corruptFile)
        }
        XCTAssertEqual(fixture.rig.files.accessCount, accesses)
    }

    func testOversizedHistoryIntentFailsBeforeMutationAndReleasesPermit() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Local"), at: "a.md")
        // Base64 source and destination bytes together exceed the journal cap.
        let history = Data(repeating: 65, count: 6 * 1_024 * 1_024 + 1)
        let path = "history/" + SyncTestValues.personalPrompt.rawValue + "/revision.md"
        try rig.data.writePrivate(history, at: path)
        let file = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let edit = try rig.mutations.publication(SyncApplyTestRig.bytes("Server", id: SyncTestValues.groupPrompt),
            at: "a.md", expecting: file, transition: SyncIdentityTransition(from: file.identity,
                to: .assigned(SyncTestValues.groupPrompt)))
        let writes = rig.files.writeCount
        XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit]))) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        XCTAssertEqual(rig.files.writeCount, writes)
        XCTAssertEqual(rig.libraryOperations.operationCount, 0)
        XCTAssertEqual(try rig.files.read(at: "a.md"), file.bytes)
        XCTAssertEqual(try rig.data.read(at: path), history)
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
        XCTAssertNoThrow(try rig.library.load(at: "a.md"))
    }

    func testDecodedInvalidUsagePayloadFailsBeforeLibraryIO() throws {
        let fixture = try preparedAdoption()
        let edit = fixture.plan.edits[0]
        let valid = Data("{\"events\":[12],\"version\":1}".utf8)
        let move = SyncKeyedFileMove(source: "usage/" + (try XCTUnwrap(edit.transition?.source)),
            destination: "usage/" + (try XCTUnwrap(edit.transition?.destination)), bytes: valid)
        let record = try SyncApplyRecord(plan: fixture.plan, steps: [SyncApplyStep(edit: edit,
            migrations: [SyncKeyedMigration(store: .usage, change: .file(move))])])
        var object = try SyncTestValues.object(record)
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        // Hash-consistent bytes can still violate the usage payload format.
        steps[0]["migrations"] = [try SyncTestValues.object(SyncKeyedMigration(store: .usage,
            change: .file(SyncKeyedFileMove(source: move.source, destination: move.destination,
                                          bytes: Data("broken".utf8)))))]
        object["steps"] = steps
        let bytes = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SyncApplyRecord.self, from: bytes)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        try fixture.rig.data.writePrivate(bytes, at: "sync/apply.json")
        let accesses = fixture.rig.files.accessCount
        XCTAssertThrowsError(try SyncApplyJournal(files: fixture.rig.data, operations: fixture.rig.dataOperations,
                                                mutations: fixture.rig.mutations, states: fixture.rig.states)) {
            XCTAssertEqual($0 as? SyncError, .corruptFile)
        }
        XCTAssertEqual(fixture.rig.files.accessCount, accesses)
    }

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
            XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan), "write \(number)") {
                XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure))
            }
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
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan)) {
            XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure))
        }
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
            XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit])), "replaced: \(replaced)") {
                XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .durabilityFailed)
                XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .applied)
            }
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
        XCTAssertThrowsError(try rig.journal.apply(plan)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .durabilityFailed)
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .applied)
        }
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
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        let record = try fixture.rig.data.read(at: "sync/apply.json")
        for variant in 0...4 {
            let data = MemoryFileStore()
            if variant == 0 { try data.put("broken", at: "sync/apply.json") }
            else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
                if variant == 1 { object["version"] = 99 }
                else {
                    var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
                    if variant == 2 {
                        var edit = try XCTUnwrap(XCTUnwrap(steps.first)["edit"] as? [String: Any])
                        edit["hash"] = String(repeating: "0", count: 64)
                        steps[0]["edit"] = edit
                    } else {
                        steps[0].removeValue(forKey: variant == 3 ? "started" : "completed")
                    }
                    object["steps"] = steps
                }
                try SyncTestValues.write(object, to: data, path: "sync/apply.json")
            }
            let files = MemoryFileStore()
            let library = LibraryService(library: files, data: data, clock: LibraryClock(), entropy: LibraryEntropy())
            let dataOps = MemorySyncFileOperations(files: data)
            XCTAssertThrowsError(try SyncApplyJournal(files: data, operations: dataOps,
                mutations: SyncLibraryMutations(library: library, operations: MemorySyncFileOperations(files: files)),
                states: SyncStateStore(files: data, operations: dataOps)), "variant \(variant)") {
                XCTAssertEqual($0 as? SyncError, variant == 1 ? .futureVersion(99) : .corruptFile)
            }
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

    func testWrongAccountStateCannotReplayOrCommitPendingJournal() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.libraryOperations.failOperationNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        rig.libraryOperations.failOperationNumber = nil
        let journal = try rig.data.read(at: "sync/apply.json")
        try rig.states.reset(for: SyncTestValues.binding(userID: SyncTestValues.otherUser))
        let operations = rig.libraryOperations.operationCount
        XCTAssertThrowsError(try rig.journal.replay()) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
        XCTAssertEqual(rig.libraryOperations.operationCount, operations)
        XCTAssertEqual(try rig.data.read(at: "sync/apply.json"), journal)
        XCTAssertEqual(rig.states.snapshot.value?.binding.account.userID, SyncTestValues.otherUser)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
    }

    func testUncertainStateRecoveryChecksBindingBeforeFlush() throws {
        let rig = try SyncApplyTestRig()
        let plan = try rig.plan([rig.replacement()])
        rig.dataOperations.onOperation = { operation in
            guard operation == "file:sync/state.json" else { return }
            rig.dataOperations.failOperationNumber = rig.dataOperations.operationCount
        }
        XCTAssertThrowsError(try rig.journal.apply(plan)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
        rig.dataOperations.onOperation = nil
        rig.dataOperations.failOperationNumber = nil
        let foreign = try SyncState(binding: SyncTestValues.binding(userID: SyncTestValues.otherUser))
        try rig.data.writePrivate(JSONEncoder().encode(foreign), at: "sync/state.json")
        let operations = rig.dataOperations.operationCount
        XCTAssertThrowsError(try rig.journal.replay()) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
        XCTAssertEqual(rig.dataOperations.operationCount, operations)
        XCTAssertEqual(rig.states.snapshot.error, .durabilityUncertain)
        XCTAssertThrowsError(try rig.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        try rig.data.writePrivate(JSONEncoder().encode(plan.nextState), at: "sync/state.json")
        XCTAssertEqual(try rig.journal.replay(), .committed)
        XCTAssertNoThrow(try rig.library.entries())
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
        XCTAssertThrowsError(try fixture.rig.journal.apply(fixture.plan)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
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

    func testDisplacedRetentionConflictKeepsPermanentErrorAndAppliedBytes() throws {
        for flushFails in [false, true] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
            let edit = try rig.replacement()
            let displaced = SyncApplyTestRig.bytes("New noncooperating writer")
            let retained = SyncApplyTestRig.bytes("Previously retained writer")
            let path = "sync/retained/" + edit.id.uuidString.lowercased() + "-displaced.bin"
            try rig.data.writePrivate(retained, at: path)
            rig.libraryOperations.racingBytesAfterCheck = displaced
            if flushFails { rig.libraryOperations.failFlushNumber = 1 }
            XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit]))) {
                let error = $0 as? SyncFileOperationError
                XCTAssertEqual(error?.code, .invalidState)
                XCTAssertEqual(error?.effect, .applied)
                XCTAssertEqual(error?.displacedBytes, displaced)
            }
            XCTAssertEqual(try rig.files.read(at: "a.md"), edit.bytes)
            XCTAssertEqual(try rig.data.read(at: path), retained)
            XCTAssertNil(rig.states.snapshot.value)
            XCTAssertNotNil(rig.journal.pending)
            XCTAssertThrowsError(try rig.library.entries()) {
                XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
            }
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
        // A distinct library graph may read its own files while shared keyed
        // writes still respect the older graph's pending recovery permit.
        XCTAssertNoThrow(try other.entries())
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
