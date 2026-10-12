import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorRebaseTests: XCTestCase {
    func testPostCommitSaveReplacementKeepsDraftAndGuardPending() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            try e.open()
            var results: [EditorGuardResult] = []
            e.ui { e.model.edit("Mine"); e.model.request(.quit) { results.append($0) } }
            e.settle()
            let decision = try XCTUnwrap(e.model.state.pendingDecision)
            replaceAfterWrite(e, at: "a.md")

            try e.decide(.save)
            e.settle()

            XCTAssertEqual(e.model.state.source, "Mine")
            XCTAssertTrue(e.model.state.isDirty)
            XCTAssertEqual(e.model.state.conflict?.theirsSource, "External replacement")
            XCTAssertEqual(e.model.state.conflict?.stamp, try e.h.files.stamp(at: "a.md"))
            XCTAssertEqual(e.model.state.pendingDecision, decision)
            XCTAssertTrue(results.isEmpty)
            e.ui { e.model.resolveConflict(.takeTheirs) }
            e.settle()
            XCTAssertEqual(e.model.state.source, "External replacement")
            XCTAssertEqual(results, [.allowed])
        }
    }

    func testPostCommitCopyReplacementRetainsOriginalAndNewerDraft() throws {
        for newerDraft in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            let original = try e.open()
            let stamp = e.model.state.stamp
            replaceAfterWrite(e, at: "a 2.md")
            e.ui {
                e.model.edit("Copy draft")
                e.model.saveAsCopy()
                if newerDraft { e.model.edit("Newer draft") }
            }
            e.settle()

            XCTAssertEqual(e.model.state.status, .failed(.editing(.library(.conflict))))
            XCTAssertEqual(e.model.state.prompt, original)
            XCTAssertEqual(e.model.state.stamp, stamp)
            XCTAssertEqual(e.model.state.source, newerDraft ? "Newer draft" : "Copy draft")
            XCTAssertTrue(e.model.state.isDirty)
            XCTAssertNil(e.model.state.lastCopy)
            XCTAssertNil(e.model.state.conflict, "A copy's external stamp does not describe the original path.")
            XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
            XCTAssertEqual(try e.h.files.text(at: "a 2.md"), "External replacement")

            e.ui { e.model.saveAsCopy() }
            e.settle()
            XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 3.md"))
            XCTAssertFalse(e.model.state.isDirty)
            XCTAssertEqual(try e.h.files.text(at: "a 2.md"), "External replacement")
        }
    }

    func testPostCommitCopyReplacementPreservesOriginalConflictAndGuard() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let original = try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.edit("Mine"); e.model.request(.quit) { results.append($0) } }
        e.settle()
        let decision = try XCTUnwrap(e.model.state.pendingDecision)
        try e.h.files.put("Theirs", at: "a.md")
        try e.decide(.save)
        e.settle()
        let conflict = try XCTUnwrap(e.model.state.conflict)
        replaceAfterWrite(e, at: "a 2.md")

        e.ui { e.model.resolveConflict(.saveAsCopy) }
        e.settle()

        XCTAssertEqual(e.model.state.status, .failed(.editing(.library(.conflict))))
        XCTAssertEqual(e.model.state.prompt, original)
        XCTAssertEqual(e.model.state.source, "Mine")
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.conflict, conflict)
        XCTAssertEqual(e.model.state.pendingDecision, decision)
        XCTAssertNil(e.model.state.lastCopy)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Theirs")
        XCTAssertEqual(try e.h.files.text(at: "a 2.md"), "External replacement")
        e.ui { e.model.resolveConflict(.takeTheirs) }
        e.settle()
        XCTAssertEqual(results, [.allowed])
        XCTAssertEqual(e.model.state.source, "Theirs")
    }

    func testCommittedSessionAfterDeactivationCompletesWithoutWork() {
        let h = PromptEditingHarness(heldWork: true)
        h.main.isHeld = true
        let entry = LibraryEntry(path: "copy.md", document: PromptCodec.parse("Copy", filename: "copy.md"),
                                 stamp: FileStamp("committed-copy"))
        var replies = 0
        h.marker.ui {
            h.editor.deactivate()
            let session = h.editor.beginSession(forCommitted: entry) { _ in XCTFail("Inactive session observed a change.") }
            h.editor.load(session: session) {
                guard case .failed(.library(.operationFailed)) = $0 else { return XCTFail("Expected inactive load failure.") }
                XCTAssertTrue(h.marker.isUI)
                replies += 1
            }
            let completed: (PromptSaveOutcome) -> Void = {
                guard case .failed(.library(.operationFailed)) = $0 else { return XCTFail("Expected inactive write failure.") }
                XCTAssertTrue(h.marker.isUI)
                replies += 1
            }
            h.editor.save("Mine", session: session, expectedStamp: entry.stamp, completion: completed)
            h.editor.createCopy("Mine", near: "copy.md", session: session, completion: completed)
        }
        XCTAssertEqual(replies, 3)
        XCTAssertTrue(h.held.pending.isEmpty)
        XCTAssertTrue(h.main.pending.isEmpty)
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, 0)
    }

    private func replaceAfterWrite(_ e: EditorHarness, at path: String) {
        e.h.files.onWrite = { written in
            guard written == path else { return }
            e.h.files.onWrite = nil
            do { try e.h.files.put("External replacement", at: path) }
            catch { XCTFail("Could not replace the committed bytes.") }
        }
    }
}
