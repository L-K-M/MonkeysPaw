import Foundation
import XCTest
@testable import MonkeysPawCore

final class PickerModelTests: XCTestCase {
    func testStaleTicketAfterDeliveryOutcomeFinishesWithoutRecordingUsage() throws {
        let h = try RepeatHarness()
        let entry = try h.put("body")
        h.flow.delivery.injectors[.cgEvent]?.mode = .deferred
        try h.open()
        h.picker.use(mode: .paste(.standard))
        h.flow.settle()
        var changes: [PickerModel.State] = []
        h.picker.onChange = { changes.append(h.picker.state) }
        h.flow.delivery.main.mode = .deferred
        h.flow.delivery.injectors[.cgEvent]?.complete([.sent, .sent])
        XCTAssertTrue(h.flow.delivery.main.drainOne())
        XCTAssertEqual(h.flow.delivery.service.lastDelivery?.outcome, .pasted(.cgEvent))
        XCTAssertEqual(h.picker.state, .delivering)

        try h.service.retire()
        h.flow.delivery.main.drain()

        XCTAssertEqual(changes, [.done(.pasted(.cgEvent))])
        XCTAssertEqual(h.picker.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), [])
        XCTAssertNil(try h.store.load())
    }

    func testStaleRecordingCallbackFinishesAndPreservesPickerWarnings() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("body")
        try h.open()
        h.flow.data.failNextWrite = true
        h.picker.use(mode: .copyOnly)
        h.flow.settle()
        XCTAssertEqual(h.picker.state, .delivering)
        XCTAssertEqual(h.held.pending.count, 1)
        var changes: [PickerModel.State] = []
        h.picker.onChange = { changes.append(h.picker.state) }

        try h.service.retire()
        h.held.releaseAll()

        XCTAssertEqual(changes, [.done(.copiedOnly(.requested))])
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.picker.persistenceWarnings, [.usageNotSaved])
        XCTAssertNil(try h.store.load())
    }

    func testPreferredTerminalModeAndHintPublishAfterDeferredTargetCapture() throws {
        let h = PromptFlowHarness(mainMode: .deferred, session: .otherX11)
        _ = try h.put("Body")
        try h.index.rebuild()
        h.delivery.main.drain()
        h.delivery.focus.target = .linux(session: .otherX11, x11WindowClass: "Gnome-terminal")
        var modes: [DeliveryMode] = []
        h.picker.onChange = { modes.append(h.picker.preferredMode) }
        h.picker.open()
        XCTAssertEqual(h.picker.preferredMode, .paste(.standard))
        h.delivery.main.drain()
        XCTAssertEqual(h.picker.preferredMode, .paste(.terminal))
        XCTAssertEqual(h.picker.deliveryHint, "X11 terminal · Ctrl+Shift+V")
        XCTAssertTrue(modes.contains(.paste(.terminal)))
        XCTAssertEqual(h.delivery.recorder.events.filter { $0 == .capture }.count, 1)
    }

    func testPreferredModeUsesSavedDefaultAndExplicitModesOverrideRecommendation() throws {
        for windowClass in ["konsole", "Firefox"] {
            for saved: PasteChord in [.standard, .terminal] {
                for explicit: DeliveryMode? in [nil, .paste(.standard), .paste(.terminal), .copyOnly] {
                    let h = PromptFlowHarness(session: .otherX11, linuxDefaultPasteChord: { saved })
                    h.delivery.focus.target = .linux(session: .otherX11, x11WindowClass: windowClass)
                    _ = try h.put("Body")
                    try h.open()
                    let preferred: DeliveryMode = .paste(windowClass == "konsole" ? .terminal : saved)
                    XCTAssertEqual(h.picker.preferredMode, preferred)
                    if let explicit { h.picker.use(mode: explicit) }
                    else { h.picker.usePreferred() }
                    h.settle()
                    switch explicit ?? preferred {
                    case .paste(let chord): XCTAssertEqual(h.delivery.injectors[.xdotool]?.chords, [chord])
                    case .copyOnly: XCTAssertTrue(h.delivery.injectors.values.allSatisfy { $0.chords.isEmpty })
                    }
                }
            }
        }
    }

    func testPreferredChordAndTargetAreFixedBeforeAsyncBuiltinRead() throws {
        var saved = PasteChord.terminal
        let h = PromptFlowHarness(session: .otherX11, linuxDefaultPasteChord: { saved })
        let target = DeliveryTarget.linux(session: .otherX11, x11WindowClass: "Firefox")
        h.delivery.focus.target = target
        h.delivery.clipboard.readMode = .deferred
        _ = try h.put("{{clipboard}}")
        try h.open()
        h.picker.usePreferred()
        XCTAssertTrue(h.picker.isResolvingBuiltins)
        saved = .standard
        h.delivery.focus.target = .linux(session: .otherX11, x11WindowClass: "kitty")
        h.delivery.service.arm()
        h.delivery.clipboard.completeRead("Snapshot")
        h.settle()
        XCTAssertEqual(h.delivery.injectors[.xdotool]?.chords, [.terminal])
        XCTAssertTrue(h.delivery.recorder.events.contains(.restore(target)))
    }

    func testFieldlessInvocationKeepsOriginalArmedTargetDuringBuiltinRead() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{clipboard}}")
        try h.open()
        let captured = try XCTUnwrap(h.delivery.focus.target)
        h.delivery.clipboard.readMode = .deferred
        h.picker.use(mode: .paste(.standard))
        h.delivery.focus.target = .macOS(processID: 99, bundleID: "later")
        h.delivery.service.arm()
        h.delivery.clipboard.completeRead("snapshot")
        h.settle()
        XCTAssertEqual(h.delivery.recorder.events.last(where: { if case .restore = $0 { return true }; return false }), .restore(captured))
    }

    func testRetiredFieldlessBuiltinCallbackCannotDeliverOrRecord() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{clipboard}}")
        try h.open()
        h.flow.delivery.clipboard.readMode = .deferred
        h.picker.use(mode: .paste(.standard))
        try h.service.retire()
        h.flow.delivery.clipboard.completeRead("late content")
        h.flow.settle()
        XCTAssertNil(h.flow.delivery.clipboard.text)
        XCTAssertNil(try h.store.load())
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), [])
    }

    func testRequestedIntentIsConsumedOnceAcrossChangeNotifications() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Body")
        try h.open()
        let edit = PickerModel.Intent.edit(identity: entry.identity, relativePath: "a.md")

        for expected in [edit, .openLibrary] {
            var delivered: [PickerModel.Intent] = []
            var notifications = 0
            h.picker.onChange = {
                notifications += 1
                if let intent = h.picker.takeRequestedIntent() { delivered.append(intent) }
            }
            switch expected {
            case .edit: h.picker.editSelected()
            case .openLibrary: h.picker.openLibrary()
            }
            h.picker.setQuery("")

            XCTAssertEqual(notifications, 2)
            XCTAssertEqual(delivered, [expected])
            XCTAssertNil(h.picker.requestedIntent)
            XCTAssertEqual(h.picker.state, .picker)
        }
    }

    func testDismissClosesFillAndRetainsDraftOnReopen() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{topic}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("kept draft", name: "topic")

        h.picker.dismiss()
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(form.state, .closed)
        XCTAssertNil(h.picker.fillModel)
        XCTAssertTrue(h.delivery.recorder.events.contains(.hide))
        form.deliver(mode: .copyOnly)
        XCTAssertNil(h.delivery.clipboard.readText())
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])

        h.picker.open()
        XCTAssertEqual(try h.openForm().fields[0].value, "kept draft")
    }

    func testDirectSelectionValidatesPositionAndUpdatesPreview() throws {
        let h = PromptFlowHarness()
        _ = try h.put("First", at: "a.md")
        _ = try h.put("Second", at: "b.md")
        try h.open()
        h.picker.selectResult(at: 1)
        XCTAssertEqual(h.picker.selectionIndex, 1)
        XCTAssertEqual(h.picker.selectedPreview, .body("Second"))
        h.picker.selectResult(at: -1)
        h.picker.selectResult(at: 2)
        XCTAssertEqual(h.picker.selectionIndex, 1)
        h.picker.dismiss()
        h.picker.selectResult(at: 0)
        XCTAssertEqual(h.picker.selectionIndex, 1)
    }

    func testDismissDoesNothingDuringFieldlessOrFillDelivery() throws {
        for source in ["Body", "{{topic}}"] {
            let h = PromptFlowHarness()
            _ = try h.put(source)
            try h.open()
            h.picker.use(mode: .copyOnly)
            if let form = h.picker.fillModel {
                form.setValue("filled", name: "topic")
                form.deliver(mode: .copyOnly)
            }
            XCTAssertEqual(h.picker.state, .delivering)
            let events = h.delivery.recorder.events

            h.picker.dismiss()
            XCTAssertEqual(h.picker.state, .delivering)
            XCTAssertEqual(h.delivery.recorder.events, events)
            h.settle()
            XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
            h.picker.dismiss()
            XCTAssertEqual(h.picker.state, .closed)
        }
    }

    func testEscapeDismissesCompletedFieldlessDeliveryButNotPendingDelivery() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body")
        try h.open()
        h.picker.use(mode: .copyOnly)
        h.picker.escape()
        XCTAssertEqual(h.picker.state, .delivering)
        XCTAssertFalse(h.delivery.recorder.events.contains(.hide))
        h.settle()
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
        let eventsBeforeDismiss = h.delivery.recorder.events.count
        h.picker.escape()
        h.delivery.main.drain()
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertEqual(Array(h.delivery.recorder.events.dropFirst(eventsBeforeDismiss)), [
            .hide, .restore(try XCTUnwrap(h.delivery.focus.target))
        ])
    }

    func testEscapeQueuesDismissalAfterPendingShowAndRestoresCapturedTarget() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("Body")
        try h.index.rebuild()
        h.delivery.main.drain()
        h.picker.open()
        h.picker.escape()
        XCTAssertEqual(h.picker.state, .closed)
        h.delivery.main.drain()
        XCTAssertEqual(h.delivery.recorder.events, [
            .capture, .show, .hide, .restore(try XCTUnwrap(h.delivery.focus.target))
        ])
    }

    func testFieldlessTopBudgetHotkeyReturnAndUsageLearning() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("First body")
        _ = try h.put("Second body", at: "b.md")
        try h.index.rebuild()
        let keys: [() -> Void] = [
            { h.picker.open() }, // hotkey
            { h.picker.use(mode: .paste(.standard)) } // Return
        ]
        XCTAssertEqual(keys.count, 2)
        keys.forEach { $0() }
        XCTAssertEqual(h.picker.state, .delivering)
        XCTAssertEqual(h.delivery.clipboard.readText(), "First body")
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        h.picker.use(mode: .copyOnly)
        h.picker.escape()
        h.picker.open()
        XCTAssertEqual(h.delivery.scheduler.delays.count, 1)
        h.settle()
        XCTAssertEqual(h.picker.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [h.clock.date])
    }

    func testReuseValuesBudgetHotkeyReturnReturn() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Explain {{topic}}")
        try h.values.record(identity: entry.identity, values: ["topic": "Swift"])
        try h.index.rebuild()
        let keys: [() throws -> Void] = [
            { h.picker.open() },
            { h.picker.use(mode: .paste(.standard)) },
            { try XCTUnwrap(h.picker.fillModel).deliver(mode: .paste(.standard)) }
        ]
        XCTAssertEqual(keys.count, 3)
        try keys.forEach { try $0() }
        XCTAssertEqual(h.delivery.clipboard.readText(), "Explain Swift")
        h.settle()
        XCTAssertEqual(h.picker.state, .done(.pasted(.cgEvent)))
    }

    func testChangeOneFieldBudgetThreeKeysPlusTyping() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Explain {{topic}}")
        try h.values.record(identity: entry.identity, values: ["topic": "Swift"])
        try h.index.rebuild()
        h.picker.open() // hotkey
        let form = try h.openForm() // Return
        form.setValue("Rust", name: "topic") // typing
        form.deliver(mode: .paste(.standard)) // Return
        h.settle()
        XCTAssertEqual(h.delivery.clipboard.readText(), "Explain Rust")
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), ["topic": "Rust"])
    }

    func testRarelyUsedPromptFoundWithTwoToFourLetters() throws {
        for letters in ["tr", "tra", "tran"] {
            let h = PromptFlowHarness()
            let frequent = try h.put("---\ntitle: Alpha\n---\nCommon", at: "common.md")
            _ = try h.put("---\ntitle: Translate\nfields:\n  text:\n    default: hello\n---\nTranslate {{text}}",
                          at: "rare.md")
            try h.usage.recordUse(identity: frequent.identity)
            try h.open() // hotkey
            XCTAssertEqual(h.picker.results.first?.title, "Alpha")
            XCTAssertTrue((2...4).contains(letters.count))
            h.picker.setQuery(letters)
            XCTAssertEqual(h.picker.results.first?.title, "Translate")
            let form = try h.openForm() // Return
            XCTAssertEqual(h.picker.state, .fill)
            form.deliver(mode: .paste(.standard)) // Return
            h.settle()
            XCTAssertEqual(h.delivery.clipboard.readText(), "Translate hello", letters)
        }
    }

    func testCancelFromPickerBudgetOneEscapeNeverDelivers() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Body")
        try h.open()

        h.picker.escape() // One Escape, with no selection or delivery intent.
        h.delivery.main.drain()

        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertTrue(h.delivery.recorder.events.contains(.hide))
        XCTAssertNil(h.delivery.clipboard.readText())
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        XCTAssertNil(try h.data.stamp(at: "values.json"))
    }

    func testEscapeChainKeepsValuesAndNeverDelivers() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{topic}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("kept draft", name: "topic")
        h.picker.escape()
        XCTAssertEqual(h.picker.state, .picker)
        XCTAssertNil(h.picker.fillModel)
        XCTAssertEqual(form.state, .closed)
        form.deliver(mode: .copyOnly) // retired views cannot deliver
        let reopened = try h.openForm()
        XCTAssertEqual(reopened.fields[0].value, "kept draft")
        h.picker.escape()
        h.picker.escape()
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertTrue(h.delivery.recorder.events.contains(.hide))
        XCTAssertNil(h.delivery.clipboard.readText())
        XCTAssertNil(try h.data.stamp(at: "values.json"))
        h.picker.open()
        XCTAssertEqual(try h.openForm().fields[0].value, "kept draft")
    }

    func testBlurAndReopenKeepsDraftWithoutDeliveryOrLearning() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{topic}}")
        try h.open()
        let form = try h.openForm()
        form.setValue("before blur", name: "topic")
        // A platform blur timer owns hiding. Models receive no delivery intent.
        FakePanel(h.delivery.recorder).hide()
        h.picker.open()
        XCTAssertEqual(form.state, .closed)
        XCTAssertEqual(try h.openForm().fields[0].value, "before blur")
        XCTAssertNil(h.delivery.clipboard.readText())
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
    }

    func testNoMatchesCarriesQueryAndUnwiredAffordances() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Existing")
        try h.open()
        h.picker.setQuery("zzzzz")
        XCTAssertNil(PromptFlowHarness().picker.noMatches)
        let empty = try XCTUnwrap(h.picker.noMatches)
        XCTAssertEqual(empty.query, "zzzzz")
        XCTAssertEqual(empty.message, "No prompts match 'zzzzz'")
        XCTAssertEqual(empty.createTitle, "zzzzz")
        XCTAssertEqual(empty.createLabel, "Create a prompt")
        XCTAssertEqual(empty.writeLabel, "Write with the assistant")
        XCTAssertEqual(empty.openLibraryLabel, "Open the library folder")
        XCTAssertNil(h.picker.selectionIndex)
        XCTAssertEqual(h.picker.selectedPreview, .none)
        h.picker.use(mode: .paste(.standard))
        h.picker.editSelected()
        XCTAssertNil(h.picker.requestedIntent)
        h.picker.openLibrary()
        XCTAssertEqual(h.picker.requestedIntent, .openLibrary)
        XCTAssertNil(h.delivery.clipboard.readText())
    }

    func testValidationErrorAndFutureSelectionShowIssuesBlockAllDeliveryModes() throws {
        for source in ["---\ntitle: [bad\n---\nBody", "---\nformat: 2\n---\nBody"] {
            let h = PromptFlowHarness()
            let entry = try h.put(source)
            try h.open()
            XCTAssertTrue(h.picker.results[0].hasIssues)
            XCTAssertFalse(h.picker.results[0].canRender)
            XCTAssertEqual(h.picker.selectedPreview, .issues(entry.issues))
            for mode: DeliveryMode in [.paste(.standard), .paste(.terminal), .copyOnly] {
                h.picker.use(mode: mode)
                XCTAssertEqual(h.picker.state, .picker)
            }
            XCTAssertNil(h.picker.fillModel)
            XCTAssertNil(h.delivery.clipboard.readText())
            XCTAssertEqual(h.delivery.clipboard.readCount, 0)
            h.picker.editSelected()
            XCTAssertEqual(h.picker.requestedIntent, .edit(identity: entry.identity, relativePath: "a.md"))
        }
    }

    func testRowsSelectionLimitsOpenResetsTopKeepsQueryAndUnavailableBannerInput() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\ntitle: Alpha\ndescription: Preview line\ntags: [code, review]\nfavorite: true\n---\nBody",
                              at: "folder/a.md")
        _ = try h.put("---\ntitle: Beta\n---\nOther")
        try h.open()
        let row = h.picker.results[0]
        XCTAssertEqual(row.identity, entry.identity)
        XCTAssertEqual(row.title, "Alpha")
        XCTAssertEqual(row.folder, "folder")
        XCTAssertEqual(row.tags, ["code", "review"])
        XCTAssertTrue(row.favorite)
        XCTAssertEqual(row.previewLine, "Preview line")
        XCTAssertFalse(row.hasIssues)
        XCTAssertTrue(row.canRender)
        h.picker.moveSelection(.up)
        XCTAssertEqual(h.picker.selectionIndex, 0)
        h.picker.moveSelection(.down)
        h.picker.moveSelection(.down)
        XCTAssertEqual(h.picker.selectionIndex, 1)
        XCTAssertEqual(h.picker.selectedPreview, .body("Other"))
        h.picker.open()
        XCTAssertEqual(h.picker.selectionIndex, 0)
        h.picker.setQuery("Alpha")
        h.picker.open()
        XCTAssertEqual(h.picker.query, "Alpha")
        var changes = 0
        h.picker.onChange = { changes += 1 }
        h.picker.libraryAvailable = false
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(h.picker.libraryAvailable)
        h.picker.use(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.delivery.clipboard.readText(), "Body")
    }

    func testIndexPublishesMarshalToMainAndKeepSelectedPathWhenRowsMove() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("Body", at: "b.md")
        try h.open()
        var callbackRanOnMain = false
        h.picker.onChange = { callbackRanOnMain = h.delivery.main.isRunning }
        _ = try h.put("Earlier", at: "a.md")
        try h.index.apply(LibraryChangeSet(created: ["a.md"]))
        XCTAssertEqual(h.picker.results.map(\.relativePath), ["b.md"])
        XCTAssertFalse(callbackRanOnMain)
        h.delivery.main.drain()
        XCTAssertTrue(callbackRanOnMain)
        XCTAssertEqual(h.picker.results.map(\.relativePath), ["a.md", "b.md"])
        XCTAssertEqual(h.picker.selectionIndex, 1)
        callbackRanOnMain = false
        try h.library.delete(at: "b.md")
        try h.index.apply(LibraryChangeSet(deleted: ["b.md"]))
        h.delivery.main.drain()
        XCTAssertTrue(callbackRanOnMain)
        XCTAssertEqual(h.picker.selectionIndex, 0)
        XCTAssertEqual(h.picker.selectedPreview, .body("Earlier"))
    }

    func testFieldlessClipboardReadStartsOnlyOnUseAndEscapeCancelsPendingDelivery() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{clipboard}}")
        try h.open()
        h.picker.moveSelection(.up)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        h.delivery.clipboard.readMode = .deferred
        h.picker.use(mode: .copyOnly)
        XCTAssertTrue(h.picker.isResolvingBuiltins)
        h.picker.use(mode: .copyOnly)
        XCTAssertEqual(h.delivery.clipboard.readCount, 1)
        h.picker.escape()
        h.delivery.clipboard.completeRead("late text")
        XCTAssertEqual(h.picker.state, .closed)
        XCTAssertNil(h.delivery.clipboard.readText())
        h.picker.open()
        h.picker.use(mode: .copyOnly)
        h.delivery.clipboard.completeRead("ready text")
        h.settle()
        XCTAssertEqual(h.delivery.clipboard.readText(), "ready text")
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
    }

    func testQueryChangeCancelsPendingFieldlessSnapshotAndRetainsNewSelection() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{clipboard}}", at: "a.md")
        _ = try h.put("Other", at: "b.md")
        try h.open()
        h.delivery.clipboard.readMode = .deferred
        h.picker.use(mode: .copyOnly)
        h.picker.setQuery("b")
        h.delivery.clipboard.completeRead("stale")
        XCTAssertNil(h.delivery.clipboard.readText())
        XCTAssertEqual(h.picker.results.first?.relativePath, "b.md")
        XCTAssertEqual(h.picker.state, .picker)
    }

    func testUsageFailureStillDeliversWithVisibleWarningAndRankingUnchanged() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Body")
        try h.open()
        h.data.failNextWrite = true
        h.picker.use(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(h.delivery.clipboard.readText(), "Body")
        XCTAssertEqual(h.picker.persistenceWarnings, [.usageNotSaved])
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        XCTAssertEqual(h.index.search("").first?.score, 0)
        h.picker.open()
        XCTAssertEqual(h.picker.persistenceWarnings, [.usageNotSaved])
        h.picker.use(mode: .copyOnly)
        XCTAssertEqual(h.picker.persistenceWarnings, [])
        h.settle()
    }
}
