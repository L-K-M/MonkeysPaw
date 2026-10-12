import Foundation
import XCTest
@testable import MonkeysPawCore

final class HistoryCommandLifetimeTests: XCTestCase {
    func testModelDeactivationCompletesEveryRunningCommandExactlyOnceAtEachQueueBoundary() throws {
        for queuedMain in [false, true] {
            for boundary in 0...2 {
                for command in HistoryTestCommand.allCases {
                    let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                    let selection = try e.open(historyCommandSource)
                    let revision = try historySnapshot(e.h, identity: selection.identity)
                    var replies: [PromptCommandOutcome] = []
                    e.ui { command.run(e.model, revision: revision) {
                        replies.append($0)
                        XCTAssertTrue(e.h.marker.isUI)
                    } }
                    e.h.main.releaseAll()
                    if boundary > 0 {
                        e.h.main.isHeld = true
                        e.h.held.releaseNext()
                        if boundary == 2 {
                            // Release the index notification and service reply;
                            // leave the model's own reply hop queued.
                            e.h.main.releaseNext()
                            e.h.main.releaseNext()
                        }
                    }
                    XCTAssertEqual(e.model.state.status, .commandRunning)
                    let retired = e.model.state
                    let accesses = e.h.files.accessCount + e.h.data.accessCount
                    e.ui { e.model.deactivate(); e.model.deactivate() }
                    e.settle()
                    XCTAssertEqual(replies.count, 1, "command: \(command), boundary: \(boundary), queuedMain: \(queuedMain)")
                    guard case .inactive = replies.first else {
                        XCTFail("Retired model must complete its command with inactive.")
                        continue
                    }
                    XCTAssertEqual(e.model.state, retired)
                    XCTAssertEqual(e.h.files.accessCount + e.h.data.accessCount, accesses)
                }
            }
        }
    }

    func testRetiringSessionDropsEveryQueuedCommandBeforeFileWork() throws {
        for command in HistoryTestCommand.allCases {
            let h = PromptEditingHarness(heldWork: true)
            let (session, loaded) = try h.open(historyCommandSource)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            let accesses = h.files.accessCount + h.data.accessCount
            var completed = false
            h.marker.ui {
                command.run(h.editor, session: session, stamp: loaded.stamp, revision: revision) { _ in completed = true }
                h.editor.retire(session)
            }
            h.held.releaseAll()
            h.main.releaseAll()
            XCTAssertFalse(completed)
            XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        }
    }

    func testRetiringSessionDropsRepliesFromCommittedCommands() throws {
        for command in HistoryTestCommand.allCases {
            let h = PromptEditingHarness(heldWork: true)
            let (session, loaded) = try h.open(historyCommandSource)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            h.main.isHeld = true
            var completed = false
            h.marker.ui { command.run(h.editor, session: session, stamp: loaded.stamp, revision: revision) { _ in completed = true } }
            h.held.releaseAll()
            h.marker.ui { h.editor.retire(session) }
            h.main.releaseAll()
            XCTAssertFalse(completed)
            if command == .delete { XCTAssertNil(try h.files.stamp(at: "a.md")) }
            else { XCTAssertNotNil(try h.files.stamp(at: command.destination)) }
        }
    }

    func testServiceDeactivationCompletesNewTokensWithFailureWithoutWork() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (oldSession, loaded) = try h.open(historyCommandSource)
        let revision = try historySnapshot(h, identity: loaded.entry.identity)
        h.editor.deactivate()
        let session = h.editor.beginSession(at: "a.md")
        let accesses = h.files.accessCount + h.data.accessCount
        for command in HistoryTestCommand.allCases {
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .failed(let failure) = outcome else { return XCTFail("Expected inactive service failure.") }
            XCTAssertEqual(failure, .library(.operationFailed))
        }
        var history: PromptHistoryOutcome?
        h.marker.ui { h.editor.history(for: loaded.entry.identity, session: session) { history = $0 } }
        guard case .failed(let failure) = history else { return XCTFail("Expected inactive history failure.") }
        XCTAssertEqual(failure, .library(.operationFailed))
        h.marker.ui { h.editor.delete(session: oldSession, expectedStamp: loaded.stamp) { _ in XCTFail("Retired token replied.") } }
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        XCTAssertTrue(h.held.pending.isEmpty)
    }

    func testQueuedCommandAndHistoryDoNotRetainEditor() throws {
        let h = PromptEditingHarness(heldWork: true)
        try h.files.put(historyCommandSource, at: "a.md")
        try h.index.rebuild()
        let entry = try h.library.load(at: "a.md")
        let selection = LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath("a.md"))
        var model: EditorModel? = EditorModel(editing: h.editor, clock: h.clock, timeZone: { .gmt }, main: h.main)
        h.marker.ui { model?.open(selection) }
        h.held.releaseAll()
        var replies: [PromptCommandOutcome] = []
        h.marker.ui { model?.loadHistory(); model?.rename(to: "renamed.md") {
            replies.append($0)
            XCTAssertTrue(h.marker.isUI)
        } }
        weak var released = model
        model = nil
        XCTAssertNil(released)
        let accesses = h.files.accessCount + h.data.accessCount
        h.held.releaseAll(); h.main.releaseAll()
        XCTAssertEqual(replies.count, 1)
        guard case .inactive = replies.first else { return XCTFail("Released model must complete its command caller.") }
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
    }

    func testReleasedModelCompletesPendingAndQueuedCommandCallersExactlyOnce() throws {
        for queuedMain in [false, true] {
            let h = PromptEditingHarness(heldWork: true)
            try h.files.put(historyCommandSource, at: "a.md")
            try h.index.rebuild()
            let entry = try h.library.load(at: "a.md")
            var model: EditorModel? = EditorModel(editing: h.editor, clock: h.clock, timeZone: { .gmt }, main: h.main)
            h.marker.ui { model?.open(LibraryPromptSelection(identity: entry.identity, relativePath: "a.md")) }
            h.held.releaseAll()
            h.main.isHeld = queuedMain
            var replies: [PromptCommandOutcome] = []
            let completion: (PromptCommandOutcome) -> Void = { replies.append($0); XCTAssertTrue(h.marker.isUI) }
            h.marker.ui { model?.edit("Mine"); model?.delete(completion: completion)
                model?.rename(to: "renamed.md", completion: completion) }
            h.main.releaseAll()
            let accesses = h.files.accessCount + h.data.accessCount
            weak var released = model
            model = nil
            XCTAssertNil(released)
            h.held.releaseAll()
            h.main.releaseAll()
            XCTAssertEqual(replies.count, 2)
            for reply in replies {
                guard case .inactive = reply else { return XCTFail("Released guard must complete its caller with inactive.") }
            }
            XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        }
    }

    func testAlreadyQueuedExternalDeletionCannotRetireCommandBeforeItsTypedReply() throws {
        let e = EditorHarness(heldWork: true)
        try e.open(historyCommandSource)
        e.h.main.isHeld = true
        try e.change(nil)
        // The service has delivered the notification, but the editor's UI hop
        // is still queued. New UI intents may run inline before that idle hop.
        e.h.main.releaseNext()
        e.h.main.isHeld = false
        var result: PromptCommandOutcome?
        e.ui { e.model.rename(to: "renamed.md") { result = $0 } }
        XCTAssertEqual(e.model.state.status, .commandRunning)
        e.h.main.releaseAll()
        e.settle()
        guard case .missing = result else { return XCTFail("A pending external hop stranded the command reply.") }
        XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
        XCTAssertEqual(e.model.state.source, historyCommandSource)
    }
}
