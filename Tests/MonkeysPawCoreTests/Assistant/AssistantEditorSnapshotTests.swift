import XCTest
@testable import MonkeysPawCore

final class AssistantEditorSnapshotTests: XCTestCase {
    func testSnapshotIsBusyForQueuedPendingAndResolvingGuardDecisions() throws {
        let e = EditorHarness(queuedMain: true)
        try e.open()
        XCTAssertEqual(e.model.assistantSnapshot?.availability, .available)
        e.ui { e.model.edit("Unsaved"); e.model.request(.quit) }
        XCTAssertNil(e.model.state.pendingDecision)
        XCTAssertEqual(e.model.state.queuedActions, [.quit])
        XCTAssertEqual(e.model.assistantSnapshot?.availability, .busy)
        e.settle()
        XCTAssertNotNil(e.model.state.pendingDecision)
        XCTAssertEqual(e.model.state.status, .idle)
        XCTAssertEqual(e.model.assistantSnapshot?.availability, .busy)
        try e.decide(.cancel)
        XCTAssertNil(e.model.state.pendingDecision)
        XCTAssertEqual(e.model.assistantSnapshot?.availability, .busy)
        e.settle()
        XCTAssertEqual(e.model.assistantSnapshot?.availability, .available)
    }
}
