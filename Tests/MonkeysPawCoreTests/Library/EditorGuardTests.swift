import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorGuardTests: XCTestCase {
    private func actions(_ e: EditorHarness) throws -> [EditorDiscardAction] {
        let other = try e.put("Other", at: "b.md")
        return [.open(other), .close, .rename, .move, .delete, .create, .librarySwitch, .quit, .revert]
    }

    func testEveryDiscardTriggerPublishesDecisionAndCancelKeepsDraft() throws {
        let e = EditorHarness()
        let original = try e.open()
        let actions = try actions(e)
        e.ui { e.model.edit("Mine") }
        for action in actions {
            var results: [EditorGuardResult] = []
            e.ui { e.model.request(action) { results.append($0); XCTAssertTrue(e.h.marker.isUI) } }
            XCTAssertEqual(e.model.state.pendingDecision?.action, action)
            XCTAssertTrue(results.isEmpty)
            try e.decide(.cancel)
            XCTAssertEqual(results, [.cancelled])
            XCTAssertEqual(e.model.state.prompt, original)
            XCTAssertEqual(e.model.state.source, "Mine")
            XCTAssertTrue(e.model.state.isDirty)
        }
    }

    func testEveryDiscardTriggerCanSaveBeforeProceeding() throws {
        for action in try actions(EditorHarness()) {
            let e = EditorHarness(heldWork: true)
            try e.open()
            try e.put("Other", at: "b.md")
            var results: [EditorGuardResult] = []
            e.ui { e.model.edit("Mine"); e.model.request(action) { results.append($0) } }
            try e.decide(.save)
            XCTAssertEqual(e.model.state.status, .saving)
            XCTAssertTrue(results.isEmpty)
            e.settle()
            XCTAssertEqual(results, [.allowed], "Action \(action) failed its save guard.")
            XCTAssertFalse(e.model.state.isDirty)
            XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Mine"))
            XCTAssertNil(e.model.state.pendingDecision)
        }
    }

    func testEveryDiscardTriggerCanDiscardBeforeProceeding() throws {
        for action in try actions(EditorHarness()) {
            let e = EditorHarness()
            let original = try e.open()
            try e.put("Other", at: "b.md")
            var results: [EditorGuardResult] = []
            e.ui { e.model.edit("Mine"); e.model.request(action) { results.append($0) } }
            try e.decide(.discard)
            XCTAssertEqual(results, [.allowed])
            XCTAssertFalse(e.model.state.isDirty)
            XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
            switch action {
            case .rename, .move, .delete, .create, .quit, .revert:
                XCTAssertEqual(e.model.state.prompt, original)
                XCTAssertEqual(e.model.state.source, "Original")
            case .open(let selection):
                XCTAssertEqual(e.model.state.prompt, selection)
                XCTAssertEqual(e.model.state.source, "Other")
            case .close, .librarySwitch:
                XCTAssertNil(e.model.state.prompt)
                XCTAssertNil(e.model.state.source)
            }
            XCTAssertNil(e.model.state.pendingDecision)
        }
    }

    func testOpenCloseAndRevertUseTheSameGuard() throws {
        let e = EditorHarness()
        try e.open()
        let other = try e.put("Other", at: "b.md")
        e.ui { e.model.edit("Mine"); e.model.open(other) }
        XCTAssertEqual(e.model.state.pendingDecision?.action, .open(other))
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a.md"))
        try e.decide(.discard)
        XCTAssertEqual(e.model.state.source, "Other")
        e.ui { e.model.edit("Edited other"); e.model.revert() }
        XCTAssertEqual(e.model.state.pendingDecision?.action, .revert)
        try e.decide(.discard)
        XCTAssertEqual(e.model.state.source, "Other")
        e.ui { e.model.edit("Again"); e.model.close() }
        XCTAssertEqual(e.model.state.pendingDecision?.action, .close)
        try e.decide(.cancel)
        XCTAssertEqual(e.model.state.source, "Again")
        e.ui { e.model.close() }
        try e.decide(.discard)
        XCTAssertNil(e.model.state.prompt)
        XCTAssertNil(e.model.state.source)
    }

    func testEveryTriggerWaitsForSaveInFlightAndSuccessfulSaveAllowsIt() throws {
        for action in try actions(EditorHarness()) {
            let e = EditorHarness(heldWork: true)
            try e.open()
            try e.put("Other", at: "b.md")
            var results: [EditorGuardResult] = []
            e.ui { e.model.edit("Mine"); e.model.save(); e.model.request(action) { results.append($0) } }
            XCTAssertEqual(e.model.state.queuedActions, [action])
            XCTAssertNil(e.model.state.pendingDecision)
            XCTAssertTrue(results.isEmpty)
            e.settle()
            XCTAssertEqual(results, [.allowed])
            XCTAssertFalse(e.model.state.isDirty)
        }
    }

    func testFailedSaveInFlightPromptsQueuedActionWithoutDiscardingEdits() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        var results: [EditorGuardResult] = []
        e.h.files.failNextWrite = true
        e.ui { e.model.edit("Mine"); e.model.save(); e.model.request(.quit) { results.append($0) } }
        e.settle()
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertEqual(e.model.state.pendingDecision?.action, .quit)
        XCTAssertTrue(results.isEmpty)
        try e.decide(.cancel)
        XCTAssertEqual(results, [.cancelled])
        XCTAssertEqual(e.model.state.source, "Mine")
    }

    func testFailedDecisionSaveRetainsDecisionForRetryDiscardOrCancel() throws {
        let e = EditorHarness()
        try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.edit("Mine"); e.model.request(.close) { results.append($0) } }
        let decision = try XCTUnwrap(e.model.state.pendingDecision)
        e.h.files.failNextWrite = true
        try e.decide(.save)
        XCTAssertEqual(e.model.state.pendingDecision, decision)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(e.model.state.source, "Mine")
        try e.decide(.save)
        XCTAssertEqual(results, [.allowed])
        XCTAssertNil(e.model.state.prompt)
    }

    func testNewEditsDuringDecisionSaveRequireAnotherDecision() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.edit("First"); e.model.request(.quit) { results.append($0) } }
        let decision = try XCTUnwrap(e.model.state.pendingDecision)
        try e.decide(.save)
        e.ui { e.model.edit("Newer"); e.model.resolveDecision(.discard, id: decision.id) }
        XCTAssertEqual(e.model.state.source, "Newer", "A saving decision cannot discard its draft.")
        e.settle()
        XCTAssertEqual(e.model.state.pendingDecision, decision)
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertTrue(results.isEmpty)
        try e.decide(.save)
        e.settle()
        XCTAssertEqual(results, [.allowed])
        XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Newer"))
    }

    func testDecisionSaveConflictWaitsUntilConflictIsResolved() throws {
        for choice in [EditorConflictChoice.keepMine, .takeTheirs, .saveAsCopy, .discard] {
            let e = EditorHarness()
            try e.open()
            var results: [EditorGuardResult] = []
            e.ui { e.model.edit("Mine"); e.model.request(.quit) { results.append($0) } }
            if choice == .discard { try e.h.files.delete(at: "a.md") }
            else { try e.h.files.put("Theirs", at: "a.md") }
            try e.decide(.save)
            XCTAssertNotNil(e.model.state.conflict)
            XCTAssertNotNil(e.model.state.pendingDecision)
            XCTAssertTrue(results.isEmpty)
            e.ui { e.model.resolveConflict(choice) }
            XCTAssertEqual(results, [.allowed], "Conflict choice \(choice) failed to resume the guard.")
            XCTAssertNil(e.model.state.pendingDecision)
        }
    }

    func testQueuedRequestsKeepFIFOAndOldDialogTokenCannotResolveNextRequest() throws {
        let e = EditorHarness()
        try e.open()
        var completed: [String] = []
        e.ui {
            e.model.edit("Mine")
            e.model.request(.rename) { _ in completed.append("rename") }
            e.model.request(.move) { _ in completed.append("move") }
        }
        let first = try XCTUnwrap(e.model.state.pendingDecision)
        XCTAssertEqual(e.model.state.queuedActions, [.move])
        try e.decide(.cancel)
        let second = try XCTUnwrap(e.model.state.pendingDecision)
        XCTAssertEqual(completed, ["rename"])
        XCTAssertEqual(second.action, .move)
        e.ui { e.model.resolveDecision(.discard, id: first.id) }
        XCTAssertEqual(e.model.state.pendingDecision, second)
        try e.decide(.discard)
        XCTAssertEqual(completed, ["rename", "move"])
    }

    func testQueuedMainRechecksNewEditsBeforeApprovingCleanOrDiscardedRequest() throws {
        let e = EditorHarness(queuedMain: true)
        try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.request(.quit) { results.append($0); XCTAssertTrue(e.h.marker.isUI) }; e.model.edit("Mine") }
        e.settle()
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(e.model.state.pendingDecision)
        try e.decide(.discard)
        e.ui { e.model.edit("After discard") }
        e.settle()
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(e.model.state.pendingDecision)
        try e.decide(.cancel)
        e.settle()
        XCTAssertEqual(results, [.cancelled])
    }

    func testLibrarySwitchRetiresSessionAndPreventsFurtherIntents() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        var results: [EditorGuardResult] = []
        e.ui { e.model.edit("Mine"); e.model.request(.librarySwitch) { results.append($0) } }
        try e.decide(.discard)
        XCTAssertEqual(results, [.allowed])
        XCTAssertNil(e.model.state.prompt)
        let retired = e.model.state
        try e.change("New root old file")
        e.ui { e.model.edit("Late"); e.model.save() }
        e.settle()
        XCTAssertEqual(e.model.state, retired)
        e.ui { e.model.request(.quit) { results.append($0); XCTAssertTrue(e.h.marker.isUI) } }
        XCTAssertEqual(results, [.allowed, .inactive])
    }
}
