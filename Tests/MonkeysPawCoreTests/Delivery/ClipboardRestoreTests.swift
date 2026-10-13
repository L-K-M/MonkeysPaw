import Foundation
@testable import MonkeysPawCore
import XCTest

final class ClipboardRestoreTests: XCTestCase {
    private func enabled(session: DesktopSession = .macOS) -> DeliveryHarness {
        let h = DeliveryHarness(session: session, clipboardRestore: .previousText)
        h.clipboard.replaceText("previous")
        h.arm()
        return h
    }

    private func completePaste(_ h: DeliveryHarness) {
        h.deliver()
        h.settle()
    }

    private func doneCount(_ h: DeliveryHarness) -> Int {
        h.recorder.events.filter { if case .done = $0 { return true }; return false }.count
    }

    func testOffHasZeroClipboardReadsAndNoExtraDelay() {
        let h = DeliveryHarness()
        h.clipboard.replaceText("previous")
        h.clipboard.snapshotMode = .deferred
        h.arm()
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))

        XCTAssertEqual(h.clipboard.readCount, 0)
        XCTAssertEqual(h.clipboard.ownershipWrites, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.scheduler.delays, [Limits.settleDelayMacOS])
        XCTAssertEqual(h.clipboard.text, "test")
    }

    func testCaptureIsBoundedAndPrecedesWriteHideFocusAndPaste() throws {
        for session in [DesktopSession.macOS, .gnomeWayland] {
            let h = enabled(session: session)
            h.deliver()
            XCTAssertEqual(h.clipboard.snapshotBudgets, [.milliseconds(250)])
            XCTAssertEqual(h.clipboard.snapshotByteLimits, [1_048_576])
            XCTAssertEqual(h.clipboard.ownershipWrites, 1)
            let events = h.recorder.events
            let capture = try XCTUnwrap(events.firstIndex(of: .snapshotClipboard))
            let write = try XCTUnwrap(events.firstIndex(of: .write("test")))
            let hide = try XCTUnwrap(events.firstIndex(of: .hideForDelivery))
            XCTAssertLessThan(capture, write)
            XCTAssertLessThan(write, hide)
            XCTAssertTrue(h.injectors.values.allSatisfy { $0.chords.isEmpty })
            h.settle()
            let settled = h.recorder.events
            let focus = try XCTUnwrap(settled.firstIndex(of: .restore(try XCTUnwrap(h.focus.target))))
            let backend: PasteBackend = session == .macOS ? .cgEvent : .remoteDesktopPortal
            let paste = try XCTUnwrap(settled.firstIndex(of: .paste(backend, .standard)))
            XCTAssertLessThan(hide, focus)
            XCTAssertLessThan(focus, paste)
            XCTAssertEqual(doneCount(h), 1)
        }
    }

    func testRestoreWaits750MillisecondsAfterSentAndDoneDoesNotWait() {
        let h = enabled()
        h.injectors[.cgEvent]?.mode = .deferred
        h.deliver()
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 0)

        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(doneCount(h), 1)
        XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.cgEvent))
        h.scheduler.advance(by: Limits.clipboardRestoreDelay - .milliseconds(1))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        h.scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(h.clipboard.restoreCalls, 1)
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertEqual(h.clipboard.text, "previous")
        XCTAssertNil(h.clipboard.lastSnapshot)
        XCTAssertEqual(doneCount(h), 1)
    }

    func testNilOrFailedReadLeavesDeliveredTextAndReleasesSnapshot() {
        for unavailable in [false, true] {
            let h = enabled()
            if unavailable { h.clipboard.snapshotUnavailable = true }
            else { h.clipboard.replaceText(nil) }
            completePaste(h)
            h.scheduler.advance(by: .seconds(2))
            XCTAssertEqual(h.clipboard.readCount, 1)
            XCTAssertEqual(h.clipboard.ownershipWrites, 0)
            XCTAssertEqual(h.clipboard.restoreCalls, 0)
            XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
            XCTAssertEqual(h.clipboard.text, "test")
            XCTAssertNil(h.clipboard.lastSnapshot)
            XCTAssertEqual(doneCount(h), 1)
        }
    }

    func testTimeoutCancelsReadWritesOnceAndIgnoresLateCompletion() {
        let h = enabled()
        h.clipboard.snapshotMode = .deferred
        h.deliver()
        h.scheduler.advance(by: .milliseconds(249))
        XCTAssertFalse(h.recorder.events.contains(.hideForDelivery))
        XCTAssertFalse(h.recorder.events.contains(.write("test")))
        h.scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.clipboard.completeSnapshot(repeating: 2)
        h.settle()
        h.scheduler.advance(by: .seconds(2))

        XCTAssertEqual(h.recorder.events.filter { $0 == .write("test") }.count, 1)
        XCTAssertEqual(h.recorder.events.filter { $0 == .hideForDelivery }.count, 1)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 1)
    }

    func testSnapshotJustBeforeDeadlineCanRestore() {
        let h = enabled()
        h.clipboard.snapshotMode = .deferred
        h.deliver()
        h.scheduler.advance(by: Limits.clipboardSnapshotBudget - .nanoseconds(1))
        h.clipboard.completeSnapshot()
        h.settle()
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertEqual(h.clipboard.text, "previous")
        XCTAssertEqual(h.clipboard.snapshotCancellations, 0)
    }

    func testLateReadSkipsRestoreEvenBeforeTimeoutCallbackRuns() {
        let h = enabled()
        // Stall the owning loop past ContinuousClock's monotonic capture deadline
        // while the fake scheduler's timeout remains pending.
        h.clipboard.onSnapshot = { Thread.sleep(forTimeInterval: 0.3) }
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.readCount, 1)
        XCTAssertEqual(h.clipboard.ownershipWrites, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.clipboard.onSnapshot = nil
    }

    func testOversizeUsesUtf8BytesAndSkipsRestore() {
        let h = enabled()
        h.clipboard.replaceText(String(repeating: "🧪", count: Limits.clipboardSnapshotMaxBytes / 4) + "x")
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.readCount, 1)
        XCTAssertEqual(h.clipboard.ownershipWrites, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertNil(h.clipboard.lastSnapshot)
    }

    func testRejectedDeferredCaptureCancelsReadAndContinuesDeliveryOnce() {
        for previous in [nil, String(repeating: "x", count: Limits.clipboardSnapshotMaxBytes + 1)] {
            let h = enabled()
            h.clipboard.replaceText(previous)
            h.clipboard.snapshotMode = .deferred
            h.deliver()
            h.clipboard.completeSnapshot(repeating: 2)
            XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
            h.settle()
            h.scheduler.advance(by: .seconds(2))
            XCTAssertEqual(h.recorder.events.filter { $0 == .write("test") }.count, 1)
            XCTAssertEqual(doneCount(h), 1)
            XCTAssertEqual(h.clipboard.restoreCalls, 0)
            XCTAssertEqual(h.clipboard.text, "test")
            XCTAssertNil(h.clipboard.lastSnapshot)
        }
    }

    func testExactByteCapUnicodeMultilineAndEmptyTextCanRestore() {
        let values = ["", "line one\n日本語 👩🏽‍💻\n",
                      String(repeating: "🧪", count: Limits.clipboardSnapshotMaxBytes / 4)]
        for value in values {
            let h = enabled()
            h.clipboard.replaceText(value)
            completePaste(h)
            h.scheduler.advance(by: Limits.clipboardRestoreDelay)
            XCTAssertTrue(h.clipboard.text == value)
            XCTAssertEqual(h.clipboard.restorationWrites, 1)
        }
    }

    func testRevisionChangeDuringCaptureSkipsRestoreEvenForIdenticalText() {
        for newer in ["user copy", "previous"] {
            let h = enabled()
            h.clipboard.snapshotMode = .deferred
            h.deliver()
            h.clipboard.replaceText(newer)
            h.clipboard.completeSnapshot()
            h.settle()
            h.scheduler.advance(by: .seconds(2))
            XCTAssertEqual(h.clipboard.ownershipWrites, 1)
            XCTAssertEqual(h.clipboard.restoreCalls, 0)
            XCTAssertEqual(h.clipboard.text, "test")
            XCTAssertNil(h.clipboard.lastSnapshot)
        }
    }

    func testUnknownWriteOwnershipLeavesResultForManualPaste() {
        let h = enabled()
        h.clipboard.canOwnWrite = false
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.ownershipWrites, 1)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertNil(h.clipboard.lastSnapshot)
    }

    func testNewerUserCopyIncludingIdenticalBytesIsNeverOverwritten() {
        for newer in ["user copy", "test"] {
            let h = enabled()
            completePaste(h)
            h.clipboard.replaceText(newer)
            h.scheduler.advance(by: Limits.clipboardRestoreDelay)
            XCTAssertEqual(h.clipboard.restorationWrites, 0)
            XCTAssertEqual(h.clipboard.text, newer)
            XCTAssertNil(h.clipboard.lastSnapshot)
        }
    }

    func testCopyHasZeroReadsAndNeverRestores() {
        let h = enabled()
        h.deliver(mode: .copyOnly)
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.readCount, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertEqual(h.service.lastDelivery?.outcome, .copiedOnly(.requested))
    }

    func testExhaustedLadderKeepsCopyFallbackAndReleasesPriorText() {
        let h = enabled()
        h.injectors[.cgEvent]?.result = .failed(.permissionDenied)
        h.injectors[.appleScript]?.result = .failed(.timeout)
        completePaste(h)
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "test")
        XCTAssertEqual(doneCount(h), 1)
        XCTAssertTrue(h.recorder.events.contains {
            if case .pressPaste = $0 { return true }; return false
        })
    }

    func testSuccessfulLaterBackendRestoresAfterEveryFailureReason() {
        let reasons: [PasteFailure] = [.permissionDenied, .toolMissing, .timeout, .portalDenied,
                                      .backendUnavailable, .notReceived, .unknown]
        for reason in reasons {
            let h = enabled()
            h.focus.confirmation = .unconfirmed
            h.injectors[.cgEvent]?.result = .failed(reason)
            completePaste(h)
            XCTAssertEqual(h.service.lastDelivery,
                DeliveryReceipt(outcome: .pasted(.appleScript), focus: .unconfirmed))
            XCTAssertEqual(h.cache.failure(for: .cgEvent), reason)
            XCTAssertNotNil(h.clipboard.lastSnapshot)
            XCTAssertEqual(h.clipboard.text, "test")
            h.scheduler.advance(by: Limits.clipboardRestoreDelay - .milliseconds(1))
            XCTAssertEqual(h.clipboard.restoreCalls, 0)
            h.scheduler.advance(by: .milliseconds(1))
            XCTAssertEqual(h.clipboard.restoreCalls, 1)
            XCTAssertEqual(h.clipboard.restorationWrites, 1)
            XCTAssertEqual(h.clipboard.text, "previous")
            XCTAssertNil(h.clipboard.lastSnapshot)
            XCTAssertEqual(doneCount(h), 1)
        }
    }

    func testCachedOrMissingBackendStillAllowsLaterSentToRestore() {
        for cached in [false, true] {
            let h = DeliveryHarness(available: cached ? PasteBackend.allCases : [.appleScript],
                                    clipboardRestore: .previousText)
            h.clipboard.replaceText("previous")
            if cached { h.cache.record(.permissionDenied, for: .cgEvent) }
            h.arm()
            completePaste(h)
            XCTAssertEqual(h.clipboard.text, "test")
            h.scheduler.advance(by: .seconds(2))
            XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.appleScript))
            XCTAssertEqual(h.clipboard.restoreCalls, 1)
            XCTAssertEqual(h.clipboard.restorationWrites, 1)
            XCTAssertEqual(h.clipboard.text, "previous")
            XCTAssertNil(h.clipboard.lastSnapshot)
            XCTAssertEqual(doneCount(h), 1)
        }
    }

    func testLaterBackendRestoreDelayStartsAtItsSentCallback() {
        let h = enabled()
        h.injectors[.cgEvent]?.mode = .deferred
        h.injectors[.appleScript]?.mode = .deferred
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))
        h.injectors[.cgEvent]?.complete(.failed(.timeout))
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 0)
        h.injectors[.appleScript]?.complete(.sent)
        XCTAssertEqual(doneCount(h), 1)
        h.scheduler.advance(by: Limits.clipboardRestoreDelay - .milliseconds(1))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        h.scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertEqual(h.clipboard.text, "previous")
    }

    func testNewerCopyDuringLadderRetryIsNeverOverwritten() {
        for newer in ["user copy", "test"] {
            let h = enabled()
            h.injectors[.cgEvent]?.onPaste = { h.clipboard.replaceText(newer) }
            h.injectors[.cgEvent]?.result = .failed(.timeout)
            completePaste(h)
            XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.appleScript))
            h.scheduler.advance(by: Limits.clipboardRestoreDelay)
            XCTAssertEqual(h.clipboard.restoreCalls, 1)
            XCTAssertEqual(h.clipboard.restorationWrites, 0)
            XCTAssertEqual(h.clipboard.text, newer)
            XCTAssertNil(h.clipboard.lastSnapshot)
            h.injectors[.cgEvent]?.onPaste = nil
        }
    }

    func testSelfTestHasZeroReadsAndInvalidatesEarlierRestoreBeforeReadback() {
        let h = enabled(session: .wlroots)
        completePaste(h)
        let reads = h.clipboard.readCount
        h.target.received = [DeliveryStrings.testPrompt]
        let test = SelfTest(target: h.target, delivery: h.service, session: h.session,
                            scheduler: h.scheduler, mainThread: h.main)
        var reports: [SelfTestReport] = []
        test.run { reports.append($0) }
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(h.clipboard.readCount, reads)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, DeliveryStrings.testPrompt)
    }

    func testLaterCopyStartsImmediatelyAndCancelsEarlierRestore() {
        let h = enabled()
        h.deliver("first")
        h.deliver("second", mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.clipboard.text, "second")
        XCTAssertEqual(doneCount(h), 1)
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(doneCount(h), 2)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "second")
    }

    func testLaterPasteOwnsItsRestoreWhileEarlierTimerCannotRestoreOverIt() {
        let h = enabled()
        h.injectors[.cgEvent]?.mode = .deferred
        completePaste(h)
        h.injectors[.cgEvent]?.complete(.sent)
        h.deliver("second")
        h.settle()
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        XCTAssertEqual(h.clipboard.text, "second")
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        h.injectors[.cgEvent]?.complete(.sent)
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertEqual(h.clipboard.text, "test")
    }

    func testNewerDeliveryCancelsPendingCaptureWithoutOverwritingDuringPaste() {
        let h = enabled()
        h.clipboard.snapshotMode = .deferred
        h.injectors[.cgEvent]?.mode = .deferred
        h.deliver("first")
        h.deliver("second", mode: .copyOnly)
        XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
        XCTAssertEqual(h.clipboard.text, "first")
        h.clipboard.completeSnapshot()
        h.settle()
        XCTAssertEqual(h.clipboard.text, "first")
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.clipboard.text, "second")
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 2)
    }

    func testDisablingAndReenablingDoesNotResurrectPendingRestore() {
        let h = enabled()
        completePaste(h)
        XCTAssertNotNil(h.clipboard.lastSnapshot)
        h.service.setClipboardRestore(.off)
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.service.setClipboardRestore(.previousText)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "test")
    }

    func testDisabledDuringInjectionCannotScheduleRestoreOnLateSent() {
        let h = enabled()
        h.injectors[.cgEvent]?.mode = .deferred
        completePaste(h)
        h.service.setClipboardRestore(.off)
        h.service.setClipboardRestore(.previousText)
        h.injectors[.cgEvent]?.complete(.sent)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertNil(h.clipboard.lastSnapshot)
        XCTAssertEqual(doneCount(h), 1)
    }

    func testSharedD3SettingsObserverCancelsPendingRestoreWithoutClipboardReads() throws {
        let files = MemoryFileStore()
        let settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        let h = DeliveryHarness()
        let observer = settings.addObserver { snapshot, _ in
            h.service.setClipboardRestore(snapshot.isReadOnly ? .off : snapshot.document.delivery.clipboardRestore)
        }
        defer { settings.removeObserver(observer) }
        settings.setClipboardRestore(.previousText)
        XCTAssertEqual(h.clipboard.readCount, 0)
        let previous = UUID().uuidString
        h.clipboard.replaceText(previous)
        h.arm()
        completePaste(h)
        settings.setClipboardRestore(.off)
        XCTAssertNil(h.clipboard.lastSnapshot)
        settings.setClipboardRestore(.previousText)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.readCount, 1)
        XCTAssertFalse(try files.text(at: "settings.json").contains(previous))
    }

    func testGraphInvalidationAndShutdownCancelCaptureInjectionAndDelayedRestore() {
        for shutdown in [false, true] {
            for stage in ["capture", "injection", "delay"] {
                let h = enabled()
                if stage == "capture" { h.clipboard.snapshotMode = .deferred }
                if stage == "injection" { h.injectors[.cgEvent]?.mode = .deferred }
                h.deliver()
                if stage != "capture" { h.settle() }
                if shutdown { h.service.shutdown() }
                else { h.service.invalidatePendingPresentation() }
                XCTAssertNil(h.clipboard.lastSnapshot)
                if stage == "capture" {
                    XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
                    h.clipboard.completeSnapshot(repeating: 2)
                    h.settle()
                }
                if stage == "injection" { h.injectors[.cgEvent]?.complete(.sent) }
                h.scheduler.advance(by: .seconds(2))
                XCTAssertEqual(h.clipboard.restoreCalls, 0)
                XCTAssertEqual(h.clipboard.text, "test")
                XCTAssertEqual(doneCount(h), 1)
            }
        }
    }

    func testShutdownPermanentlyDisablesRestoreForLaterDeliveries() {
        let h = enabled()
        h.service.shutdown()
        h.service.setClipboardRestore(.previousText)
        completePaste(h)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.readCount, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(h.clipboard.text, "test")
    }

    func testCancellationDuringSnapshotCallCancelsReturnedHandleAndWritesOnce() {
        let h = enabled()
        h.clipboard.snapshotMode = .deferred
        h.clipboard.onSnapshot = { h.service.setClipboardRestore(.off) }
        h.deliver()
        XCTAssertEqual(h.clipboard.snapshotCancellations, 1)
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.clipboard.completeSnapshot(repeating: 2)
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.recorder.events.filter { $0 == .write("test") }.count, 1)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 1)
        h.clipboard.onSnapshot = nil
    }

    func testDelayedTimerDoesNotRetainServiceOrPreviousTextAfterRelease() {
        let h = enabled()
        var service: DeliveryService? = DeliveryService(panel: FakePanel(h.recorder), focus: h.focus,
            clipboard: h.clipboard, injectors: Array(h.injectors.values), notifier: FakeNotifier(h.recorder),
            session: h.session, scheduler: h.scheduler, mainThread: h.main, failureCache: h.cache,
            clipboardRestore: .previousText)
        weak var released = service
        service?.deliver("test", mode: .paste(.standard)) { _ in }
        h.settle()
        // Retire the completed settle callback retained by the fake scheduler.
        h.scheduler.advance(by: Limits.clipboardSnapshotBudget - Limits.settleDelayMacOS)
        XCTAssertNotNil(h.clipboard.lastSnapshot)
        service = nil
        XCTAssertNil(released)
        XCTAssertNil(h.clipboard.lastSnapshot)
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
    }

    func testSnapshotInjectorAndRestoreTimerDuplicatesCannotCompleteOrRestoreTwice() {
        let h = enabled()
        h.clipboard.snapshotMode = .deferred
        h.injectors[.cgEvent]?.mode = .deferred
        h.deliver()
        h.clipboard.completeSnapshot(repeating: 2)
        h.settle()
        h.injectors[.cgEvent]?.complete([.sent, .sent])
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        h.scheduler.repeatLastCallback()
        XCTAssertEqual(h.recorder.events.filter { $0 == .write("test") }.count, 1)
        XCTAssertEqual(h.clipboard.ownershipWrites, 1)
        XCTAssertEqual(h.clipboard.restoreCalls, 1)
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertEqual(doneCount(h), 1)
    }

    func testAllRestoreStagesRunThroughInjectedMainThread() {
        let h = enabled()
        h.main.mode = .deferred
        h.clipboard.snapshotMode = .deferred
        h.clipboard.onSnapshot = { XCTAssertTrue(h.main.isRunning) }
        h.clipboard.onClipboardRestore = { XCTAssertTrue(h.main.isRunning) }
        h.deliver()
        XCTAssertEqual(h.clipboard.readCount, 0)
        h.main.drain()
        h.clipboard.completeSnapshot()
        XCTAssertEqual(h.clipboard.ownershipWrites, 0)
        h.main.drain()
        h.settle()
        h.main.drain()
        XCTAssertEqual(doneCount(h), 1)
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        h.main.drain()
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
    }

    func testMissingCapabilityUsesExistingDeliveryPathWithoutReads() {
        let h = enabled()
        let service = DeliveryService(panel: FakePanel(h.recorder), focus: h.focus,
            clipboard: BasicClipboard(h.clipboard), injectors: Array(h.injectors.values),
            notifier: FakeNotifier(h.recorder), session: h.session, scheduler: h.scheduler,
            mainThread: h.main, failureCache: h.cache, clipboardRestore: .previousText)
        service.deliver("test", mode: .paste(.standard)) { h.recorder.events.append(.done($0)) }
        h.settle()
        h.scheduler.advance(by: .seconds(2))
        XCTAssertEqual(h.clipboard.readCount, 0)
        XCTAssertEqual(h.clipboard.ownershipWrites, 0)
        XCTAssertEqual(h.clipboard.restoreCalls, 0)
        XCTAssertEqual(doneCount(h), 1)
    }

    func testPriorBytesAreRedactedAndNeverReachEventsStatusOrSettingsFiles() throws {
        let secret = UUID().uuidString
        let h = enabled()
        h.clipboard.replaceText(secret)
        h.deliver()
        let snapshot = try XCTUnwrap(h.clipboard.lastSnapshot)
        var reflection = ""
        dump(snapshot, to: &reflection)
        XCTAssertFalse(String(describing: snapshot).contains(secret))
        XCTAssertFalse(String(reflecting: snapshot).contains(secret))
        XCTAssertFalse(reflection.contains(secret))
        h.settle()
        h.scheduler.advance(by: Limits.clipboardRestoreDelay)
        XCTAssertEqual(h.clipboard.restorationWrites, 1)
        XCTAssertFalse(String(reflecting: h.recorder.events).contains(secret))
        h.service.readStatus { status in
            XCTAssertFalse(String(reflecting: status).contains(secret))
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(h.service.lastDelivery?.outcome), as: UTF8.self)
            .contains(secret))
    }
}

private struct BasicClipboard: Clipboard {
    let clipboard: FakeClipboard
    init(_ clipboard: FakeClipboard) { self.clipboard = clipboard }
    func writeText(_ text: String) { clipboard.writeText(text) }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { clipboard.readText(completion) }
}
