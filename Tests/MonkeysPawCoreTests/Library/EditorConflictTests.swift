import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorConflictTests: XCTestCase {
    func testDirtyExternalModificationOpensImmediatelyAndKeepMineUsesTheirStamp() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        XCTAssertEqual(e.model.state.conflict?.kind, .modified)
        XCTAssertTrue(e.model.state.conflict?.isLoading == true)
        XCTAssertEqual(e.model.state.conflict?.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertEqual(e.model.state.source, "Mine")
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Theirs")
        XCTAssertEqual(e.model.state.conflict?.choices, [.keepMine, .takeTheirs, .saveAsCopy])
        e.ui { e.model.resolveConflict(.keepMine) }
        e.settle()
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Mine"))
        let revision = try XCTUnwrap(e.h.library.history(for: e.model.state.prompt!.identity).first)
        XCTAssertEqual(String(decoding: try HistoryStore(files: e.h.data).read(revision), as: UTF8.self), "Theirs")
    }

    func testTakeTheirsReloadsLatestDiskSourceAndClearsDirty() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        try e.h.files.put("Even newer", at: "a.md")
        e.ui { e.model.resolveConflict(.takeTheirs) }
        XCTAssertEqual(e.model.state.source, "Even newer")
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertEqual(e.model.state.status, .idle)
    }

    func testModifiedConflictSaveAsCopyPreservesTheirsAndAdoptsDistinctIdentity() throws {
        let e = EditorHarness()
        let original = try e.open("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal")
        e.ui { e.model.edit(e.model.state.source! + " Mine") }
        try e.change("Theirs")
        e.ui { e.model.resolveConflict(.saveAsCopy) }
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Theirs")
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
        XCTAssertNotEqual(e.model.state.prompt?.identity, original.identity)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertTrue(try e.h.files.text(at: "a 2.md").hasSuffix("Original Mine"))
    }

    func testDirtyDeletionKeepMineRecreatesAndLaterDeletionIsStillObserved() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change(nil)
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertNil(e.model.state.conflict?.stamp)
        XCTAssertEqual(e.model.state.conflict?.choices, [.keepMine, .saveAsCopy, .discard])
        e.ui { e.model.resolveConflict(.takeTheirs) }
        XCTAssertTrue(e.model.state.isDirty, "Taking a nonexistent version is not a deletion choice.")
        e.ui { e.model.resolveConflict(.keepMine) }
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        try e.h.index.apply(LibraryChangeSet(created: ["a.md"]))
        e.ui { e.model.edit(e.model.state.source! + " New") }
        try e.change(nil)
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertTrue(e.model.state.isDirty)
    }

    func testDeletionSaveAsCopyGetsNewIdentityAndDiscardCloses() throws {
        for choice in [EditorConflictChoice.saveAsCopy, .discard] {
            let e = EditorHarness()
            let original = try e.open("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal")
            e.ui { e.model.edit(e.model.state.source! + " Mine") }
            try e.change(nil)
            e.ui { e.model.resolveConflict(choice) }
            XCTAssertFalse(e.model.state.isDirty)
            XCTAssertNil(e.model.state.conflict)
            if choice == .discard {
                XCTAssertNil(e.model.state.prompt)
                XCTAssertNil(try e.h.files.stamp(at: "a.md"))
            } else {
                XCTAssertNotEqual(e.model.state.prompt?.identity, original.identity)
                XCTAssertEqual(e.model.state.lastCopy, e.model.state.prompt)
                XCTAssertTrue(e.model.state.source!.hasSuffix("Original Mine"))
            }
        }
    }

    func testRepeatedExternalWritesRefreshTheirsIncludingDeletionAndRecreation() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("First")
        try e.change("Second")
        let latestStamp = try e.h.files.stamp(at: "a.md")
        XCTAssertEqual(e.model.state.conflict?.stamp, latestStamp)
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Second")
        XCTAssertEqual(e.model.state.source, "Mine")
        try e.change("Third")
        e.h.held.releaseAll()
        try e.change(nil)
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertNil(e.model.state.conflict?.theirsSource)
        try e.change("Recreated")
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Recreated")
        XCTAssertEqual(e.model.state.conflict?.stamp, try e.h.files.stamp(at: "a.md"))
        try e.change("Again")
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Again")
    }

    func testCleanExternalModificationReloadsAndDeletionClosesWithoutConflict() throws {
        let e = EditorHarness()
        try e.open()
        try e.change("Theirs {{field}}")
        XCTAssertEqual(e.model.state.source, "Theirs {{field}}")
        XCTAssertEqual(e.model.state.preview, "Theirs {field}")
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
        try e.change(nil)
        XCTAssertNil(e.model.state.prompt)
        XCTAssertNil(e.model.state.conflict)
    }

    func testStaleSaveOpensSameConflictWithoutWatcherNotification() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.h.files.put("Theirs", at: "a.md")
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.conflict?.kind, .modified)
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Theirs")
        XCTAssertEqual(e.model.state.source, "Mine")
        XCTAssertTrue(e.model.state.isDirty)
        e.ui { e.model.resolveConflict(.keepMine) }
        XCTAssertNil(e.model.state.conflict)
        XCTAssertFalse(e.model.state.isDirty)
    }

    func testStaleSaveOnDeletionOpensDeletionConflict() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.h.files.delete(at: "a.md")
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertEqual(e.model.state.source, "Mine")
        XCTAssertNil(try e.h.files.stamp(at: "a.md"))
    }

    func testWriteAfterKeepMineWasQueuedReopensConflictRatherThanOverwriting() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        e.settle()
        e.ui { e.model.resolveConflict(.keepMine) }
        try e.h.files.put("Raced write", at: "a.md")
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Raced write")
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Raced write")
    }

    func testConflictRereadAndTakeTheirsFailuresRetainDirtyDraft() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        e.h.files.onRead = { _ in throw FileStoreError.ioFailure }
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.failure, .fileStore(.ioFailure))
        XCTAssertFalse(e.model.state.conflict?.isLoading ?? true)
        e.ui { e.model.resolveConflict(.takeTheirs) }
        e.settle()
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertEqual(e.model.state.source, "Mine")
        XCTAssertTrue(e.model.state.isDirty)
        e.h.files.onRead = nil
        e.ui { e.model.resolveConflict(.takeTheirs) }
        e.settle()
        XCTAssertEqual(e.model.state.source, "Theirs")
    }

    func testExternalChangeWhileTakingTheirsKeepsLatestConflictUsable() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        e.settle()
        e.ui { e.model.resolveConflict(.takeTheirs) }
        try e.change("Newer")
        e.settle()
        XCTAssertEqual(e.model.state.status, .idle)
        XCTAssertTrue(e.model.state.canEdit)
        XCTAssertTrue(e.model.state.canSave)
        XCTAssertEqual(e.model.state.conflict?.theirsSource, "Newer")
        e.ui { e.model.resolveConflict(.takeTheirs) }
        e.settle()
        XCTAssertEqual(e.model.state.source, "Newer")
        XCTAssertFalse(e.model.state.isDirty)
    }

    func testQueuedRereadCannotResurrectTheirsAfterDeletion() throws {
        let e = EditorHarness(queuedMain: true)
        try e.open()
        e.ui { e.model.edit("Mine") }
        try e.change("Theirs")
        e.h.main.releaseAll()
        try e.change(nil)
        e.settle()
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertNil(e.model.state.conflict?.theirsSource)
        XCTAssertEqual(e.model.state.source, "Mine")
    }
}
