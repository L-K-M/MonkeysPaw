import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorBoundaryTests: XCTestCase {
    func testAdoptedCopyImmediatelyObservesDirtyModificationAndDeletion() throws {
        for deletion in [false, true] {
            let e = EditorHarness(heldWork: true)
            try e.open()
            e.ui { e.model.edit("Copy"); e.model.saveAsCopy() }
            e.h.held.releaseNext()
            XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
            e.ui { e.model.edit(e.model.state.source! + " New edit") }
            try e.change(deletion ? nil : "Theirs", at: "a 2.md")
            XCTAssertEqual(e.model.state.conflict?.kind, deletion ? .deleted : .modified,
                "Adopting a committed copy must register its known stamp before another worker runs.")
            e.settle()
            if !deletion { XCTAssertEqual(e.model.state.conflict?.theirsSource, "Theirs") }
            XCTAssertTrue(e.model.state.source!.hasSuffix("Copy New edit"))
        }
    }

    func testAdoptedCopyCleanExternalChangeReloadsSilently() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("Copy"); e.model.saveAsCopy() }
        try e.change("Theirs", at: "a 2.md")
        XCTAssertEqual(e.model.state.source, "Theirs")
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
    }

    func testCopyAdoptionReconcilesPublicationBeforeQueuedReplyWithoutLosingNewDraft() throws {
        for dirty in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            try e.open()
            e.ui { e.model.edit("Copy"); e.model.saveAsCopy() }
            e.h.held.releaseNext()
            // The write is committed, but no editor session watches the copy
            // yet. The publication predates delivery of the copy's UI reply.
            try e.change("Theirs before adoption", at: "a 2.md")
            e.h.main.releaseAll()
            XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
            if dirty { e.ui { e.model.edit("New draft after adoption") } }
            e.settle()
            if dirty {
                XCTAssertEqual(e.model.state.source, "New draft after adoption")
                XCTAssertTrue(e.model.state.isDirty)
                XCTAssertEqual(e.model.state.conflict?.theirsSource, "Theirs before adoption")
            } else {
                XCTAssertEqual(e.model.state.source, "Theirs before adoption")
                XCTAssertFalse(e.model.state.isDirty)
                XCTAssertNil(e.model.state.conflict)
            }
        }
    }

    func testAdoptedCopyOwnWatcherPublicationStaysQuietWithNewerDraft() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Copy"); e.model.saveAsCopy() }
        e.h.held.releaseNext()
        e.ui { e.model.edit(e.model.state.source! + " New edit") }
        try e.h.index.apply(LibraryChangeSet(created: ["a 2.md"]))
        e.settle()
        XCTAssertNil(e.model.state.conflict)
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertTrue(e.model.state.source!.hasSuffix("Copy New edit"))
    }

    func testReentrantOpenCannotRunBeforeResolvingEarlierFileCommandGuard() throws {
        let e = EditorHarness()
        let original = try e.open()
        let next = try e.put("Next", at: "b.md")
        var commandPrompt: LibraryPromptSelection?
        e.ui {
            e.model.edit("Mine")
            e.model.request(.rename) { _ in commandPrompt = e.model.state.prompt }
        }
        var enqueued = false
        e.model.onChange = {
            guard !enqueued, e.model.state.pendingDecision == nil,
                  !e.model.state.isDirty, e.model.state.prompt == original else { return }
            enqueued = true
            e.model.open(next)
        }
        try e.decide(.discard)
        XCTAssertEqual(commandPrompt, original, "The old guard must resolve before a reentrant navigation.")
        XCTAssertEqual(e.model.state.prompt, next)
        XCTAssertEqual(e.model.state.source, "Next")
    }

    func testReentrantOpenWaitsUntilEarlierCloseHasFinished() throws {
        let e = EditorHarness()
        let original = try e.open()
        let next = try e.put("Next", at: "b.md")
        e.ui { e.model.edit("Mine"); e.model.close() }
        var enqueued = false
        e.model.onChange = {
            guard !enqueued, e.model.state.pendingDecision == nil,
                  !e.model.state.isDirty, e.model.state.prompt == original else { return }
            enqueued = true
            e.model.open(next)
        }
        try e.decide(.discard)
        XCTAssertEqual(e.model.state.prompt, next)
        XCTAssertEqual(e.model.state.source, "Next")
    }

    func testQueuedGuardApprovalSurvivesSilentDeletionAfterTakingTheirs() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.edit("Mine"); e.model.request(.quit) { results.append($0) } }
        e.settle()
        try e.h.files.put("Theirs", at: "a.md")
        try e.decide(.save)
        e.settle()
        XCTAssertNotNil(e.model.state.conflict)
        e.ui { e.model.resolveConflict(.takeTheirs) }
        e.h.held.releaseNext()
        try e.change(nil)
        e.settle()
        XCTAssertNil(e.model.state.prompt)
        XCTAssertEqual(results, [.allowed], "A clean deletion cannot strand a pending global quit.")
    }
}
