import Foundation
import XCTest
@testable import MonkeysPawCore

final class ForgetValuesModelTests: XCTestCase {
    private let forgetIntents: [(PickerModel) -> Void] = [
        { $0.forgetSelectedValues() }, { $0.forgetAllValues() }
    ]

    func testSelectedForgetClearsOnlySelectedDraftAndRememberedIdentity() throws {
        let h = PromptFlowHarness()
        let first = try h.put(prompt(defaultValue: "first default"))
        let second = try h.put(prompt(defaultValue: "second default"), at: "b.md")
        try h.values.record(identity: first.identity, values: ["topic": "first saved", "retired": "stale"])
        try h.values.record(identity: second.identity, values: ["topic": "second saved"])
        try h.open()
        try h.openForm().setValue("first draft", name: "topic")
        h.picker.escape()
        h.picker.setQuery("b")
        try h.openForm().setValue("second draft", name: "topic")
        h.picker.escape()
        h.picker.setQuery("a")
        let events = h.delivery.recorder.events

        h.picker.forgetSelectedValues()

        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(h.picker.state, .picker)
        XCTAssertEqual(try h.values.rememberedValues(for: first.identity), [:])
        XCTAssertEqual(try h.values.rememberedValues(for: second.identity), ["topic": "second saved"])
        XCTAssertEqual(h.delivery.recorder.events, events)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        XCTAssertEqual(try h.usage.useEvents(for: first.identity), [])
        XCTAssertEqual(try h.usage.useEvents(for: second.identity), [])
        XCTAssertEqual(try h.openForm().values, ["topic": "first default"])
        h.picker.escape()
        h.picker.setQuery("b")
        XCTAssertEqual(try h.openForm().values, ["topic": "second draft"])
    }

    func testGlobalForgetClearsAllDraftsWhilePanelIsClosed() throws {
        let h = PromptFlowHarness()
        let first = try h.put(prompt(defaultValue: "first default"))
        let second = try h.put(prompt(defaultValue: "second default"), at: "b.md")
        let removed = try h.put("Body", at: "removed.md")
        try h.library.delete(at: "removed.md")
        for entry in [first, second, removed] {
            try h.values.record(identity: entry.identity, values: ["topic": "saved"])
        }
        try h.open()
        try h.openForm().setValue("first draft", name: "topic")
        h.picker.escape()
        h.picker.setQuery("b")
        try h.openForm().setValue("second draft", name: "topic")
        h.picker.dismiss()
        let events = h.delivery.recorder.events

        h.picker.forgetAllValues()

        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(try h.data.text(at: "values.json"), "{\"values\":{},\"version\":1}")
        XCTAssertTrue(h.data.isPrivate(at: "values.json"))
        XCTAssertEqual(h.delivery.recorder.events, events)
        for entry in [first, second, removed] {
            XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
            XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        }
        h.picker.open()
        XCTAssertEqual(try h.openForm().values, ["topic": "second default"])
        h.picker.escape()
        h.picker.setQuery("a")
        XCTAssertEqual(try h.openForm().values, ["topic": "first default"])
    }

    func testForgetAssignedIdentityResetsImplicitRequiredFieldToEmpty() throws {
        for forget in forgetIntents {
            let h = PromptFlowHarness()
            let entry = try h.put("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\n{{implicit}}")
            guard case .assigned = entry.identity else {
                XCTFail("Expected an assigned prompt identity.")
                return
            }
            try h.values.record(identity: entry.identity, values: ["implicit": "saved", "retired": "stale"])
            try h.open()
            let form = try h.openForm()
            XCTAssertEqual(form.values, ["implicit": "saved"])
            XCTAssertTrue(form.deliverEnabled)
            form.setValue("draft", name: "implicit")
            let events = h.delivery.recorder.events

            forget(h.picker)

            XCTAssertNil(h.picker.forgetValuesError)
            XCTAssertEqual(form.values, ["implicit": ""])
            XCTAssertEqual(form.preview, .blocked(.missingRequiredValue("implicit"), issues: []))
            XCTAssertFalse(form.deliverEnabled)
            XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
            XCTAssertTrue(h.data.isPrivate(at: "values.json"))
            form.deliver(mode: .copyOnly)
            XCTAssertEqual(h.delivery.recorder.events, events)
            XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
            h.picker.escape()
            XCTAssertEqual(try h.openForm().values, ["implicit": ""])
        }
    }

    func testSelectedForgetUsesHeldFormIdentityAfterRefreshMovesSelection() throws {
        let h = PromptFlowHarness()
        let first = try h.put(prompt(defaultValue: "first default"))
        let second = try h.put(prompt(defaultValue: "second default"), at: "b.md")
        try h.values.record(identity: first.identity, values: ["topic": "first saved"])
        try h.values.record(identity: second.identity, values: ["topic": "second saved"])
        try h.open()
        let form = try h.openForm()
        form.setValue("first draft", name: "topic")
        try h.library.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: ["a.md"]))
        XCTAssertEqual(h.picker.results.first?.identity, second.identity)

        h.picker.forgetSelectedValues()

        XCTAssertTrue(h.picker.fillModel === form)
        XCTAssertEqual(h.picker.state, .fill)
        XCTAssertEqual(form.values, ["topic": "first default"])
        XCTAssertEqual(form.preview, .rendered("first default"))
        XCTAssertEqual(try h.values.rememberedValues(for: first.identity), [:])
        XCTAssertEqual(try h.values.rememberedValues(for: second.identity), ["topic": "second saved"])
        XCTAssertEqual(h.picker.selectedPreview, .body("second default"))
    }

    func testLiveForgetResetsEveryDefaultAndPreservesFormMetadataFocusModeAndSnapshot() throws {
        for forget in forgetIntents {
            let h = PromptFlowHarness()
            let entry = try h.put("""
            ---
            fields:
              topic:
                type: multiline
                label: Subject
                description: Help text
                default: default topic
              style:
                type: choice
                options: [one, two]
                default: one
                optional: true
                remember: false
              blank:
                optional: true
                remember: false
            ---
            {{topic}}/{{style}}/{{blank}}/{{clipboard}}/{{date}}/{{time}}
            """)
            try h.values.record(identity: entry.identity, values: ["topic": "saved topic", "retired": "stale"])
            try h.open()
            h.delivery.clipboard.writeText("initial clipboard")
            let form = try h.openForm(mode: .paste(.terminal))
            form.setValue("typed topic", name: "topic")
            form.setValue("two", name: "style")
            form.setValue("typed blank", name: "blank")
            form.focusField(at: 2)
            let metadata = form.fields
            h.clock.date = Date(timeIntervalSince1970: 100_000)
            h.delivery.clipboard.writeText("changed clipboard")
            let reads = h.delivery.clipboard.readCount
            let clockReads = h.clock.readCount
            let events = h.delivery.recorder.events
            var formChanges = 0
            var pickerChanges = 0
            form.onChange = { formChanges += 1 }
            h.picker.onChange = { pickerChanges += 1 }

            forget(h.picker)

            XCTAssertNil(h.picker.forgetValuesError)
            XCTAssertTrue(h.picker.fillModel === form)
            XCTAssertEqual(h.picker.state, .fill)
            XCTAssertEqual(form.state, .editing)
            XCTAssertEqual(form.focusIndex, 2)
            XCTAssertEqual(form.preferredMode, .paste(.terminal))
            XCTAssertTrue(form.builtinsResolved)
            XCTAssertTrue(form.deliverEnabled)
            XCTAssertEqual(form.values, ["topic": "default topic", "style": "one", "blank": ""])
            XCTAssertEqual(form.preview, .rendered("default topic/one//initial clipboard/1970-01-01/00:00"))
            XCTAssertEqual(form.fields.map(\.id), metadata.map(\.id))
            XCTAssertEqual(form.fields.map(\.kind), metadata.map(\.kind))
            XCTAssertEqual(form.fields.map(\.label), metadata.map(\.label))
            XCTAssertEqual(form.fields.map(\.description), metadata.map(\.description))
            XCTAssertEqual(form.fields.map(\.options), metadata.map(\.options))
            XCTAssertEqual(form.fields.map(\.optional), metadata.map(\.optional))
            XCTAssertEqual(form.fields.map(\.remember), metadata.map(\.remember))
            XCTAssertEqual(form.issues, entry.issues)
            XCTAssertEqual(form.canRender, entry.document.canRender)
            XCTAssertEqual(form.isReadOnly, entry.document.isReadOnly)
            XCTAssertEqual(formChanges, 1)
            XCTAssertEqual(pickerChanges, 1)
            XCTAssertEqual(h.delivery.clipboard.readCount, reads)
            XCTAssertEqual(h.clock.readCount, clockReads)
            XCTAssertEqual(h.delivery.recorder.events, events)
            XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
            XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
            h.picker.dismiss()
            h.picker.open()
            XCTAssertEqual(try h.openForm().values, ["topic": "default topic", "style": "one", "blank": ""])
        }
    }

    func testForgetUsesHeldDefaultsThenReopensWithLatestDefaults() throws {
        let leaveForm: [(PickerModel) -> Void] = [
            { $0.escape() },
            { $0.dismiss(); $0.open() },
            { $0.fillModel?.cancel(); $0.open() }
        ]
        for forget in forgetIntents {
            for leave in leaveForm {
                let h = PromptFlowHarness()
                _ = try h.put(prompt(defaultValue: "original default"))
                try h.open()
                let form = try h.openForm()
                form.setValue("typed", name: "topic")
                _ = try h.put(prompt(defaultValue: "edited default"))
                try h.index.apply(LibraryChangeSet(modified: ["a.md"]))

                forget(h.picker)

                XCTAssertTrue(h.picker.fillModel === form)
                XCTAssertEqual(form.values, ["topic": "original default"])
                XCTAssertEqual(form.preview, .rendered("original default"))
                leave(h.picker)
                XCTAssertEqual(try h.openForm().values, ["topic": "edited default"])
            }
        }
    }

    func testSelectedWriteFailureKeepsPersistedBytesAndDraftUntilRetry() throws {
        let h = PromptFlowHarness()
        let entry = try h.put(prompt(defaultValue: "default"))
        try h.values.record(identity: entry.identity, values: ["topic": "saved", "retired": "stale"])
        try h.open()
        let form = try h.openForm()
        form.setValue("draft", name: "topic")
        let bytes = try h.data.read(at: "values.json")
        let stamp = try h.data.stamp(at: "values.json")
        let events = h.delivery.recorder.events
        var changes = 0
        h.picker.onChange = { changes += 1 }
        h.data.failNextWrite = true

        h.picker.forgetSelectedValues()

        XCTAssertEqual(h.picker.forgetValuesError as? FileStoreError, .ioFailure)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(h.picker.state, .fill)
        XCTAssertEqual(form.state, .editing)
        XCTAssertEqual(form.values, ["topic": "draft"])
        XCTAssertEqual(form.preview, .rendered("draft"))
        XCTAssertEqual(try h.data.read(at: "values.json"), bytes)
        XCTAssertEqual(try h.data.stamp(at: "values.json"), stamp)
        XCTAssertEqual(h.delivery.recorder.events, events)
        h.picker.escape()
        let reopened = try h.openForm()
        XCTAssertEqual(reopened.values, ["topic": "draft"])
        XCTAssertEqual(h.picker.forgetValuesError as? FileStoreError, .ioFailure)

        h.picker.forgetSelectedValues()

        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(reopened.values, ["topic": "default"])
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
    }

    func testGlobalWriteFailureRetainsEveryClosedDraftUntilRetry() throws {
        let h = PromptFlowHarness()
        let first = try h.put(prompt(defaultValue: "first default"))
        let second = try h.put(prompt(defaultValue: "second default"), at: "b.md")
        for entry in [first, second] {
            try h.values.record(identity: entry.identity, values: ["topic": "saved"])
        }
        try h.open()
        try h.openForm().setValue("first draft", name: "topic")
        h.picker.escape()
        h.picker.setQuery("b")
        try h.openForm().setValue("second draft", name: "topic")
        h.picker.dismiss()
        let bytes = try h.data.read(at: "values.json")
        let stamp = try h.data.stamp(at: "values.json")
        h.data.failNextWrite = true

        h.picker.forgetAllValues()

        XCTAssertEqual(h.picker.forgetValuesError as? FileStoreError, .ioFailure)
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(try h.data.read(at: "values.json"), bytes)
        XCTAssertEqual(try h.data.stamp(at: "values.json"), stamp)
        h.picker.open()
        XCTAssertEqual(try h.openForm().values, ["topic": "second draft"])
        h.picker.escape()
        h.picker.setQuery("a")
        let form = try h.openForm()
        XCTAssertEqual(form.values, ["topic": "first draft"])

        h.picker.forgetAllValues()

        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(form.values, ["topic": "first default"])
        h.picker.escape()
        h.picker.setQuery("b")
        XCTAssertEqual(try h.openForm().values, ["topic": "second default"])
    }

    func testCorruptSelectiveFailureAndGlobalRetryClearWarningsOnlyAfterSuccess() throws {
        let h = PromptFlowHarness()
        let entry = try h.put(prompt(defaultValue: "default"))
        try h.data.put("rejected private state", at: "values.json")
        try h.open()
        let form = try h.openForm()
        form.setValue("draft", name: "topic")
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesUnavailable])
        let bytes = try h.data.read(at: "values.json")

        h.picker.forgetSelectedValues()

        XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(form.values, ["topic": "draft"])
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesUnavailable])
        XCTAssertEqual(h.picker.persistenceWarnings, [.rememberedValuesUnavailable])
        XCTAssertEqual(try h.data.read(at: "values.json"), bytes)
        h.data.failNextWrite = true
        h.picker.forgetAllValues()
        XCTAssertEqual(h.picker.forgetValuesError as? FileStoreError, .ioFailure)
        XCTAssertEqual(form.values, ["topic": "draft"])
        XCTAssertEqual(form.persistenceWarnings, [.rememberedValuesUnavailable])
        XCTAssertEqual(h.picker.persistenceWarnings, [.rememberedValuesUnavailable])
        XCTAssertEqual(try h.data.read(at: "values.json"), bytes)

        h.picker.forgetAllValues()

        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(form.values, ["topic": "default"])
        XCTAssertEqual(form.persistenceWarnings, [])
        XCTAssertEqual(h.picker.persistenceWarnings, [])
        XCTAssertEqual(try h.data.text(at: "values.json"), "{\"values\":{},\"version\":1}")
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        XCTAssertNil(h.delivery.clipboard.readText())
    }

    func testSelectedUnknownReadFailureExposesOnlySanitizedTypedError() throws {
        let h = PromptFlowHarness()
        _ = try h.put(prompt(defaultValue: "default"))
        try h.open()
        let form = try h.openForm()
        form.setValue("draft", name: "topic")
        h.data.onRead = { _ in throw NSError(domain: "private/path/values", code: 1) }

        h.picker.forgetSelectedValues()

        XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(form.values, ["topic": "draft"])
        h.data.onRead = nil
        h.picker.forgetSelectedValues()
        XCTAssertNil(h.picker.forgetValuesError)
    }

    func testNoSelectionIsExplicitFailureAndClosedGlobalForgetCanClearIt() throws {
        let h = PromptFlowHarness()
        var changes = 0
        h.picker.onChange = { changes += 1 }

        h.picker.forgetSelectedValues()

        XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .invalidIdentity)
        XCTAssertEqual(h.data.accessCount, 0)
        XCTAssertEqual(changes, 1)
        h.picker.forgetAllValues()
        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(h.delivery.recorder.events, [])
    }

    func testForgetDuringDeliveryRejectsBothIntentsWithoutTouchingState() throws {
        for forget in forgetIntents {
            for source in ["Body", prompt(defaultValue: "default")] {
                let h = PromptFlowHarness()
                let entry = try h.put(source)
                try h.values.record(identity: entry.identity, values: ["topic": "saved"])
                try h.open()
                h.picker.use(mode: .copyOnly)
                let form = h.picker.fillModel
                form?.setValue("delivered", name: "topic")
                form?.deliver(mode: .copyOnly)
                let bytes = try h.data.read(at: "values.json")
                let stamp = try h.data.stamp(at: "values.json")
                let accesses = h.data.accessCount
                let events = h.delivery.recorder.events
                var changes = 0
                h.picker.onChange = { changes += 1 }

                forget(h.picker)

                XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .operationFailed)
                XCTAssertEqual(h.picker.state, .delivering)
                XCTAssertEqual(changes, 1)
                XCTAssertEqual(h.data.accessCount, accesses)
                XCTAssertEqual(try h.data.read(at: "values.json"), bytes)
                XCTAssertEqual(try h.data.stamp(at: "values.json"), stamp)
                XCTAssertEqual(h.delivery.recorder.events, events)
                h.settle()
                XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [h.clock.date])
                if let form {
                    XCTAssertEqual(form.values, ["topic": "delivered"])
                    XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), ["topic": "delivered"])
                }

                forget(h.picker)

                XCTAssertNil(h.picker.forgetValuesError)
                XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
                XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
                if let form {
                    XCTAssertEqual(form.state, .done(.copiedOnly(.requested)))
                    XCTAssertEqual(form.values, ["topic": "delivered"])
                }
            }
        }
    }

    func testForgetCancelsPendingFieldlessUseWithoutDeliveryOrLearning() throws {
        for forget in forgetIntents {
            let h = PromptFlowHarness()
            let entry = try h.put("{{clipboard}}")
            try h.values.record(identity: entry.identity, values: ["retired": "saved"])
            try h.open()
            h.delivery.clipboard.readMode = .deferred
            h.picker.use(mode: .copyOnly)
            XCTAssertTrue(h.picker.isResolvingBuiltins)
            let events = h.delivery.recorder.events

            forget(h.picker)
            h.delivery.clipboard.completeRead("late snapshot")
            h.settle()

            XCTAssertNil(h.picker.forgetValuesError)
            XCTAssertFalse(h.picker.isResolvingBuiltins)
            XCTAssertEqual(h.picker.state, .picker)
            XCTAssertEqual(h.delivery.clipboard.readCount, 1)
            XCTAssertEqual(h.delivery.recorder.events, events)
            XCTAssertNil(h.delivery.clipboard.readText())
            XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
            XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        }
    }

    func testForgetPreservesPendingFormSnapshotAndLaterEdits() throws {
        for forget in forgetIntents {
            let h = PromptFlowHarness(mainMode: .deferred)
            let entry = try h.put("---\nfields:\n  topic:\n    default: default\n---\n{{topic}}/{{clipboard}}")
            try h.values.record(identity: entry.identity, values: ["topic": "saved"])
            try h.open()
            h.delivery.clipboard.readMode = .deferred
            let form = try h.openForm()
            form.setValue("before reset", name: "topic")
            let events = h.delivery.recorder.events

            forget(h.picker)

            XCTAssertFalse(form.builtinsResolved)
            XCTAssertFalse(form.deliverEnabled)
            XCTAssertEqual(form.values, ["topic": "default"])
            XCTAssertEqual(form.preview, .blocked(.missingBuiltin(.clipboard), issues: []))
            form.setValue("after reset", name: "topic")
            h.delivery.clipboard.completeRead("original snapshot")
            XCTAssertFalse(form.builtinsResolved)
            h.delivery.main.drain()
            XCTAssertTrue(form.builtinsResolved)
            XCTAssertEqual(form.values, ["topic": "after reset"])
            XCTAssertEqual(form.preview, .rendered("after reset/original snapshot"))
            XCTAssertEqual(h.delivery.clipboard.readCount, 1)
            XCTAssertEqual(h.delivery.recorder.events, events)
            XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
            XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
            XCTAssertNil(h.delivery.clipboard.readText())

            h.picker.escape()
            XCTAssertEqual(try h.openForm().values, ["topic": "after reset"])
        }
    }

    func testGlobalForgetClosedFormIgnoresOldSnapshotOnReopen() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\nfields:\n  topic:\n    default: default\n---\n{{topic}}/{{clipboard}}")
        try h.open()
        h.delivery.clipboard.readMode = .deferred
        let old = try h.openForm()
        old.setValue("old draft", name: "topic")
        h.picker.dismiss()

        h.picker.forgetAllValues()
        h.picker.open()
        let reopened = try h.openForm()
        h.delivery.clipboard.completeRead("stale snapshot")

        XCTAssertEqual(old.state, .closed)
        XCTAssertFalse(old.builtinsResolved)
        XCTAssertFalse(reopened.builtinsResolved)
        XCTAssertEqual(reopened.values, ["topic": "default"])
        h.delivery.clipboard.completeRead("new snapshot")
        XCTAssertEqual(reopened.preview, .rendered("default/new snapshot"))
        XCTAssertNil(h.delivery.clipboard.readText())
    }

    func testSuccessfulForgetClearsStalePickerDeliveryWarnings() throws {
        for forget in forgetIntents {
            let h = PromptFlowHarness()
            _ = try h.put("Body")
            try h.open()
            h.data.failNextWrite = true
            h.picker.use(mode: .copyOnly)
            h.settle()
            XCTAssertEqual(h.picker.persistenceWarnings, [.usageNotSaved])
            let events = h.delivery.recorder.events

            forget(h.picker)

            XCTAssertEqual(h.picker.persistenceWarnings, [])
            XCTAssertNil(h.picker.forgetValuesError)
            XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
            XCTAssertEqual(h.delivery.recorder.events, events)
        }
    }

    private func prompt(defaultValue: String) -> String {
        "---\nfields:\n  topic:\n    default: \(defaultValue)\n---\n{{topic}}"
    }
}
