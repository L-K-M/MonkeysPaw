import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncReconcilerTests: XCTestCase {
    private let user = SyncTestValues.user
    private let group = SyncTestValues.group
    private let id = SyncTestValues.personalPrompt
    private let other = SyncTestValues.groupPrompt
    private let database = SyncTestValues.uuid
    private let restored = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var personal: SyncScopeKey { .user(user) }
    private var team: SyncScopeKey { .group(group) }

    func testOwnEchoAndOlderDeltaAreNoOpsEvenWithDirtyLocalContent() throws {
        for rev: Int64 in [2, 7] {
            let rig = try SyncApplyTestRig()
            let old = try baseline(rig, [record(id, "a.md", body: "Acknowledged", rev: 7)])
            let dirty = bytes("Unsynced edit")
            try rig.files.write(dirty, at: "a.md")
            let pull = try collected([scope(items: [upsert(10, rev: rev, body: "Echo")])])
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            XCTAssertTrue(plan.operations.isEmpty)
            let writes = rig.files.writeCount
            XCTAssertEqual(try apply(plan, rig), .committed)
            XCTAssertEqual(rig.files.writeCount, writes)
            XCTAssertEqual(try rig.files.read(at: "a.md"), dirty)
            XCTAssertEqual(rig.states.snapshot.value?.prompts, old.prompts)
            XCTAssertEqual(rig.states.snapshot.value?.cursors, pull.cursors)
        }
    }

    func testOwnMoveEchoCannotRemoveTheNewScopeEntry() throws {
        let rig = try SyncApplyTestRig()
        let content = try groupBytes("Moved")
        _ = try baseline(rig, [record(id, "a.md", data: content, rev: 2, scope: team)])
        try rig.files.write(content, at: "Groups/Team/a.md")
        let pull = try collected([scope(items: [.moveOut(seq: 10, id: id.rawValue)]),
            scope(team, items: [upsert(11, rev: 2, data: content)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), content)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, team)
        XCTAssertTrue(rig.libraryOperations.trashed.isEmpty)
    }

    func testMoveChainsFoldByGlobalSequenceBeforeAnyDestruction() throws {
        let rig = try SyncApplyTestRig()
        let original = bytes("Original")
        _ = try baseline(rig, [record(id, "a.md", data: original)])
        try rig.files.write(original, at: "a.md")
        let final = try groupBytes("Final")
        // Collection/scope order deliberately disagrees with global order.
        let pull = try collected([scope(team, items: [
            upsert(11, path: "in.md", rev: 2, data: try groupBytes("In")),
            .moveOut(seq: 12, id: id.rawValue), upsert(15, path: "final.md", rev: 4, data: final)]),
            scope(items: [.moveOut(seq: 10, id: id.rawValue), upsert(13, path: "back.md", rev: 3, body: "Back"),
                          .moveOut(seq: 14, id: id.rawValue)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations)
        XCTAssertEqual(application.edits.map(\.path), ["Groups/Team/final.md", "a.md"])
        XCTAssertEqual(try rig.journal.apply(application), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/final.md"), final)
        XCTAssertEqual(try rig.files.listFiles().map(\.relativePath), ["Groups/Team/final.md"])
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 4)
        XCTAssertTrue(try retained(rig).contains(original))
    }

    func testMoveBackEchoIsNotTurnedIntoDeletionByEarlierMoveOut() throws {
        let rig = try SyncApplyTestRig()
        let final = try groupBytes("Acknowledged final")
        _ = try baseline(rig, [record(id, "a.md", data: final, rev: 4, scope: team)])
        try rig.files.write(final, at: "Groups/Team/a.md")
        let pull = try collected([scope(team, items: [.moveOut(seq: 10, id: id.rawValue), upsert(13, rev: 4, data: final)]),
            scope(items: [upsert(11, rev: 3, body: "Intermediate"), .moveOut(seq: 12, id: id.rawValue)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), final)
    }

    func testRemoteRenameLeavesAReplacedOldPathOccupantUntouched() throws {
        let rig = try SyncApplyTestRig()
        _ = try baseline(rig, [record(id, "old.md", body: "Recorded")])
        let unrelated = bytes("Replacement occupant", id: other)
        try rig.files.write(unrelated, at: "old.md")
        let server = bytes("Renamed server")
        let pull = try collected([scope(items: [upsert(10, path: "new.md", rev: 2, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "old.md"), unrelated)
        XCTAssertEqual(try rig.files.read(at: "new.md"), server)
        XCTAssertTrue(rig.libraryOperations.trashed.isEmpty)
    }

    func testNormalSnapshotMissingCleanAndDirtyIDsUseDifferentOutcomes() throws {
        for dirty in [false, true] {
            let rig = try SyncApplyTestRig()
            let original = bytes("Baseline")
            _ = try baseline(rig, [record(id, "a.md", data: original)])
            let local = dirty ? bytes("Unsynced") : original
            try rig.files.write(local, at: "a.md")
            let pull = try collected([scope(mode: .snapshot, head: 0)])
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            XCTAssertNil(plan.nextState.prompts[.assigned(id)])
            if dirty {
                XCTAssertEqual(try preservation(plan).reason, .dirtyRemoval)
                XCTAssertThrowsError(try apply(plan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
                XCTAssertEqual(rig.states.snapshot.value?.cursors[personal], "old personal cursor")
                XCTAssertEqual(try rig.files.read(at: "a.md"), local)
                XCTAssertNil(rig.journal.pending)
            } else {
                guard case .remove = try XCTUnwrap(plan.operations.first) else { return XCTFail("Expected guarded deletion") }
                XCTAssertEqual(try apply(plan, rig), .committed)
                XCTAssertNil(try rig.files.stamp(at: "a.md"))
                XCTAssertTrue(try retained(rig).contains(local))
            }
        }
    }

    func testRemovalFindsAnActualMovedIDAndNeverRemovesItsReplacement() throws {
        let rig = try SyncApplyTestRig()
        _ = try baseline(rig, [record(id, "old.md", body: "Baseline")])
        let changed = bytes("Locally moved and edited")
        let unrelated = bytes("Occupant", id: other)
        try rig.files.write(changed, at: "elsewhere.md")
        try rig.files.write(unrelated, at: "old.md")
        let pull = try collected([scope(items: [.delete(seq: 10, id: id.rawValue)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try preservation(plan).local.path, "elsewhere.md")
        let copy = try rescue(plan, rig, at: "Conflicts/Deleted.md")
        XCTAssertEqual(try apply(plan, rig, copies: copy), .committed)
        XCTAssertEqual(try rig.files.read(at: "old.md"), unrelated)
        XCTAssertNil(try rig.files.stamp(at: "elsewhere.md"))
        XCTAssertTrue(try retained(rig).contains(changed))
    }

    func testMissingIDDoesNotAuthorizeRemovalOfAnUnrelatedFile() throws {
        for mode: SyncAPI.Mode in [.delta, .snapshot] {
            let rig = try SyncApplyTestRig()
            _ = try baseline(rig, [record(id, "a.md", body: "Recorded")])
            let unrelated = bytes("New occupant", id: other)
            try rig.files.write(unrelated, at: "a.md")
            let pull = try collected([scope(mode: mode, items: mode == .delta ? [.delete(seq: 10, id: id.rawValue)] : [])])
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            XCTAssertTrue(plan.operations.isEmpty)
            XCTAssertEqual(try apply(plan, rig), .committed)
            XCTAssertEqual(try rig.files.read(at: "a.md"), unrelated)
            XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
        }
    }

    func testRestoreMissingIDsAlwaysGetFreshPrivateRescues() throws {
        for dirty in [false, true] {
            let rig = try SyncApplyTestRig()
            let old = bytes("Before restore")
            _ = try baseline(rig, [record(id, "a.md", data: old, rev: 99)])
            let local = dirty ? bytes("New local edit") : old
            try rig.files.write(local, at: "a.md")
            let pull = try collected([scope(mode: .snapshot, head: 0)], database: restored)
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            XCTAssertEqual(plan.mode, .restore)
            XCTAssertEqual(try preservation(plan).reason, .restoreMissing)
            let copies = try rescue(plan, rig, at: "Conflicts/Rescued.md")
            let application = try SyncReconciler.application(plan, mutations: rig.mutations, copies: copies)
            XCTAssertEqual(application.edits.map(\.kind), [.rescue, .trash])
            XCTAssertEqual(try rig.journal.apply(application), .committed)
            let copyID = try XCTUnwrap(application.edits.first?.copyID)
            XCTAssertNotEqual(copyID, id.rawValue)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[try SyncIdentifiers.promptIdentity(copyID)]?.origin, .rescued)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[try SyncIdentifiers.promptIdentity(copyID)]?.rev, 0)
            XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
            XCTAssertTrue(try retained(rig).contains(local))
        }
    }

    func testSnapshotsAdoptEqualContentAtLowerRevisionsBeforeEchoShortcut() throws {
        for database in [database, restored] {
            let rig = try SyncApplyTestRig()
            let content = bytes("Equal")
            _ = try baseline(rig, [record(id, "a.md", data: content, rev: 99)])
            try rig.files.write(content, at: "a.md")
            let pull = try collected([scope(mode: .snapshot, items: [upsert(10, rev: 2, data: content)])], database: database)
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            XCTAssertTrue(plan.operations.isEmpty)
            let writes = rig.files.writeCount
            XCTAssertEqual(try apply(plan, rig), .committed)
            XCTAssertEqual(rig.files.writeCount, writes)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 2)
            XCTAssertEqual(rig.states.snapshot.value?.databaseID, database)
        }
    }

    func testNormalSnapshotWithDifferentLowerRevisionPreservesDirtyLocal() throws {
        let rig = try SyncApplyTestRig()
        _ = try baseline(rig, [record(id, "a.md", body: "Baseline", rev: 99)])
        let local = bytes("Dirty")
        try rig.files.write(local, at: "a.md")
        let server = bytes("Server at lower rev")
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, rev: 2, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try preservation(plan).reason, .dirtyUpsert)
        XCTAssertEqual(try apply(plan, rig, copies: rescue(plan, rig)), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), server)
        XCTAssertTrue(try retained(rig).contains(local))
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 2)
    }

    func testUnchangedNormalSnapshotLeavesLaterLocalIntentForScanner() throws {
        for intent in ["edit", "rename", "move", "delete"] {
            let rig = try SyncApplyTestRig()
            let acknowledged = try groupBytes("Acknowledged move")
            _ = try baseline(rig, [record(id, "a.md", data: acknowledged, rev: 7, scope: team)])
            let path: RelativePath = intent == "move" ? "private.md" : intent == "rename" ? "Groups/Team/b.md" : "Groups/Team/a.md"
            if intent != "delete" {
                try rig.files.write(intent == "edit" ? groupBytes("Queued edit") : acknowledged, at: path.string)
            }
            let pull = try collected([scope(), scope(team, mode: .snapshot,
                items: [upsert(10, rev: 2, data: acknowledged)])])
            defer { try? pull.discard() }
            let plan = try reconcile(pull, rig)
            guard plan.operations.isEmpty else { XCTFail("Snapshot replayed over local \(intent)"); continue }
            let writes = rig.files.writeCount
            XCTAssertEqual(try apply(plan, rig), .committed)
            XCTAssertEqual(rig.files.writeCount, writes)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 2)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: acknowledged))
            let scan = try SyncScanTestSupport.scan(rig)
            XCTAssertNil(scan.preparation)
            XCTAssertEqual(scan.changes.count, 1)
            switch (intent, try XCTUnwrap(scan.changes.first)) {
            case ("edit", .update(_, let recorded)), ("rename", .rename(_, let recorded)),
                 ("move", .move(_, let recorded)), ("delete", .delete(_, let recorded)):
                XCTAssertEqual(recorded.rev, 2)
            default: XCTFail("Lost local \(intent)")
            }
        }
    }

    func testUnchangedBaselineAfterRestoreStillRestoresMissingFile() throws {
        let rig = try SyncApplyTestRig()
        let acknowledged = bytes("Acknowledged")
        _ = try baseline(rig, [record(id, "a.md", data: acknowledged, rev: 7)])
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, rev: 2, data: acknowledged)])], database: restored)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(plan.mode, .restore)
        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), acknowledged)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 2)
    }

    func testRestoreDifferentContentAdoptsHeadAndQueuesFreshRepushWithoutOverwrite() throws {
        let rig = try SyncApplyTestRig()
        let local = bytes("Local before restore")
        _ = try baseline(rig, [record(id, "a.md", data: local, rev: 99)])
        try rig.files.write(local, at: "a.md")
        let server = bytes("Restored old server")
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, rev: 2, data: server)])], database: restored)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(plan.restoreUpdates.count, 1)
        XCTAssertEqual(plan.restoreUpdates.first?.remote.rev, 2)
        XCTAssertEqual(plan.restoreUpdates.first?.local.bytes, local)
        XCTAssertTrue(try SyncReconciler.application(plan, mutations: rig.mutations).edits.isEmpty)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), local)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: server))
        XCTAssertEqual(rig.states.snapshot.value?.databaseID, restored)
    }

    func testRestoreViewerDifferencesArePrivateInsteadOfRepushed() throws {
        let rig = try SyncApplyTestRig()
        let local = try groupBytes("Viewer local version")
        _ = try baseline(rig, [record(id, "a.md", data: local, rev: 99, scope: team)], role: .viewer)
        try rig.files.write(local, at: "Groups/Team/a.md")
        let server = try groupBytes("Restored viewer server")
        let pull = try collected([scope(mode: .snapshot, head: 0),
            scope(team, mode: .snapshot, items: [upsert(10, rev: 2, data: server)], role: .viewer)], database: restored)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertTrue(plan.restoreUpdates.isEmpty)
        XCTAssertEqual(try preservation(plan).reason, .restoreViewer)
        XCTAssertEqual(try apply(plan, rig, copies: rescue(plan, rig)), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), server)
        XCTAssertEqual(rig.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
        XCTAssertTrue(try retained(rig).contains(local))
    }

    func testSnapshotThenTailDeltaStillAdoptsLowerRevision() throws {
        let rig = try SyncApplyTestRig()
        let old = bytes("Clean local baseline")
        _ = try baseline(rig, [record(id, "a.md", data: old, rev: 99)])
        try rig.files.write(old, at: "a.md")
        let staging = SyncPullStaging(files: MemoryFileStore())
        let snapshot = scope(mode: .snapshot, head: 10, items: [upsert(10, rev: 2, body: "Snapshot")])
        let delta = scope(head: 11, items: [upsert(11, rev: 3, body: "Tail")])
        try staging.append(.init(databaseID: database.uuidString.lowercased(), scopes: [snapshot], removed: []))
        try staging.append(.init(databaseID: database.uuidString.lowercased(), scopes: [delta], removed: []))
        let pull = SyncCollectedPull(databaseID: database,
            scopes: [personal: .init(page: delta, snapshotHead: 10, firstPage: 0)], removed: [], staging: staging)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 3)
        XCTAssertEqual(try rig.files.read(at: "a.md"), bytes("Tail"))
        XCTAssertTrue(try retained(rig).contains(old))
    }

    func testSnapshotsReconcileFinalOwnershipBeforeMissingIDDeletion() throws {
        let rig = try SyncApplyTestRig()
        let old = bytes("Clean before remote move")
        _ = try baseline(rig, [record(id, "a.md", data: old)])
        try rig.files.write(old, at: "a.md")
        let moved = try groupBytes("Clean before remote move")
        let pull = try collected([scope(mode: .snapshot, head: 0),
            scope(team, mode: .snapshot, items: [upsert(10, rev: 2, data: moved)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertFalse(plan.operations.contains { if case .preserve = $0 { return true }; return false })
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, team)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), moved)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
    }

    func testSeparatelyCapturedSnapshotsStraddlingMoveChooseLaterOwner() throws {
        let rig = try SyncApplyTestRig()
        let old = bytes("Before move")
        _ = try baseline(rig, [record(id, "a.md", data: old)])
        try rig.files.write(old, at: "a.md")
        let moved = try groupBytes("After move")
        let pull = try collected([scope(team, mode: .snapshot, head: 20, items: [upsert(20, rev: 2, data: moved)]),
            scope(mode: .snapshot, head: 10, items: [upsert(10, data: old)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, team)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), moved)
    }

    func testMultiScopeRestoreCommitsUUIDOnceAfterEveryFileIsDurable() throws {
        let rig = try SyncApplyTestRig()
        let personalBytes = bytes("Personal equal")
        let sharedBytes = try groupBytes("Group equal", id: other)
        let old = try baseline(rig, [record(id, "a.md", data: personalBytes, rev: 99),
            record(other, "b.md", data: sharedBytes, rev: 80, scope: team)])
        try rig.files.write(personalBytes, at: "a.md")
        try rig.files.write(sharedBytes, at: "Groups/Team/b.md")
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, path: "new.md", rev: 2, data: personalBytes)]),
            scope(team, mode: .snapshot, items: [upsert(20, id: other, path: "new.md", rev: 3, data: sharedBytes)])], database: restored)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations)
        rig.libraryOperations.onOperation = { operation in
            XCTAssertEqual(rig.states.snapshot.value, old)
            if operation == "publish:Groups/Team/new.md" {
                rig.libraryOperations.failOperationNumber = rig.libraryOperations.operationCount
            }
        }
        XCTAssertThrowsError(try rig.journal.apply(application))
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertEqual(rig.states.snapshot.value?.databaseID, database)
        XCTAssertEqual(try rig.files.read(at: "new.md"), personalBytes)
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/new.md"))
        XCTAssertNotNil(rig.journal.pending)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(restarted.states.snapshot.value?.databaseID, restored)
        XCTAssertEqual(restarted.states.snapshot.value?.prompts[.assigned(id)]?.rev, 2)
        XCTAssertEqual(restarted.states.snapshot.value?.prompts[.assigned(other)]?.rev, 3)
        XCTAssertEqual(restarted.states.snapshot.value?.cursors, pull.cursors)
        XCTAssertEqual(try restarted.files.listFiles().map(\.relativePath).sorted(), ["Groups/Team/new.md", "new.md"])
        XCTAssertTrue(try retained(restarted).contains(personalBytes))
        XCTAssertTrue(try retained(restarted).contains(sharedBytes))
    }

    func testDirtyRenameFailureBetweenStepsPreservesVersionsWithoutAcknowledgement() throws {
        let rig = try SyncApplyTestRig()
        let old = try baseline(rig, [record(id, "a.md", body: "Baseline")])
        let dirty = bytes("Losing dirty bytes")
        let server = bytes("Authoritative server")
        let unrelated = bytes("Leave alone", id: other)
        try rig.files.write(dirty, at: "a.md")
        try rig.files.write(unrelated, at: "other.md")
        let pull = try collected([scope(items: [upsert(10, path: "new.md", rev: 2, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations, copies: rescue(plan, rig))
        rig.libraryOperations.onOperation = { operation in
            if operation == "trash:a.md" { rig.libraryOperations.failOperationNumber = rig.libraryOperations.operationCount }
        }
        XCTAssertThrowsError(try rig.journal.apply(application))
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertEqual(try rig.files.read(at: "a.md"), dirty)
        XCTAssertEqual(try rig.files.read(at: "new.md"), server)
        XCTAssertTrue(try retained(rig).contains(dirty))
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.files.read(at: "other.md"), unrelated)
        XCTAssertNil(try restarted.files.stamp(at: "a.md"))
        XCTAssertEqual(try restarted.files.listFiles().count, 3)
        XCTAssertEqual(restarted.states.snapshot.value?.cursors, pull.cursors)
    }

    func testApplicationRejectsRacingReplacementAndNeverAcknowledges() throws {
        let rig = try SyncApplyTestRig()
        let original = bytes("Original clean")
        let old = try baseline(rig, [record(id, "a.md", data: original)])
        try rig.files.write(original, at: "a.md")
        let pull = try collected([scope(items: [upsert(10, rev: 2, body: "Remote")])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations)
        let replacement = bytes("Unrelated incarnation", id: other)
        try rig.files.write(replacement, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(application), .replanAsConflict(operationID: application.edits[0].id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), replacement)
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNotNil(rig.journal.pending)
        XCTAssertTrue(try retained(rig).contains(original))
    }

    func testDistinctCaseFoldedOccupantRequiresRelocationAndStaysIntact() throws {
        let rig = try SyncApplyTestRig()
        let old = try baseline(rig, [])
        let occupant = bytes("Distinct local occupant", id: other)
        try rig.files.write(occupant, at: "Straße.md")
        let pull = try collected([scope(items: [upsert(10, path: "STRASSE.md", body: "Incoming")])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        guard case .pathClash(_, let displaced) = try XCTUnwrap(plan.operations.first) else { return XCTFail("Expected clash") }
        XCTAssertEqual(displaced.bytes, occupant)
        XCTAssertThrowsError(try apply(plan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        XCTAssertEqual(try rig.files.read(at: "Straße.md"), occupant)
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNil(rig.journal.pending)
    }

    func testFirstSyncDefersOccupiedIdentityNeutralMatchToAdoption() throws {
        let rig = try SyncApplyTestRig()
        let content = bytes("Copied library", id: other)
        try rig.files.write(content, at: "a.md")
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, body: "Copied library")])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(plan.mode, .firstSync)
        guard case .adoption(let remote, let local) = try XCTUnwrap(plan.operations.first) else { return XCTFail("Expected adoption seam") }
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(local.bytes, remote.bytes, scope: .user, filename: "a.md"))
        XCTAssertThrowsError(try apply(plan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNil(rig.journal.pending)
        XCTAssertEqual(try rig.files.read(at: "a.md"), content)
    }

    func testUnknownSnapshotIDAtVacantPathInstallsExactBytes() throws {
        let rig = try SyncApplyTestRig()
        let server = bytes("Exact CRLF\r\nTrailing\n\n")
        let pull = try collected([scope(mode: .snapshot, items: [upsert(10, rev: 4, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), server)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 4)
    }

    func testUnsafeSupersededOrEchoPathsAreRejectedBeforeAnyWrite() throws {
        for path in ["../bad.md", "a/../bad.md", "Groups/bad.md", "e\u{301}.md"] {
            let rig = try SyncApplyTestRig()
            let original = bytes("Unchanged")
            let old = try baseline(rig, [record(id, "a.md", data: original, rev: 7)])
            try rig.files.write(original, at: "a.md")
            let pull = try collected([scope(items: [upsert(10, path: path, rev: 2), upsert(11, rev: 8)])])
            defer { try? pull.discard() }
            XCTAssertThrowsError(try reconcile(pull, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .invalidPull) }
            XCTAssertEqual(rig.states.snapshot.value, old)
            XCTAssertEqual(try rig.files.read(at: "a.md"), original)
            XCTAssertNil(rig.journal.pending)
        }
    }

    func testInvalidRemoteIdentityAndNoncanonicalGroupBytesFailBeforeWrite() throws {
        for badGroup in [false, true] {
            let rig = try SyncApplyTestRig()
            _ = try baseline(rig, [])
            let invalid = badGroup ? bytes("Valid but not group canonical") : bytes("Wrong front-matter ID", id: other)
            let scopes = badGroup ? [scope(), scope(team, items: [upsert(10, data: invalid)])]
                : [scope(items: [upsert(10, data: invalid)])]
            let pull = try collected(scopes)
            defer { try? pull.discard() }
            XCTAssertThrowsError(try reconcile(pull, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .invalidPull) }
            XCTAssertTrue(try rig.files.listFiles().isEmpty)
            XCTAssertNil(rig.journal.pending)
        }
    }

    func testUnavailableRootAndDuplicateIDsCannotInferDeletions() throws {
        let rig = try SyncApplyTestRig()
        let old = try baseline(rig, [record(id, "a.md")])
        let pull = try collected([scope(mode: .snapshot, head: 0)])
        defer { try? pull.discard() }
        XCTAssertThrowsError(try SyncReconciler.plan(pull, state: old,
            local: .init(binding: rig.binding, files: [], availability: .unavailable))) {
            XCTAssertEqual($0 as? SyncReconciliationError, .unavailableLibrary)
        }
        try rig.files.write(bytes("A"), at: "a.md")
        try rig.files.write(bytes("B"), at: "b.md")
        XCTAssertThrowsError(try reconcile(pull, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .invalidLocalSnapshot) }
        XCTAssertEqual(try rig.files.listFiles().count, 2)
        XCTAssertEqual(rig.states.snapshot.value, old)
    }

    func testLocalVisibilityAndRemovedScopeStayTypedAndUnacknowledged() throws {
        let rig = try SyncApplyTestRig()
        let old = try baseline(rig, [record(other, "b.md", scope: team)])
        let invisible = try collected([scope(items: [upsert(10, path: "_Hidden.md")]), scope(team)])
        defer { try? invisible.discard() }
        let plan = try reconcile(invisible, rig)
        guard case .localVisibility = try XCTUnwrap(plan.operations.first) else { return XCTFail("Expected visibility seam") }
        XCTAssertThrowsError(try apply(plan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        let removed = try collected([scope()], removed: [team])
        defer { try? removed.discard() }
        let removedPlan = try reconcile(removed, rig)
        XCTAssertTrue(removedPlan.operations.contains { if case .removedScope = $0 { return true }; return false })
        XCTAssertThrowsError(try apply(removedPlan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNil(rig.journal.pending)
    }

    func testWrongPreservationBytesOrCopyIdentityCannotAuthorizeRemoval() throws {
        let rig = try SyncApplyTestRig()
        let old = try baseline(rig, [record(id, "a.md")])
        let losing = bytes("Losing edit")
        try rig.files.write(losing, at: "a.md")
        try rig.files.write(bytes("Untracked identity", id: SyncTestValues.device), at: "untracked.md")
        let pull = try collected([scope(mode: .snapshot, head: 0)], database: restored)
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let duplicate = try rescue(plan, rig)
        XCTAssertThrowsError(try apply(plan, rig, copies: duplicate)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        let wrongFile = try SyncLibraryFile(path: "a.md", stamp: FileStamp("wrong"), bytes: bytes("Wrong preserved bytes"))
        let wrongEdit = try rig.mutations.rescue(wrongFile, at: "Conflicts/Other.md", freshID: ULID("00000000000000000000000007")!)
        XCTAssertThrowsError(try apply(plan, rig, copies: ["a.md": .init(edit: wrongEdit, origin: .rescued)])) {
            XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy)
        }
        XCTAssertEqual(try rig.files.read(at: "a.md"), losing)
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNil(rig.journal.pending)
    }

    func testOperationDescriptionsAndReflectionDoNotExposePromptContent() throws {
        let rig = try SyncApplyTestRig()
        _ = try baseline(rig, [])
        let sentinel = "sensitive-reconciliation-sentinel"
        let pull = try collected([scope(items: [upsert(10, body: sentinel)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertFalse(String(describing: plan).contains(sentinel))
        XCTAssertFalse(String(reflecting: plan).contains(sentinel))
        XCTAssertFalse(String(reflecting: plan.operations).contains(sentinel))
        XCTAssertFalse(String(describing: Mirror(reflecting: plan).children.map(\.value)).contains(sentinel))
    }

    func testWrongScopeRemovalIsANoOp() throws {
        let rig = try SyncApplyTestRig()
        let local = try groupBytes("Correctly owned")
        _ = try baseline(rig, [record(id, "a.md", data: local, scope: team)])
        try rig.files.write(local, at: "Groups/Team/a.md")
        let pull = try collected([scope(items: [.delete(seq: 10, id: id.rawValue)]), scope(team)])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(try apply(plan, rig), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), local)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, team)
    }

    func testLateEditAtRetiringPathRemainsIntactAndBlocksAcknowledgement() throws {
        let rig = try SyncApplyTestRig()
        let original = bytes("Original")
        let old = try baseline(rig, [record(id, "a.md", data: original)])
        try rig.files.write(original, at: "a.md")
        let server = bytes("Remote rename")
        let pull = try collected([scope(items: [upsert(10, path: "new.md", rev: 2, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations)
        let late = bytes("Late local edit")
        rig.libraryOperations.beforePublish = { path in
            if path == "new.md" { try rig.files.write(late, at: "a.md") }
        }
        XCTAssertEqual(try rig.journal.apply(application), .replanAsConflict(operationID: application.edits[1].id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), late)
        XCTAssertEqual(try rig.files.read(at: "new.md"), server)
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNotNil(rig.journal.pending)
        XCTAssertTrue(try retained(rig).contains(original))
    }

    func testAdditionalDisplacedVersionIsRetainedAlongsideExpectedVersion() throws {
        let rig = try SyncApplyTestRig()
        let original = bytes("Expected local version")
        _ = try baseline(rig, [record(id, "a.md", data: original)])
        try rig.files.write(original, at: "a.md")
        let racing = bytes("Additional displaced version")
        let server = bytes("Remote")
        let pull = try collected([scope(items: [upsert(10, rev: 2, data: server)])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        rig.libraryOperations.racingBytesAfterCheck = racing
        XCTAssertEqual(try apply(plan, rig), .committed)
        let retained = try retained(rig)
        XCTAssertTrue(retained.contains(original))
        XCTAssertTrue(retained.contains(racing))
        XCTAssertEqual(try rig.files.read(at: "a.md"), server)
    }

    func testMultipleCaseFoldedOccupantsAreDeferredWithoutRemovingEither() throws {
        let rig = try SyncApplyTestRig()
        _ = try baseline(rig, [])
        let first = bytes("First occupant", id: other)
        let second = bytes("Second occupant", id: SyncTestValues.device)
        try rig.files.write(first, at: "A.md")
        try rig.files.write(second, at: "a.md")
        let pull = try collected([scope(items: [upsert(10, path: "a.md")])])
        defer { try? pull.discard() }
        let plan = try reconcile(pull, rig)
        XCTAssertEqual(plan.operations.filter { if case .pathClash = $0 { return true }; return false }.count, 2)
        XCTAssertThrowsError(try apply(plan, rig)) { XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy) }
        XCTAssertEqual(try rig.files.read(at: "A.md"), first)
        XCTAssertEqual(try rig.files.read(at: "a.md"), second)
    }

    private func bytes(_ body: String, id: ULID? = nil) -> Data {
        SyncApplyTestRig.bytes(body, id: id ?? self.id)
    }

    private func groupBytes(_ body: String, id: ULID? = nil) throws -> Data {
        try CanonicalForm.group(bytes(body, id: id), filename: "a.md").bytes
    }

    private func record(_ id: ULID, _ path: RelativePath, body: String = "Baseline", data: Data? = nil,
                        rev: Int64 = 1, scope: SyncScopeKey? = nil) throws -> (PromptIdentity, SyncPromptState) {
        let scope = scope ?? personal
        let content = try data ?? (scope == personal ? bytes(body, id: id) : groupBytes(body, id: id))
        return (.assigned(id), try SyncPromptState(scope: scope, path: path, rev: rev,
            canonicalHash: SyncHash(bytes: content)))
    }

    @discardableResult
    private func baseline(_ rig: SyncApplyTestRig, _ records: [(PromptIdentity, SyncPromptState)],
                          role: SyncAPI.Role = .editor) throws -> SyncState {
        let groups = records.contains { $0.1.scope == team } ? [group: try SyncGroupState(name: "Team", folder: "Team", role: role)] : [:]
        var cursors = [personal: "old personal cursor"]
        if !groups.isEmpty { cursors[team] = "old group cursor" }
        let state = try SyncState(binding: rig.binding, databaseID: database, cursors: cursors,
            groups: groups, prompts: Dictionary(uniqueKeysWithValues: records))
        try rig.states.update(for: rig.binding) { $0 = state }
        return state
    }

    private func scope(_ key: SyncScopeKey? = nil, mode: SyncAPI.Mode = .delta, head: Int64 = 100,
                       items: [SyncAPI.FeedItem] = [], role: SyncAPI.Role = .editor) -> SyncAPI.SyncScope {
        let key = key ?? personal
        let identity: SyncAPI.ScopeIdentity = key == personal ? .user(userID: user.rawValue)
            : .group(groupID: group.rawValue, name: "Team", role: role)
        return .init(identity: identity, mode: mode, head: head, cursor: "new " + key.rawValue, hasMore: false, items: items)
    }

    private func upsert(_ seq: Int64, id: ULID? = nil, path: String = "a.md", rev: Int64 = 1,
                        body: String = "Server", data: Data? = nil) -> SyncAPI.FeedItem {
        .upsert(seq: seq, prompt: .init(id: (id ?? self.id).rawValue, rev: rev, path: path,
            content: String(decoding: data ?? bytes(body, id: id), as: UTF8.self)))
    }

    private func collected(_ scopes: [SyncAPI.SyncScope], database: UUID? = nil,
                           removed: Set<SyncScopeKey> = []) throws -> SyncCollectedPull {
        let database = database ?? self.database
        let staging = SyncPullStaging(files: MemoryFileStore())
        // Snapshot items carry the frozen scope head, rather than mutation seq.
        let scopes = scopes.map { scope -> SyncAPI.SyncScope in
            let items = scope.mode == .snapshot ? scope.items.map { item -> SyncAPI.FeedItem in
                if case .upsert(_, let prompt) = item { return .upsert(seq: scope.head, prompt: prompt) }
                return item
            } : scope.items
            return .init(identity: scope.identity, mode: scope.mode, head: scope.head,
                cursor: scope.cursor, hasMore: false, items: items)
        }
        try staging.append(.init(databaseID: database.uuidString.lowercased(), scopes: scopes, removed: removed.map(\.rawValue)))
        return SyncCollectedPull(databaseID: database,
            scopes: try Dictionary(uniqueKeysWithValues: scopes.map {
                (try SyncScopeKey($0.identity), SyncCollectedScope(page: $0, snapshotHead: $0.mode == .snapshot ? $0.head : nil, firstPage: 0))
            }), removed: removed, staging: staging)
    }

    private func reconcile(_ pull: SyncCollectedPull, _ rig: SyncApplyTestRig) throws -> SyncReconciliationPlan {
        let files = try rig.files.listFiles().map { try XCTUnwrap(rig.mutations.read(at: RelativePath($0.relativePath))) }
        return try SyncReconciler.plan(pull, state: rig.states.load(for: rig.binding),
            local: .init(binding: rig.binding, files: files), groupFolders: [group: "Team"])
    }

    private func apply(_ plan: SyncReconciliationPlan, _ rig: SyncApplyTestRig,
                       copies: [RelativePath: SyncReconciliationCopy] = [:]) throws -> SyncApplyOutcome {
        try SyncReconciler.apply(plan, mutations: rig.mutations, journal: rig.journal, copies: copies)
    }

    private func preservation(_ plan: SyncReconciliationPlan) throws -> SyncReconciliationPreservation {
        try XCTUnwrap(plan.operations.compactMap {
            if case .preserve(let preservation) = $0 { return preservation }; return nil
        }.first)
    }

    private func rescue(_ plan: SyncReconciliationPlan, _ rig: SyncApplyTestRig,
                        at destination: RelativePath = "Conflicts/Copy.md") throws -> [RelativePath: SyncReconciliationCopy] {
        let preservation = try preservation(plan)
        let origin: SyncPromptOrigin = preservation.reason == .restoreMissing ? .rescued : .conflictOf(preservation.id)
        let edit = try rig.mutations.rescue(preservation.local, at: destination, freshID: SyncTestValues.device, origin: origin)
        return [RelativePath(preservation.local.path): .init(edit: edit, origin: origin)]
    }

    private func retained(_ rig: SyncApplyTestRig) throws -> [Data] {
        try rig.data.listFiles().filter { $0.relativePath.hasPrefix("sync/retained/") && $0.relativePath.hasSuffix(".bin") }
            .map { try rig.data.read(at: $0.relativePath) }
    }
}
