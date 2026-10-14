import XCTest
@testable import MonkeysPawCore

final class RepeatModelTests: XCTestCase {
    func testForgetDuringPendingLoadReturnsModelToIdle() throws {
        let h = try RepeatHarness(heldWork: true)
        h.model.load()
        XCTAssertEqual(h.model.state, .loading)
        XCTAssertEqual(h.picker.forgetAllValues(), .forgotten)
        h.held.releaseAll()
        XCTAssertEqual(h.model.state, .idle)
        XCTAssertEqual(h.model.availability, .nothingToRepeat)
    }

    func testNothingToRepeatAndPublicationOnInjectedMainThread() throws {
        let h = try RepeatHarness()
        h.flow.delivery.main.mode = .deferred
        var changes = 0
        h.model.onChange = { changes += 1 }
        h.model.load()
        XCTAssertEqual(h.model.state, .loading)
        h.flow.delivery.main.drain()
        XCTAssertEqual(h.model.state, .idle)
        XCTAssertEqual(h.model.availability, .nothingToRepeat)
        h.model.repeatLast()
        h.flow.delivery.main.drain()
        XCTAssertEqual(h.model.result, .nothingToRepeat)
        XCTAssertGreaterThan(changes, 0)
    }

    func testRepeatDoesNotTouchHiddenPickerQueryOrDraft() throws {
        let h = try RepeatHarness()
        _ = try h.put("---\ntitle: Explain\n---\n{{field}}")
        try h.deliver(values: ["field": "delivered"])
        try h.open()
        h.picker.setQuery("Expl")
        h.picker.use(mode: .paste(.standard))
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("hidden draft", name: "field")
        h.picker.dismiss()
        h.model.repeatLast()
        h.flow.settle()
        XCTAssertEqual(h.model.result, .delivered(.pasted(.cgEvent), []))
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(h.picker.query, "Expl")
        h.picker.open()
        h.picker.use(mode: .paste(.standard))
        XCTAssertEqual(h.picker.fillModel?.values, ["field": "hidden draft"])
    }

    func testBusyModelDropsFloodAndDeactivationSuppressesLateReply() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("body")
        try h.deliver()
        h.model.repeatLast()
        h.model.repeatLast()
        XCTAssertEqual(h.model.state, .repeating)
        XCTAssertEqual(h.held.pending.count, 1)
        h.model.deactivate()
        h.held.releaseAll()
        h.flow.settle()
        XCTAssertEqual(h.model.state, .inactive)
        XCTAssertNil(h.model.result)
        XCTAssertFalse(h.service.isBusy)
        XCTAssertNotNil(try h.store.load())
    }

    func testRetirementDuringHeldLoadDoesNotPublishOrRecreateRecord() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("body")
        try h.deliver()
        h.model.load()
        try h.service.retire()
        h.model.deactivate()
        h.held.releaseAll()
        XCTAssertEqual(h.model.state, .inactive)
        XCTAssertEqual(h.model.availability, .unavailable(.inactive))
        XCTAssertNil(try h.store.load())
    }
}
