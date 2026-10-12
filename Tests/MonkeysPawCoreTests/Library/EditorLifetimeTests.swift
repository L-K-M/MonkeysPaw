import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorLifetimeTests: XCTestCase {
    func testInlineAndQueuedMainDeliverStateAndGuardCallbacksOnUIThread() throws {
        for queued in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queued)
            var snapshots: [EditorState] = []
            var changes = 0
            e.model.onChange = { changes += 1; XCTAssertTrue(e.h.marker.isUI) }
            e.model.addObserver { snapshots.append($0); XCTAssertTrue(e.h.marker.isUI) }
            try e.open()
            XCTAssertEqual(e.model.state.source, "Original")
            XCTAssertFalse(snapshots.isEmpty)
            e.ui { e.model.edit("Mine"); e.model.save() }
            XCTAssertEqual(e.model.state.status, .saving)
            e.h.held.releaseAll()
            if queued { XCTAssertEqual(e.model.state.status, .saving) }
            e.settle()
            XCTAssertEqual(e.model.state.status, .saved)
            var results: [EditorGuardResult] = []
            e.ui { e.model.request(.quit) { results.append($0); XCTAssertTrue(e.h.marker.isUI) } }
            if queued { XCTAssertTrue(results.isEmpty) }
            e.settle()
            XCTAssertEqual(results, [.allowed])
            XCTAssertGreaterThan(changes, 1)
        }
    }

    func testSwitchingPromptRetiresQueuedOldLoadReply() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let first = try e.put("First")
        let second = try e.put("Second", at: "b.md")
        e.ui { e.model.open(first) }
        e.h.main.releaseAll()
        e.h.held.releaseAll()
        e.ui { e.model.open(second) }
        e.settle()
        XCTAssertEqual(e.model.state.prompt, second)
        XCTAssertEqual(e.model.state.source, "Second")
        try e.change("Changed first")
        e.settle()
        XCTAssertEqual(e.model.state.source, "Second")
        XCTAssertNil(e.model.state.conflict)
    }

    func testCloseRetiresQueuedLoadBeforeItStarts() throws {
        let e = EditorHarness(heldWork: true)
        let selection = try e.put("Original")
        e.ui { e.model.open(selection); e.model.close() }
        let accesses = e.h.files.accessCount
        e.settle()
        XCTAssertEqual(e.h.files.accessCount, accesses)
        XCTAssertNil(e.model.state.prompt)
        XCTAssertEqual(e.model.state.status, .idle)
    }

    func testDeactivationDropsWorkerAndUIRepliesWithoutRetainingModel() throws {
        for workerStarted in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            try e.open()
            e.ui { e.model.edit("Mine"); e.model.save() }
            if workerStarted { e.h.held.releaseAll() }
            let retired = e.model.state
            var callbacks = 0
            e.model.onChange = { callbacks += 1 }
            e.ui { e.model.deactivate() }
            e.settle()
            XCTAssertEqual(e.model.state, retired)
            XCTAssertEqual(callbacks, 0)
            if workerStarted { XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Mine")) }
            else { XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original") }
        }
    }

    func testRetiredLibraryServiceDropsRepliesAlreadyOnMainThread() throws {
        let e = EditorHarness(queuedMain: true)
        try e.open()
        e.ui { e.model.edit("Mine"); e.model.save() }
        let before = e.model.state
        e.ui { e.model.deactivate(); e.h.editor.deactivate() }
        e.settle()
        XCTAssertEqual(e.model.state, before)
        try e.change("External")
        e.settle()
        XCTAssertEqual(e.model.state, before)
    }

    func testModelReleaseCancelsQueuedBackgroundLoadAndSave() throws {
        for save in [false, true] {
            let h = PromptEditingHarness(heldWork: true)
            try h.files.put("Original", at: "a.md")
            try h.index.rebuild()
            let entry = try h.library.load(at: "a.md")
            var model: EditorModel? = EditorModel(editing: h.editor, clock: h.clock,
                timeZone: { TimeZone(secondsFromGMT: 0)! }, main: h.main)
            weak var released = model
            h.marker.ui { model?.open(LibraryPromptSelection(identity: entry.identity, relativePath: "a.md")) }
            if save {
                h.held.releaseAll()
                h.marker.ui { model?.edit("Mine"); model?.save() }
            }
            let accesses = h.files.accessCount
            model = nil
            XCTAssertNil(released)
            h.held.releaseAll()
            h.main.releaseAll()
            XCTAssertEqual(h.files.accessCount, accesses)
            XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
        }
    }

    func testModelReleaseCancelsRepliesAlreadyQueuedOnMainThread() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        try h.index.rebuild()
        let entry = try h.library.load(at: "a.md")
        var model: EditorModel? = EditorModel(editing: h.editor, clock: h.clock,
            timeZone: { TimeZone(secondsFromGMT: 0)! }, main: h.main)
        h.marker.ui { model?.open(LibraryPromptSelection(identity: entry.identity, relativePath: "a.md")) }
        h.main.isHeld = true
        model?.onChange = { XCTFail("Released model notified a view.") }
        h.marker.ui { model?.edit("Mine"); model?.save() }
        weak var released = model
        model = nil
        XCTAssertNil(released)
        h.main.releaseAll()
    }

    func testObserversAreRemovableAndReentrantIntentsPublishLatestSnapshot() throws {
        let e = EditorHarness()
        try e.open()
        var snapshots: [String] = []
        let removed = e.model.addObserver { _ in XCTFail("Removed subscriber.") }
        e.model.removeObserver(removed)
        e.model.onChange = {
            if e.model.state.source == "First" { e.model.edit("Second") }
        }
        e.model.addObserver { state in snapshots.append(state.source ?? ""); XCTAssertTrue(e.h.marker.isUI) }
        e.ui { e.model.edit("First") }
        XCTAssertEqual(snapshots, ["Second"])
        XCTAssertEqual(e.model.state.source, "Second")
    }
}
