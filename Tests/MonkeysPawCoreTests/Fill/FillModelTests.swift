import Foundation
import XCTest
@testable import MonkeysPawCore

final class FillModelTests: XCTestCase {
    func testStaleTicketAfterDeliveryOutcomeFinishesWithoutLearning() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        h.flow.delivery.injectors[.cgEvent]?.mode = .deferred
        try h.open()
        h.picker.use(mode: .paste(.standard))
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("delivered", name: "field")
        form.deliver(mode: .paste(.standard))
        h.flow.settle()
        var changes: [FillModel.State] = []
        form.onChange = { changes.append(form.state) }
        h.flow.delivery.main.mode = .deferred
        h.flow.delivery.injectors[.cgEvent]?.complete([.sent, .sent])
        XCTAssertTrue(h.flow.delivery.main.drainOne())
        XCTAssertEqual(h.flow.delivery.service.lastDelivery?.outcome, .pasted(.cgEvent))
        XCTAssertEqual(form.state, .delivering)

        try h.service.retire()
        h.flow.delivery.main.drain()

        XCTAssertEqual(changes, [.done(.pasted(.cgEvent))])
        XCTAssertEqual(form.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(h.picker.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(try h.flow.values.rememberedValues(for: entry.identity), [:])
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), [])
        XCTAssertNil(try h.store.load())
    }

    func testStaleRecordingCallbackFinishesAndPreservesFillWarnings() throws {
        let h = try RepeatHarness(heldWork: true)
        let entry = try h.put("{{field}}")
        try h.open()
        h.picker.use(mode: .copyOnly)
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("delivered", name: "field")
        h.flow.data.failNextWrite = true
        form.deliver(mode: .copyOnly)
        h.flow.settle()
        XCTAssertEqual(form.state, .delivering)
        XCTAssertEqual(h.held.pending.count, 1)
        var changes: [FillModel.State] = []
        form.onChange = { changes.append(form.state) }

        try h.service.retire()
        h.held.releaseAll()

        XCTAssertEqual(changes, [.done(.copiedOnly(.requested))])
        XCTAssertEqual(form.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.picker.persistenceWarnings, [.rememberedValuesNotSaved])
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 1)
        XCTAssertNil(try h.store.load())
    }

    func testPreferredFillModeIsChosenAtOpenAndSurvivesDefaultChange() throws {
        for windowClass in ["kitty", "Firefox"] {
            for explicit: DeliveryMode? in [nil, .paste(.standard), .paste(.terminal), .copyOnly] {
                var saved = PasteChord.terminal
                let h = PromptFlowHarness(session: .otherX11, linuxDefaultPasteChord: { saved })
                h.delivery.focus.target = .linux(session: .otherX11, x11WindowClass: windowClass)
                _ = try h.put("---\nfields:\n  f:\n    default: text\n---\n{{f}}")
                try h.open()
                if let explicit { h.picker.use(mode: explicit) }
                else { h.picker.usePreferred() }
                let form = try XCTUnwrap(h.picker.fillModel)
                let chosen = explicit ?? .paste(.terminal)
                XCTAssertEqual(form.preferredMode, chosen)
                saved = .standard
                form.setValue("Changed", name: "f")
                XCTAssertEqual(form.preferredMode, chosen)
                let targetHint = windowClass == "kitty" ? "X11 terminal" : "X11 target"
                let action = chosen == .copyOnly ? "Copy only" : (chosen == .paste(.terminal) ? "Ctrl+Shift+V" : "Ctrl+V")
                XCTAssertEqual(form.deliveryHint, targetHint + " · " + action)
                form.deliver(mode: form.preferredMode)
                h.settle()
                switch chosen {
                case .paste(let chord): XCTAssertEqual(h.delivery.injectors[.xdotool]?.chords, [chord])
                case .copyOnly: XCTAssertTrue(h.delivery.injectors.values.allSatisfy { $0.chords.isEmpty })
                }
            }
        }
    }

    func testRepeatProjectionFailureRemainsVisibleAfterRealFillDelivery() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        h.flow.data.onWrite = { if $0.hasPrefix("usage/") { h.flow.data.failNextWrite = true } }
        try h.deliver(mode: .copyOnly, values: ["field": "exact"])
        XCTAssertEqual(h.picker.fillModel?.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.picker.persistenceWarnings, [.lastDeliveryNotSaved])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "exact")
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 1)
        XCTAssertNil(try h.store.load())
    }

    func testLateInjectorReplyAfterRetirementCannotRememberFillValues() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        h.flow.delivery.injectors[.cgEvent]?.mode = .deferred
        try h.open()
        h.picker.use(mode: .paste(.standard))
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("late fields", name: "field")
        form.deliver(mode: .paste(.standard))
        h.flow.settle()
        try h.service.retire()
        h.flow.delivery.injectors[.cgEvent]?.complete([.sent, .sent])
        XCTAssertEqual(try h.flow.values.rememberedValues(for: entry.identity), [:])
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), [])
        XCTAssertNil(try h.store.load())
    }

    func testNativeFocusKeepsTraversalInFieldOrderAndRejectsInvalidPositions() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{a}} {{b}} {{c}}")
        try h.open()
        let form = try h.openForm()
        form.focusField(at: 2)
        XCTAssertEqual(form.focusIndex, 2)
        form.focusNext()
        XCTAssertEqual(form.focusIndex, 0)
        form.focusPrevious()
        XCTAssertEqual(form.focusIndex, 2)
        form.focusField(at: -1)
        form.focusField(at: 3)
        XCTAssertEqual(form.focusIndex, 2)
        h.picker.dismiss()
        form.focusField(at: 0)
        XCTAssertEqual(form.focusIndex, 2)
    }

    func testDuplicateFormFieldNamesKeepLastValueWithoutTrapping() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{f}}")
        let field = try XCTUnwrap(entry.document.effectiveFields.first)
        let form = FillForm(fields: [FillFormField(field, prefill: "first"),
                                     FillFormField(field, prefill: "last")],
                            issues: entry.issues, canRender: entry.document.canRender,
                            isReadOnly: entry.document.isReadOnly, warning: nil)
        let model = FillModel(entry: entry, form: form, draft: nil, preferredMode: .copyOnly,
                              fill: h.fill, delivery: h.delivery.service, index: h.index,
                              main: h.delivery.main, onDraft: { _ in }, onDelivering: {},
                              onBack: {}, onCancel: {}, onDelivered: { _, _ in })
        XCTAssertEqual(model.values, ["f": "last"])
        XCTAssertEqual(model.preview, .rendered("last"))
        model.open()
        XCTAssertEqual(model.preview, .rendered("last"))
        XCTAssertTrue(model.deliverEnabled)
    }

    func testFormOnChangeOwnershipDoesNotBreakPickerDeliveryState() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("text", name: "f")
        form.onChange = {} // the form view owns this hook
        form.deliver(mode: .copyOnly)
        XCTAssertEqual(form.state, .delivering)
        XCTAssertEqual(h.picker.state, .delivering)
    }

    func testFieldOrderMetadataAndTabShiftTab() throws {
        let h = PromptFlowHarness()
        _ = try h.put("""
        ---
        fields:
          last:
            type: choice
            label: Last
            description: Help text
            options: [one, two]
            optional: true
            remember: false
          first:
            type: multiline
        ---
        {{first}} {{middle}} {{last}} {{first}}
        """)
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.fields.map(\.id), ["first", "middle", "last"])
        XCTAssertEqual(form.fields.map(\.kind), [.multiline, .text, .choice])
        XCTAssertEqual(form.fields[2].label, "Last")
        XCTAssertEqual(form.fields[2].description, "Help text")
        XCTAssertEqual(form.fields[2].options.map(\.value), ["one", "two"])
        XCTAssertTrue(form.fields[2].optional)
        XCTAssertFalse(form.fields[2].remember)
        XCTAssertEqual(form.focusIndex, 0)
        form.focusNext()
        XCTAssertEqual(form.focusIndex, 1)
        form.focusNext()
        XCTAssertEqual(form.focusIndex, 2)
        form.focusNext()
        XCTAssertEqual(form.focusIndex, 0)
        form.focusPrevious()
        XCTAssertEqual(form.focusIndex, 2)
        form.focusPrevious()
        XCTAssertEqual(form.focusIndex, 1)
    }

    func testRequiredAndChoiceGatingAndLivePreviewForEveryEdit() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n---\n{{f}} {{c}}")
        try h.open()
        let form = try h.openForm()
        XCTAssertFalse(form.deliverEnabled)
        XCTAssertFalse(form.canCopyOnly)
        XCTAssertEqual(form.preview, .blocked(.missingRequiredValue("f"), issues: []))
        form.deliver(mode: .copyOnly)
        XCTAssertNil(h.delivery.clipboard.readText())
        var changes = 0
        form.onChange = { changes += 1 }
        form.setValue(" ", name: "f") // required text is not trimmed
        XCTAssertEqual(form.preview, .blocked(.missingRequiredValue("c"), issues: []))
        form.setValue("bad", name: "c")
        XCTAssertEqual(form.preview, .blocked(.invalidChoiceValue("c"), issues: []))
        XCTAssertFalse(form.deliverEnabled)
        form.setValue("two", name: "c")
        XCTAssertEqual(form.preview, .rendered("  two"))
        XCTAssertTrue(form.deliverEnabled)
        XCTAssertTrue(form.canCopyOnly)
        form.setValue("", name: "f")
        XCTAssertFalse(form.deliverEnabled)
        form.setValue("ignored", name: "unknown")
        XCTAssertEqual(changes, 4)
        XCTAssertNil(form.values["unknown"])
    }

    func testOptionalEmptyChoiceIsDeliverableAndRememberedEmptyBeatsDefaultNextTime() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n    default: one\n    optional: true\n---\nA{{c}}B")
        try h.open()
        let form = try h.openForm()
        form.setValue("", name: "c")
        XCTAssertTrue(form.deliverEnabled)
        form.deliver(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), ["c": ""])
        h.picker.open()
        XCTAssertEqual(try h.openForm().fields[0].value, "")
    }

    func testPendingBuiltinFormIsInteractiveAndCallbackUpdatesPreviewOnMain() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("{{f}}/{{clipboard}}/{{date}}")
        try h.open()
        h.delivery.clipboard.readMode = .deferred
        let form = try h.openForm()
        form.setValue("typed while waiting", name: "f")
        XCTAssertEqual(form.preview, .blocked(.missingBuiltin(.clipboard), issues: []))
        XCTAssertFalse(form.builtinsResolved)
        XCTAssertFalse(form.deliverEnabled)
        XCTAssertFalse(form.canCopyOnly)
        form.deliver(mode: .copyOnly)
        XCTAssertNil(h.delivery.clipboard.readText())
        form.onChange = { XCTAssertTrue(h.delivery.main.isRunning) }
        h.delivery.clipboard.completeRead("snapshot")
        XCTAssertFalse(form.builtinsResolved)
        h.delivery.main.drain()
        XCTAssertTrue(form.builtinsResolved)
        XCTAssertTrue(form.deliverEnabled)
        XCTAssertEqual(form.preview, .rendered("typed while waiting/snapshot/1970-01-01"))
    }

    func testLateClipboardSnapshotCannotUpdateEscapedOrReopenedForm() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}}/{{clipboard}}")
        try h.open()
        h.delivery.clipboard.readMode = .deferred
        let old = try h.openForm()
        old.setValue("draft", name: "f")
        old.escape()
        var retiredChanges = 0
        old.onChange = { retiredChanges += 1 }
        let new = try h.openForm()
        XCTAssertEqual(new.fields[0].value, "draft")
        h.delivery.clipboard.completeRead("stale snapshot")
        XCTAssertFalse(old.builtinsResolved)
        XCTAssertFalse(new.builtinsResolved)
        XCTAssertEqual(retiredChanges, 0)
        h.delivery.clipboard.completeRead("new snapshot")
        XCTAssertEqual(new.preview, .rendered("draft/new snapshot"))
        XCTAssertTrue(new.deliverEnabled)
    }

    func testCopyOnlyDeliveryPersistsValuesAndUsageAndClearsSessionDraft() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("""
        ---
        fields:
          forget:
            remember: false
            default: fresh
        ---
        {{keep}} {{forget}}
        """)
        try h.open()
        let form = try h.openForm(mode: .copyOnly)
        form.setValue("remembered", name: "keep")
        form.setValue("session only", name: "forget")
        form.deliver(mode: .copyOnly)
        XCTAssertEqual(form.state, .delivering)
        XCTAssertEqual(h.picker.state, .delivering)
        XCTAssertFalse(form.deliverEnabled)
        form.setValue("after delivery", name: "keep")
        form.deliver(mode: .paste(.terminal))
        form.cancel()
        form.escape()
        h.picker.open()
        XCTAssertEqual(h.delivery.scheduler.delays.count, 1)
        h.settle()
        XCTAssertEqual(form.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.delivery.clipboard.readText(), "remembered session only")
        XCTAssertTrue(h.delivery.injectors.values.allSatisfy { $0.chords.isEmpty })
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), ["keep": "remembered"])
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [h.clock.date])
        XCTAssertTrue(h.data.isPrivate(at: "values.json"))
        h.picker.open()
        let reopened = try h.openForm()
        XCTAssertEqual(reopened.values, ["keep": "remembered", "forget": "fresh"])
    }

    func testStandardTerminalAndCopyModesCarryThroughPickerAndMapToDelivery() throws {
        for mode: DeliveryMode in [.paste(.standard), .paste(.terminal), .copyOnly] {
            let h = PromptFlowHarness(session: .otherX11)
            _ = try h.put("---\nfields:\n  f:\n    default: text\n---\n{{f}}")
            try h.open()
            let form = try h.openForm(mode: mode)
            XCTAssertEqual(form.preferredMode, mode)
            form.deliver(mode: form.preferredMode)
            h.settle()
            switch mode {
            case .paste(let chord):
                XCTAssertEqual(h.delivery.injectors[.xdotool]?.chords, [chord])
                XCTAssertEqual(form.state, .done(.pasted(.xdotool)))
            case .copyOnly:
                XCTAssertEqual(form.state, .done(.copiedOnly(.requested)))
                XCTAssertTrue(h.delivery.injectors.values.allSatisfy { $0.chords.isEmpty })
            }
        }
    }

    func testCancelClosesPanelAndRetainsDraftForNextHotkey() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("kept", name: "f")
        form.cancel()
        XCTAssertEqual(form.state, .closed)
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertTrue(h.delivery.recorder.events.contains(.hide))
        XCTAssertNil(h.delivery.clipboard.readText())
        h.picker.open()
        XCTAssertEqual(try h.openForm().fields[0].value, "kept")
    }

    func testRememberFailureDoesNotPreventDeliveryOrUsageAndIsVisible() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{f}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("delivered", name: "f")
        h.data.failNextWrite = true
        form.deliver(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.delivery.clipboard.readText(), "delivered")
        XCTAssertEqual(form.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesNotSaved])
        XCTAssertEqual(h.picker.persistenceWarnings, [.rememberedValuesNotSaved])
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [h.clock.date])
    }

    func testBothPersistenceFailuresSurfaceSanitizedWarningsWithoutStoppingDelivery() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("delivered", name: "f")
        h.data.onRead = { _ in throw NSError(domain: "private values/identity/path", code: 1) }
        form.deliver(mode: .paste(.standard))
        h.settle()
        XCTAssertEqual(form.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesNotSaved, .usageNotSaved])
        XCTAssertEqual(h.picker.persistenceWarnings, form.persistenceWarnings)
        XCTAssertEqual(h.index.search("").first?.score, 0)
    }

    func testCorruptRememberedStateShowsReadAndWriteWarningWithoutReset() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        try h.data.put("private corrupt data", at: "values.json")
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesUnavailable])
        form.deliver(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesUnavailable, .rememberedValuesNotSaved])
        XCTAssertEqual(try h.data.text(at: "values.json"), "private corrupt data")
        XCTAssertEqual(h.delivery.clipboard.readText(), "fallback")
    }

    func testUnusedClipboardIsNeverReadAcrossFormPreviewEditsAndDelivery() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}} {{date}} {{time}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("raw", name: "f")
        form.deliver(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        XCTAssertEqual(h.delivery.clipboard.readText(), "raw 1970-01-01 00:00")
    }
}
