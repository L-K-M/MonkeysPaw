import Foundation
import XCTest
@testable import MonkeysPawCore

final class RepeatServiceTests: XCTestCase {
    private let assigned = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\n"

    func testPickerAndFillRecordEveryCompletedUserOutcomeExactlyOnce() throws {
        for filled in [false, true] {
            for mode: DeliveryMode in [.paste(.standard), .copyOnly] {
                for fallback in [false, true] {
                    let h = try RepeatHarness()
                    let entry = try h.put(filled ? "{{field}}" : "body")
                    if fallback { h.flow.delivery.injectors.values.forEach { $0.result = .failed(.permissionDenied) } }
                    var records = 0
                    h.flow.data.onWrite = { if $0 == "last-delivery.json" { records += 1 } }
                    try h.open()
                    h.picker.use(mode: mode)
                    if let form = h.picker.fillModel { form.setValue("exact", name: "field"); form.deliver(mode: mode) }
                    XCTAssertNil(try h.store.load(), "Pending deliveries must not record.")
                    h.flow.settle()
                    h.flow.delivery.scheduler.repeatLastCallback()
                    XCTAssertEqual(records, 1)
                    XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 1)
                    XCTAssertEqual(try h.store.load()?.rememberedValues, filled ? ["field": "exact"] : [:])
                    let results = h.repeatNow()
                    XCTAssertEqual(results.count, 1)
                    XCTAssertEqual(records, 2)
                    XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 2)
                }
            }
        }
    }

    func testPreviewCancellationAndSelfTestNeverCreateARecord() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.open()
        h.picker.use(mode: .copyOnly)
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("draft only", name: "field")
        form.escape()
        XCTAssertNil(try h.store.load())
        h.flow.delivery.service.performSelfTest { release in
            h.flow.delivery.service.deliverForSelfTest("diagnostic", through: .cgEvent) { _ in release() }
        }
        h.flow.settle()
        XCTAssertNil(try h.store.load())
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), [])
    }

    func testFreshBuiltinsAndExactEmptyAndNonRememberedFields() throws {
        let h = try RepeatHarness()
        _ = try h.put("""
        ---
        fields:
          empty: {optional: true, default: fallback}
          secret: {remember: false}
        ---
        {{empty}}|{{secret}}|{{date}}|{{time}}|{{clipboard}}
        """)
        h.flow.delivery.clipboard.replaceText("first clipboard")
        try h.deliver(values: ["empty": "", "secret": "{{literal}} "])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "|{{literal}} |1970-01-01|00:00|first clipboard")
        let disk = try XCTUnwrap(h.store.load())
        XCTAssertEqual(disk.rememberedValues, ["empty": ""])
        XCTAssertTrue(disk.requiresSessionValues)
        h.flow.clock.date = Date(timeIntervalSince1970: 90_000)
        h.flow.delivery.clipboard.replaceText("fresh clipboard")
        let reads = h.flow.delivery.clipboard.readCount
        XCTAssertEqual(h.repeatNow(), [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "|{{literal}} |1970-01-02|01:00|fresh clipboard")
        XCTAssertEqual(h.flow.delivery.clipboard.readCount, reads + 1)
        XCTAssertFalse(try h.flow.data.text(at: "last-delivery.json").contains("fresh clipboard"))
    }

    func testRestartRequiresCompleteSnapshotAndLatestSessionOnlyMarkerReplacesOlderUse() throws {
        let h = try RepeatHarness()
        _ = try h.put("old fieldless", at: "a.md")
        try h.deliver(mode: .copyOnly)
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.delivered(.copiedOnly(.requested), [])])
        try h.flow.library.delete(at: "a.md")
        let entry = try h.put("---\nfields:\n  field: {remember: false, default: unsafe-default}\n---\n{{field}}")
        try h.deliver(mode: .copyOnly, values: ["field": "session value"])
        let before = h.flow.delivery.recorder.events.count
        let restarted = h.restart()
        XCTAssertEqual(h.repeatNow(using: restarted), [.reviewRequired(
            RepeatPromptReference(identity: entry.identity, relativePath: entry.relativePath), .sessionOnlyValues)])
        XCTAssertEqual(h.flow.delivery.recorder.events.dropFirst(before).filter {
            if case .write = $0 { return true }; return false
        }.count, 0)
        XCTAssertFalse(try h.flow.data.text(at: "last-delivery.json").contains("session value"))
    }

    func testRestartPreservesExactRememberedEmptyInsteadOfCurrentValuesStore() throws {
        let h = try RepeatHarness()
        let entry = try h.put("---\nfields:\n  field: {optional: true, default: default}\n---\n[{{field}}]")
        try h.deliver(mode: .copyOnly, values: ["field": ""])
        try h.flow.values.record(identity: entry.identity, values: ["field": "different remembered value"])
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.delivered(.copiedOnly(.requested), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "[]")
    }

    func testNoClipboardReadForUnusedBuiltinAndDateIsFixedBeforeBackgroundWork() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("{{date}} {{time}}")
        try h.deliver()
        h.flow.clock.date = Date(timeIntervalSince1970: 90_000)
        let reads = h.flow.delivery.clipboard.readCount
        var results: [RepeatResult] = []
        h.service.repeatLast { results.append($0) }
        h.flow.clock.date = Date(timeIntervalSince1970: 180_000)
        h.held.releaseAll()
        h.flow.settle()
        h.held.releaseAll()
        XCTAssertEqual(results, [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "1970-01-02 01:00")
        XCTAssertEqual(h.flow.delivery.clipboard.readCount, reads)
    }

    func testCurrentTargetAndSessionAreImmutableWhileBuiltinsResolve() throws {
        let h = try RepeatHarness()
        _ = try h.put("{{clipboard}}")
        try h.deliver()
        h.flow.delivery.clipboard.readMode = .deferred
        let target = DeliveryTarget.macOS(processID: 77, bundleID: "fresh.target")
        h.flow.delivery.focus.target = target
        var results: [RepeatResult] = []
        h.service.repeatLast { results.append($0) }
        h.flow.delivery.focus.target = .macOS(processID: 88, bundleID: "later.target")
        h.flow.delivery.service.arm()
        h.flow.delivery.session.session = .otherX11
        h.flow.delivery.clipboard.completeRead("fresh")
        h.flow.delivery.scheduler.advance(by: Limits.settleDelayMacOS)
        XCTAssertEqual(results, [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.recorder.events.last(where: { if case .restore = $0 { return true }; return false }), .restore(target))
    }

    func testKnownClipboardBuiltinIsCapturedBeforeBackgroundSourceValidation() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("{{clipboard}}")
        try h.deliver()
        h.flow.delivery.clipboard.replaceText("at invocation")
        let reads = h.flow.delivery.clipboard.readCount
        var results: [RepeatResult] = []
        h.service.repeatLast { results.append($0) }
        XCTAssertEqual(h.flow.delivery.clipboard.readCount, reads + 1)
        h.flow.delivery.clipboard.replaceText("after invocation")
        h.held.releaseAll()
        h.flow.settle()
        h.held.releaseAll()
        XCTAssertEqual(results, [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "at invocation")
    }

    func testNewCompletedDeliveryIsVisibleToReentrantRepeatAfterCancellation() throws {
        let h = try RepeatHarness()
        _ = try h.put("---\ntitle: Old\n---\n{{clipboard}}")
        try h.deliver()
        _ = try h.put("---\ntitle: New\n---\nnew body", at: "b.md")
        h.flow.delivery.clipboard.readMode = .deferred
        var results: [RepeatResult] = []
        h.service.repeatLast { result in
            results.append(result)
            if result == .cancelled { h.service.repeatLast { results.append($0) } }
        }
        try h.open()
        h.picker.setQuery("New")
        h.picker.use(mode: .paste(.standard))
        h.flow.settle()
        XCTAssertEqual(h.flow.delivery.clipboard.readCount, 2, "The new fieldless delivery must replace the snapshot before callbacks run.")
        h.flow.delivery.clipboard.completeRead("late old builtin")
        h.flow.settle()
        XCTAssertEqual(results, [.cancelled, .delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "new body")
    }

    func testCopyIntentPersistsWhilePasteChordUsesCurrentPolicy() throws {
        let h = try RepeatHarness(session: .otherX11)
        _ = try h.put("body")
        try h.deliver(mode: .paste(.terminal))
        h.access.chord = .standard
        XCTAssertEqual(h.repeatNow(), [.delivered(.pasted(.xdotool), [])])
        XCTAssertEqual(h.flow.delivery.injectors[.xdotool]?.chords, [.terminal, .standard])
        try h.deliver(mode: .copyOnly)
        h.access.chord = .terminal
        let count = h.flow.delivery.injectors[.xdotool]?.chords.count
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.delivered(.copiedOnly(.requested), [])])
        XCTAssertEqual(h.flow.delivery.injectors[.xdotool]?.chords.count, count)
    }

    func testAssignedIdentityFollowsMoveAndRejectsReusedHintAndDuplicateID() throws {
        let h = try RepeatHarness()
        let entry = try h.put(assigned + "body")
        try h.deliver(mode: .copyOnly)
        let moved = try h.flow.service.move(from: "a.md", to: "moved.md")
        _ = try h.put("replacement", at: "a.md")
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.delivered(.copiedOnly(.requested), [])])
        XCTAssertEqual(try h.store.load()?.relativePath, "moved.md")
        XCTAssertEqual(try h.store.load()?.identity, moved.identity)
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 2)
        _ = try h.put(assigned + "body", at: "duplicate.md")
        XCTAssertEqual(h.repeatNow(), [.reviewRequired(
            RepeatPromptReference(identity: entry.identity, relativePath: "a.md"), .sourceUnavailable)])
    }

    func testIdlessReplacementWithIdenticalBytesRequiresReviewWithoutAssigningID() throws {
        let h = try RepeatHarness()
        let entry = try h.put("body")
        try h.deliver()
        try h.flow.library.delete(at: "a.md")
        _ = try h.put("body")
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.reviewRequired(
            RepeatPromptReference(identity: entry.identity, relativePath: "a.md"), .sourceChanged)])
        XCTAssertNil(try h.flow.service.load(at: "a.md").document.frontMatter.id)
    }

    func testChangedDeletedAndInaccessibleSourceNeverWritesOrPastes() throws {
        for change in 0..<4 {
            let h = try RepeatHarness()
            let entry = try h.put(assigned + "body")
            try h.deliver()
            switch change {
            case 0: _ = try h.put(assigned + "changed")
            case 1: try h.flow.library.delete(at: "a.md")
            case 2: h.flow.library.onRead = { _ in throw FileStoreError.ioFailure }
            default: h.access.allowed = false
            }
            let before = h.flow.delivery.recorder.events.count
            XCTAssertEqual(h.repeatNow(), [.reviewRequired(
                RepeatPromptReference(identity: entry.identity, relativePath: "a.md"),
                change == 0 ? .sourceChanged : .sourceUnavailable)])
            let events = h.flow.delivery.recorder.events.dropFirst(before)
            XCTAssertFalse(events.contains { if case .write = $0 { return true }; if case .paste = $0 { return true }; return false })
        }
    }

    func testSourceAndAccessRecheckedDuringBuiltinResolution() throws {
        for change in 0..<4 {
            let h = try RepeatHarness()
            let entry = try h.put(assigned + "{{clipboard}}")
            try h.deliver()
            h.flow.delivery.clipboard.readMode = .deferred
            var results: [RepeatResult] = []
            h.service.repeatLast { results.append($0) }
            switch change {
            case 0: _ = try h.put(assigned + "changed {{clipboard}}")
            case 1: try h.flow.library.delete(at: "a.md")
            case 2: h.flow.library.onRead = { _ in throw FileStoreError.ioFailure }
            default: h.access.allowed = false
            }
            let before = h.flow.delivery.recorder.events.count
            h.flow.delivery.clipboard.completeRead("fresh")
            h.flow.settle()
            XCTAssertEqual(results, [.reviewRequired(
                RepeatPromptReference(identity: entry.identity, relativePath: "a.md"),
                change == 0 ? .sourceChanged : .sourceUnavailable)])
            XCTAssertFalse(h.flow.delivery.recorder.events.dropFirst(before).contains {
                if case .write = $0 { return true }; if case .paste = $0 { return true }; return false
            })
        }
    }

    func testQueuedRepeatRevalidatesSourceBeforeClipboardWrite() throws {
        let h = try RepeatHarness()
        let entry = try h.put(assigned + "body")
        try h.deliver()
        var release: (() -> Void)?
        h.flow.delivery.service.performSelfTest { release = $0 }
        var results: [RepeatResult] = []
        h.service.repeatLast { results.append($0) }
        _ = try h.put(assigned + "changed")
        let text = h.flow.delivery.clipboard.text
        release?()
        XCTAssertEqual(results, [.reviewRequired(RepeatPromptReference(identity: entry.identity, relativePath: "a.md"), .sourceChanged)])
        XCTAssertEqual(h.flow.delivery.clipboard.text, text)
    }

    func testSourceRecheckedAfterOptionalClipboardRestoreSnapshotAndBeforePaste() throws {
        for duringRestore in [true, false] {
            let h = try RepeatHarness()
            let entry = try h.put(assigned + "body")
            try h.deliver()
            h.flow.delivery.service.setClipboardRestore(.previousText)
            h.flow.delivery.clipboard.snapshotMode = .deferred
            var results: [RepeatResult] = []
            h.service.repeatLast { results.append($0) }
            if duringRestore { _ = try h.put(assigned + "changed") }
            h.flow.delivery.clipboard.completeSnapshot()
            if !duringRestore { _ = try h.put(assigned + "changed") }
            let pastes = h.flow.delivery.injectors[.cgEvent]?.chords.count
            h.flow.settle()
            XCTAssertEqual(results, [.reviewRequired(RepeatPromptReference(identity: entry.identity, relativePath: "a.md"), .sourceChanged)])
            XCTAssertEqual(h.flow.delivery.injectors[.cgEvent]?.chords.count, pastes)
        }
    }

    func testForgetMatchingAllAndNonmatchingValuesAcrossRestart() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.deliver(values: ["field": "kept"])
        try h.service.forgetValues(for: PromptIdentity(path: "other.md", id: nil))
        XCTAssertEqual(h.repeatNow(), [.delivered(.pasted(.cgEvent), [])])
        try h.service.forgetValues(for: entry.identity)
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
        try h.deliver(values: ["field": "again"])
        XCTAssertEqual(h.picker.forgetAllValues(), .forgotten)
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
    }

    func testForgetBoundaryFailsBeforeClearingValuesOrDraftsAndCanBeRetried() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.deliver(values: ["field": "remembered"])
        try h.open()
        h.picker.use(mode: .paste(.standard))
        let form = try XCTUnwrap(h.picker.fillModel)
        form.setValue("draft", name: "field")
        h.flow.data.failNextWrite = true
        h.picker.forgetSelectedValues()
        XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(form.values, ["field": "draft"])
        XCTAssertEqual(try h.flow.values.rememberedValues(for: entry.identity), ["field": "remembered"])
        XCTAssertEqual(h.repeatNow(), [.unavailable(.invalidationFailed)])
        XCTAssertNotNil(try LastDeliveryStore(files: h.flow.data).load(), "A failed clear cannot promise durable removal.")
        h.picker.forgetSelectedValues()
        XCTAssertNil(h.picker.forgetValuesError)
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
    }

    func testSwitchSignOutAndRootReplacementRejectOldBindingsAcrossRestart() throws {
        let h = try RepeatHarness()
        let user = try XCTUnwrap(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        let account = try RepeatBinding(root: "/library", serverURL: "https://sync.example", userID: user)
        for binding in [try RepeatBinding(root: "/other"), account] {
            _ = try h.put("body")
            try h.deliver()
            XCTAssertEqual(h.repeatNow(using: h.restart(binding: binding)), [.nothingToRepeat])
            XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
        }
        _ = try h.put("body")
        try h.deliver()
        try h.service.retire()
        XCTAssertEqual(h.repeatNow(), [.unavailable(.inactive)])
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
    }

    func testFailedBindingInvalidationStaysDisabledUntilDurableRetry() throws {
        let h = try RepeatHarness()
        _ = try h.put("body")
        try h.deliver()
        h.flow.data.failNextWrite = true
        XCTAssertThrowsError(try h.service.retire()) { XCTAssertEqual($0 as? RepeatFailure, .invalidationFailed) }
        XCTAssertEqual(h.repeatNow(), [.unavailable(.invalidationFailed)])
        let restarted = h.restart(binding: try RepeatBinding(root: "/other"))
        h.flow.data.failNextWrite = true
        XCTAssertEqual(h.repeatNow(using: restarted), [.unavailable(.invalidationFailed)])
        try h.service.retire()
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
    }

    func testNonmatchingForgetCannotEnableRepeatWithoutRepairingFailedInvalidation() throws {
        let h = try RepeatHarness()
        _ = try h.put("body")
        try h.deliver()
        h.flow.data.failNextWrite = true
        XCTAssertThrowsError(try h.service.forgetValues())
        h.flow.data.failNextWrite = true
        XCTAssertThrowsError(try h.service.forgetValues(for: PromptIdentity(path: "other.md", id: nil)))
        XCTAssertEqual(h.repeatNow(), [.unavailable(.invalidationFailed)])
        try h.service.forgetValues(for: PromptIdentity(path: "other.md", id: nil))
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
    }

    func testForgetAndRetirementCancelLateBuiltinQueueSettleAndFocusContinuations() throws {
        for stage in 0..<4 {
            let h = try RepeatHarness()
            _ = try h.put(stage == 0 ? "{{clipboard}}" : "body")
            try h.deliver()
            var release: (() -> Void)?
            if stage == 0 { h.flow.delivery.clipboard.readMode = .deferred }
            if stage == 1 { h.flow.delivery.service.performSelfTest { release = $0 } }
            if stage == 3 { h.flow.delivery.focus.mode = .deferred }
            var results: [RepeatResult] = []
            h.service.repeatLast { results.append($0) }
            if stage == 3 { h.flow.settle() }
            try h.service.retire()
            let before = h.flow.delivery.recorder.events.count
            if stage == 0 { h.flow.delivery.clipboard.completeRead("late") }
            if stage == 1 { release?() }
            if stage == 3 { h.flow.delivery.focus.complete([.confirmed, .confirmed]) }
            h.flow.settle()
            XCTAssertEqual(results, [.cancelled])
            XCTAssertNil(try h.store.load())
            XCTAssertFalse(h.flow.delivery.recorder.events.dropFirst(before).contains {
                if case .write = $0 { return true }; if case .paste = $0 { return true }; return false
            })
        }
    }

    func testLateNormalDeliveryAndQueuedRecordingCannotRecreateClearedState() throws {
        for heldRecord in [false, true] {
            let h = try RepeatHarness(heldWork: heldRecord)
            let entry = try h.put("{{field}}")
            try h.open()
            h.picker.use(mode: .paste(.standard))
            let form = try XCTUnwrap(h.picker.fillModel)
            form.setValue("late secret", name: "field")
            form.deliver(mode: .paste(.standard))
            if heldRecord { h.flow.settle() }
            try h.service.retire()
            let usage = try h.flow.usage.useEvents(for: entry.identity)
            h.flow.settle()
            h.held.releaseAll()
            XCTAssertNil(try h.store.load())
            XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), usage)
            XCTAssertFalse(h.service.isBusy)
        }
    }

    func testPersistenceFailureWarnsWithoutUndoingDeliveryAndRetiresOlderRecord() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.deliver(values: ["field": "old"])
        let large = String(repeating: "x", count: Limits.lastDeliveryFileCapBytes)
        var warnings: [PromptPersistenceWarning] = []
        h.service.recordCompleted(entry: entry, values: ["field": large], mode: .copyOnly,
                                  ticket: h.service.beginRecording()) { warnings = $0 }
        XCTAssertEqual(warnings, [.lastDeliveryNotSaved])
        XCTAssertNil(try h.store.load())
        XCTAssertEqual(h.repeatNow(using: h.restart()), [.nothingToRepeat])
        XCTAssertEqual(h.repeatNow(), [.delivered(.copiedOnly(.requested), [.lastDeliveryNotSaved])])
        XCTAssertEqual(h.flow.delivery.clipboard.text?.count, large.count)
    }

    func testFailedRecordAndTombstoneDisableRepeatWithoutReportingSaved() throws {
        let h = try RepeatHarness()
        let entry = try h.put("body")
        try h.deliver()
        h.flow.data.failNextWrite = true
        h.flow.data.failWriteNumber = h.flow.data.writeCount + 2
        var warnings: [PromptPersistenceWarning] = []
        h.service.recordCompleted(entry: entry, values: [:], mode: .copyOnly,
                                  ticket: h.service.beginRecording()) { warnings = $0 }
        XCTAssertEqual(warnings, [.lastDeliveryNotSaved])
        XCTAssertEqual(h.repeatNow(), [.unavailable(.invalidationFailed)])
        try h.service.forgetValues()
        XCTAssertNil(try h.store.load())
    }

    func testOverlappingRepeatIsDroppedThroughRecordingAndDuplicateCallbacksCountOnce() throws {
        let h = try RepeatHarness(heldWork: true)
        let entry = try h.put("body")
        try h.deliver()
        h.flow.delivery.injectors[.cgEvent]?.mode = .deferred
        var results: [RepeatResult] = []
        XCTAssertTrue(h.service.repeatLast { results.append($0) })
        XCTAssertFalse(h.service.repeatLast { _ in XCTFail("Overlapping repeat must be dropped.") })
        h.held.releaseAll()
        h.flow.settle()
        h.held.releaseAll()
        h.flow.delivery.injectors[.cgEvent]?.complete([.sent, .sent])
        XCTAssertTrue(h.service.isBusy)
        XCTAssertFalse(h.service.repeatLast { _ in XCTFail("Recording still owns repeat's busy guard.") })
        h.held.releaseAll()
        h.flow.delivery.scheduler.repeatLastCallback()
        XCTAssertEqual(results, [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity).count, 2)
    }

    func testOwnSettingsOrLibraryWindowIsRefusedInitiallyAndAfterAsyncWork() throws {
        let h = try RepeatHarness()
        _ = try h.put("{{clipboard}}")
        try h.deliver()
        h.access.ownWindow = true
        let reads = h.flow.delivery.clipboard.readCount
        XCTAssertEqual(h.repeatNow(), [.unavailable(.ownWindow)])
        XCTAssertEqual(h.flow.delivery.clipboard.readCount, reads)
        h.access.ownWindow = false
        h.flow.delivery.clipboard.readMode = .deferred
        var results: [RepeatResult] = []
        h.service.repeatLast { results.append($0) }
        h.access.ownWindow = true
        let before = h.flow.delivery.recorder.events.count
        h.flow.delivery.clipboard.completeRead("late")
        h.flow.settle()
        XCTAssertEqual(results, [.cancelled])
        XCTAssertFalse(h.flow.delivery.recorder.events.dropFirst(before).contains { if case .write = $0 { return true }; return false })
    }

    func testBackgroundLoadAndValidationNeverReadSourceOnUIThread() throws {
        let h = try RepeatHarness(heldWork: true)
        _ = try h.put("body")
        try h.deliver()
        h.flow.library.onRead = { _ in XCTAssertFalse(h.marker.isUI) }
        h.marker.ui { h.service.load() }
        XCTAssertFalse(h.held.pending.isEmpty)
        h.held.releaseAll()
        _ = h.marker.ui { h.service.repeatLast { _ in } }
        h.held.releaseAll()
        h.flow.settle()
        h.held.releaseAll()
    }

    func testLoadRetainsFullSessionSnapshot() throws {
        let h = try RepeatHarness()
        _ = try h.put("---\nfields:\n  field: {remember: false}\n---\n{{field}}")
        try h.deliver(values: ["field": "session"])
        h.model.load()
        XCTAssertEqual(h.model.availability, .ready)
        XCTAssertEqual(h.repeatNow(), [.delivered(.pasted(.cgEvent), [])])
        XCTAssertEqual(h.flow.delivery.clipboard.text, "session")
    }

    func testInMemorySnapshotDoesNotLeakThroughDescriptionOrReflection() throws {
        let h = try RepeatHarness()
        _ = try h.put("---\nfields:\n  field: {remember: false}\n---\nprivate-body {{field}}")
        try h.deliver(values: ["field": "session-secret-sentinel"])
        var output = ""
        dump(h.service, to: &output)
        XCTAssertFalse(output.contains("session-secret-sentinel"))
        XCTAssertFalse(output.contains("private-body"))
    }
}
