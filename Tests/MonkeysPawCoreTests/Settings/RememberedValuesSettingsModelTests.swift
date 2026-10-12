import Foundation
import XCTest
@testable import MonkeysPawCore

final class RememberedValuesSettingsModelTests: XCTestCase {
    func testConfirmationIsRequiredAndCancelDoesNotCallControl() {
        let h = RememberedValuesSettingsHarness()
        let model = h.makeModel()
        var changes = 0
        model.onChange = { changes += 1 }
        XCTAssertEqual(model.state.confirmation, .none)
        XCTAssertNil(model.state.lastOutcome)
        XCTAssertNil(model.state.message)

        model.confirmForgetAll()
        model.cancelForgetAll()
        XCTAssertEqual(changes, 0)
        model.requestForgetAll()
        model.requestForgetAll()
        XCTAssertEqual(model.state.confirmation, .forgetAll)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(h.control.calls, 0)

        model.cancelForgetAll()
        model.cancelForgetAll()
        model.confirmForgetAll()
        XCTAssertEqual(model.state.confirmation, .none)
        XCTAssertNil(model.state.lastOutcome)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(h.control.calls, 0)
    }

    func testSuccessRefusalAndTypedFailuresPublishOneCompletedState() {
        let h = RememberedValuesSettingsHarness()
        let model = h.makeModel()
        var states: [RememberedValuesSettingsModel.State] = []
        model.onChange = { [weak model] in
            if let state = model?.state { states.append(state) }
        }

        for outcome in outcomes {
            h.control.outcome = outcome
            let calls = h.control.calls
            model.requestForgetAll()
            XCTAssertEqual(model.state.confirmation, .forgetAll)
            XCTAssertNil(model.state.lastOutcome, "A new request clears the previous message")
            model.confirmForgetAll()

            XCTAssertEqual(h.control.calls, calls + 1)
            XCTAssertEqual(model.state.confirmation, .none)
            XCTAssertEqual(model.state.lastOutcome, outcome)
            XCTAssertEqual(model.state.message, RememberedValuesStrings.message(for: outcome))
            XCTAssertEqual(states.count, 2)
            XCTAssertEqual(states[0].confirmation, .forgetAll)
            XCTAssertEqual(states[1], model.state)

            model.confirmForgetAll()
            model.cancelForgetAll()
            XCTAssertEqual(h.control.calls, calls + 1)
            XCTAssertEqual(states.count, 2, "An already-completed confirmation is a no-op")
            states = []
        }
    }

    func testRepeatedOutcomesStillRequireConfirmationAndOnlyRealChangesNotify() {
        for outcome in outcomes {
            let h = RememberedValuesSettingsHarness()
            h.control.outcome = outcome
            let model = h.makeModel()
            var changes = 0
            model.onChange = { changes += 1 }

            for attempt in 1...2 {
                model.requestForgetAll()
                model.requestForgetAll()
                model.confirmForgetAll()
                model.confirmForgetAll()
                XCTAssertEqual(model.state.lastOutcome, outcome)
                XCTAssertEqual(h.control.calls, attempt)
                XCTAssertEqual(changes, attempt * 2)
            }
        }
    }

    func testPortAndEveryStateTransitionUseMainThreadUnderBothSchedulingModes() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = RememberedValuesSettingsHarness()
            h.main.mode = mode
            let model = h.makeModel()
            var changes = 0
            model.onChange = {
                XCTAssertTrue(h.main.isRunning)
                changes += 1
            }

            model.requestForgetAll()
            if mode == .deferred {
                XCTAssertEqual(model.state.confirmation, .none)
                XCTAssertEqual(changes, 0)
            }
            h.main.drain()
            XCTAssertEqual(model.state.confirmation, .forgetAll)
            XCTAssertEqual(changes, 1)
            model.cancelForgetAll()
            if mode == .deferred { XCTAssertEqual(model.state.confirmation, .forgetAll) }
            h.main.drain()
            XCTAssertEqual(model.state.confirmation, .none)
            XCTAssertEqual(changes, 2)
            XCTAssertEqual(h.control.calls, 0)

            // Preserve intent order even when both are queued before draining.
            model.requestForgetAll()
            model.confirmForgetAll()
            if mode == .deferred {
                XCTAssertNil(model.state.lastOutcome)
                XCTAssertEqual(h.control.calls, 0)
                XCTAssertEqual(changes, 2)
            }
            h.main.drain()
            XCTAssertEqual(model.state.lastOutcome, .forgotten)
            XCTAssertEqual(h.control.calls, 1)
            XCTAssertEqual(changes, 4)
        }
    }

    func testQueuedConfirmedIntentSurvivesSettingsClosingAndThenReleasesModel() {
        let h = RememberedValuesSettingsHarness()
        var model: RememberedValuesSettingsModel? = h.makeModel()
        let isReleased = { [weak model] in model == nil }
        var changes = 0
        model?.onChange = { changes += 1 }
        model?.requestForgetAll()
        h.main.mode = .deferred
        model?.confirmForgetAll()
        model = nil
        XCTAssertFalse(isReleased())
        XCTAssertEqual(h.control.calls, 0)
        XCTAssertEqual(changes, 1)

        h.main.drain()

        XCTAssertEqual(h.control.calls, 1)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(isReleased(), "The queued mutation releases its model after it runs")
    }

    func testInlinePickerCallbacksCannotReenterAConfirmedReset() {
        let h = RememberedValuesSettingsHarness()
        let model = h.makeModel()
        h.control.onForget = { [weak model] in
            model?.confirmForgetAll()
            model?.requestForgetAll()
            model?.cancelForgetAll()
        }
        model.requestForgetAll()
        model.confirmForgetAll()
        XCTAssertEqual(h.control.calls, 1)
        XCTAssertEqual(model.state.confirmation, .none)
        XCTAssertEqual(model.state.lastOutcome, .forgotten)
    }

    func testCompositionAdapterUsesReplacementPickerForDraftsAndOpenForm() throws {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = PromptFlowHarness(mainMode: mode)
            let old = try h.put(prompt(defaultValue: "old default"))
            try h.values.record(identity: old.identity, values: ["topic": "saved", "retired": "stale"])
            try h.open()
            try h.openForm().setValue("retired picker draft", name: "topic")
            h.picker.dismiss()
            h.delivery.main.drain()
            let control = CurrentPickerValuesControl(picker: h.picker, main: h.delivery.main)
            let model = RememberedValuesSettingsModel(control: control, mainThread: h.delivery.main)
            model.requestForgetAll()
            h.delivery.main.drain()

            // Composition replaces the library graph while the same Settings
            // model is alive. Its app-data stores and delivery service survive.
            let library = MemoryFileStore()
            try library.put(prompt(defaultValue: "new default"), at: "a.md")
            try library.put(prompt(defaultValue: "other default"), at: "b.md")
            let service = LibraryService(library: library, data: h.data, clock: h.clock,
                                         entropy: LibraryEntropy(), keyedStores: [h.usage, h.values])
            let index = PromptIndex(service: service, usage: h.usage, clock: h.clock)
            let picker = PickerModel(index: index, fill: h.fill, delivery: h.delivery.service,
                                     main: h.delivery.main)
            try index.rebuild()
            h.delivery.main.drain()
            let second = try service.load(at: "b.md")
            try h.values.record(identity: second.identity, values: ["topic": "other saved"])
            control.picker = picker
            picker.open()
            h.delivery.main.drain()
            picker.setQuery("b")
            picker.use(mode: .copyOnly)
            h.delivery.main.drain()
            try XCTUnwrap(picker.fillModel).setValue("other draft", name: "topic")
            picker.escape()
            picker.setQuery("a")
            picker.use(mode: .paste(.terminal))
            h.delivery.main.drain()
            let form = try XCTUnwrap(picker.fillModel)
            form.setValue("current picker draft", name: "topic")
            let events = h.delivery.recorder.events

            model.confirmForgetAll()
            if mode == .deferred { XCTAssertEqual(form.values, ["topic": "current picker draft"]) }
            h.delivery.main.drain()

            XCTAssertEqual(model.state.lastOutcome, .forgotten)
            XCTAssertTrue(picker.fillModel === form)
            XCTAssertEqual(picker.state, .fill)
            XCTAssertEqual(form.values, ["topic": "new default"])
            XCTAssertEqual(form.preview, .rendered("new default"))
            XCTAssertEqual(form.preferredMode, .paste(.terminal))
            XCTAssertEqual(try h.values.rememberedValues(for: old.identity), [:])
            XCTAssertEqual(try h.values.rememberedValues(for: second.identity), [:])
            XCTAssertEqual(try h.usage.useEvents(for: old.identity), [])
            XCTAssertEqual(try h.usage.useEvents(for: second.identity), [])
            XCTAssertEqual(h.delivery.recorder.events, events)
            picker.escape()
            picker.setQuery("b")
            picker.use(mode: .copyOnly)
            h.delivery.main.drain()
            XCTAssertEqual(picker.fillModel?.values, ["topic": "other default"])
            picker.escape()
            picker.setQuery("a")
            picker.use(mode: .copyOnly)
            h.delivery.main.drain()
            XCTAssertEqual(picker.fillModel?.values, ["topic": "new default"])

            // Keeping the retired graph alive is a test oracle: forwarding to
            // it would clear its draft and leave the replacement form unchanged.
            h.picker.open()
            h.delivery.main.drain()
            XCTAssertEqual(try h.openForm().values, ["topic": "retired picker draft"])
        }
    }

    func testCompositionAdapterForgetsWhilePanelIsClosedAndReportsDeliveryRefusal() throws {
        let h = PromptFlowHarness()
        let entry = try h.put(prompt(defaultValue: "default"))
        try h.values.record(identity: entry.identity, values: ["topic": "saved"])
        try h.open()
        let form = try h.openForm()
        form.setValue("draft", name: "topic")
        let control = CurrentPickerValuesControl(picker: h.picker, main: h.delivery.main)
        let model = RememberedValuesSettingsModel(control: control, mainThread: h.delivery.main)

        model.requestForgetAll()
        form.deliver(mode: .copyOnly)
        let accesses = h.data.accessCount
        model.confirmForgetAll()
        XCTAssertEqual(model.state.lastOutcome, .deliveryInFlight)
        XCTAssertEqual(h.data.accessCount, accesses)
        XCTAssertEqual(form.values, ["topic": "draft"])
        h.settle()

        h.picker.open()
        try h.openForm().setValue("closed draft", name: "topic")
        h.picker.dismiss()
        let events = h.delivery.recorder.events
        model.requestForgetAll()
        model.confirmForgetAll()
        XCTAssertEqual(model.state.lastOutcome, .forgotten)
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(h.delivery.recorder.events, events)
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
        h.picker.open()
        XCTAssertEqual(try h.openForm().values, ["topic": "default"])
    }

    func testCopyWarnsAboutIrreversibilityAndHasNoPathsContentOrErrorBodies() {
        let copy = [RememberedValuesStrings.forgetAll, RememberedValuesStrings.confirmationTitle,
                    RememberedValuesStrings.confirmationMessage, RememberedValuesStrings.cancel]
            + outcomes.map(RememberedValuesStrings.message(for:))
        XCTAssertTrue(RememberedValuesStrings.confirmationMessage.contains("You"))
        XCTAssertTrue(RememberedValuesStrings.confirmationMessage.contains("cannot be undone"))
        for text in copy {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("\u{2014}"))
            XCTAssertFalse(text.contains("/"))
            for sensitive in ["PROMPT_SECRET_BODY", "FIELD_SECRET_VALUE", "PRIVATE_ERROR_BODY"] {
                XCTAssertFalse(text.contains(sensitive))
            }
        }
    }

    private var outcomes: [RememberedValuesOutcome] {
        [.forgotten, .deliveryInFlight, .fileStoreFailure(.ioFailure),
         .fileStoreFailure(.outsideRoot), .libraryFailure(.operationFailed),
         .libraryFailure(.keyedStateConflict)]
    }

    private func prompt(defaultValue: String) -> String {
        "---\nfields:\n  topic:\n    default: \(defaultValue)\n---\n{{topic}}"
    }
}

private final class RememberedValuesSettingsHarness {
    let main = FakeMainThread()
    let control: FakeRememberedValuesControl

    init() { control = FakeRememberedValuesControl(main: main) }

    func makeModel() -> RememberedValuesSettingsModel {
        RememberedValuesSettingsModel(control: control, mainThread: main)
    }
}

private final class FakeRememberedValuesControl: RememberedValuesControl {
    var outcome = RememberedValuesOutcome.forgotten
    var onForget: (() -> Void)?
    private(set) var calls = 0
    private let main: FakeMainThread

    init(main: FakeMainThread) { self.main = main }

    func forgetAllValues() -> RememberedValuesOutcome {
        XCTAssertTrue(main.isRunning)
        calls += 1
        onForget?()
        return outcome
    }
}

private final class CurrentPickerValuesControl: RememberedValuesControl {
    var picker: PickerModel
    private let main: FakeMainThread

    init(picker: PickerModel, main: FakeMainThread) {
        self.picker = picker
        self.main = main
    }

    func forgetAllValues() -> RememberedValuesOutcome {
        XCTAssertTrue(main.isRunning)
        return picker.forgetAllValues()
    }
}
