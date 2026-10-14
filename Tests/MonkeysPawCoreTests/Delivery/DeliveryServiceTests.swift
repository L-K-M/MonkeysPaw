@testable import MonkeysPawCore
import XCTest

final class DeliveryServiceTests: XCTestCase {
    func testCaptureInvocationCompletesOnInjectedMainThread() throws {
        for source: DeliveryInvocationSource in [.picker, .currentTarget] {
            let h = DeliveryHarness()
            h.arm()
            h.main.mode = .deferred
            var completions = 0
            h.service.captureInvocation(source: source) { invocation in
                XCTAssertTrue(h.main.isRunning)
                XCTAssertEqual(invocation.target, h.focus.target)
                XCTAssertEqual(invocation.session, .macOS)
                completions += 1
            }
            XCTAssertEqual(completions, 0)
            h.main.drain()
            XCTAssertEqual(completions, 1)
        }
    }

    func testSentBackendAfterPresentationInvalidationReportsActualOutcomeOnce() throws {
        let h = DeliveryHarness()
        h.arm()
        var captured: DeliveryInvocation?
        h.service.captureInvocation(source: .picker) { captured = $0 }
        let invocation = try XCTUnwrap(captured)
        h.injectors[.cgEvent]?.mode = .deferred
        var outcomes: [DeliveryOutcome?] = []
        h.service.deliver("test", mode: .paste(.standard), invocation: invocation) { outcomes.append($0) }
        h.settle()
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [.standard])

        h.service.invalidatePendingPresentation()
        h.injectors[.cgEvent]?.complete([.sent, .sent])

        XCTAssertEqual(outcomes, [.pasted(.cgEvent)])
        XCTAssertEqual(h.service.lastDelivery, DeliveryReceipt(outcome: .pasted(.cgEvent), focus: .confirmed))
        h.service.deliver("next", mode: .copyOnly) { _ in }
        XCTAssertEqual(h.clipboard.text, "next", "Completion must release the delivery queue.")
        h.settle()
    }

    func testSentBackendAfterRevocationKeepsClipboardRestore() throws {
        for cancelInvocation in [true, false] {
            let h = DeliveryHarness(clipboardRestore: .previousText)
            h.clipboard.replaceText("previous")
            h.arm()
            var captured: DeliveryInvocation?
            h.service.captureInvocation(source: .picker) { captured = $0 }
            let invocation = try XCTUnwrap(captured)
            h.injectors[.cgEvent]?.mode = .deferred
            var valid = true
            var outcomes: [DeliveryOutcome?] = []
            h.service.deliver("test", mode: .paste(.standard), invocation: invocation,
                              isValid: { valid }) { outcomes.append($0) }
            h.settle()
            XCTAssertEqual(h.injectors[.cgEvent]?.chords, [.standard])
            if cancelInvocation { invocation.cancel() }
            else { valid = false }
            h.injectors[.cgEvent]?.complete([.sent, .sent])

            XCTAssertEqual(outcomes, [.pasted(.cgEvent)])
            XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.cgEvent))
            h.scheduler.advance(by: Limits.clipboardRestoreDelay - .milliseconds(1))
            XCTAssertEqual(h.clipboard.text, "test")
            h.scheduler.advance(by: .milliseconds(1))
            h.scheduler.repeatLastCallback()
            XCTAssertEqual(h.clipboard.text, "previous")
            XCTAssertEqual(h.clipboard.restorationWrites, 1)
            XCTAssertNil(h.clipboard.lastSnapshot)
        }
    }

    func testRevokedInvocationBeforePasteStillCancelsWithoutReceipt() throws {
        let h = DeliveryHarness()
        h.arm()
        var captured: DeliveryInvocation?
        h.service.captureInvocation(source: .picker) { captured = $0 }
        let invocation = try XCTUnwrap(captured)
        var outcomes: [DeliveryOutcome?] = []
        h.service.deliver("test", mode: .paste(.standard), invocation: invocation) { outcomes.append($0) }
        invocation.cancel()
        h.settle()
        h.scheduler.repeatLastCallback()

        XCTAssertEqual(outcomes, [nil])
        XCTAssertNil(h.service.lastDelivery)
        XCTAssertTrue(h.injectors.values.allSatisfy { $0.chords.isEmpty })

    func testTerminalPreferredChordUsesArmedTargetAndPreservesDeliveryOrder() throws {
        let h = DeliveryHarness(session: .otherX11)
        let target = DeliveryTarget.linux(session: .otherX11, x11WindowClass: "kitty")
        h.focus.target = target
        h.arm()
        h.focus.target = .linux(session: .otherX11, x11WindowClass: "Firefox")
        XCTAssertEqual(h.service.preferredChord, .terminal)
        h.deliver(mode: .paste(h.service.preferredChord))
        XCTAssertEqual(h.recorder.events, [.write("test"), .hideForDelivery, .wait(Limits.settleDelayLinux)])
        h.settle()
        XCTAssertEqual(h.recorder.events, [
            .write("test"), .hideForDelivery, .wait(Limits.settleDelayLinux), .restore(target),
            .paste(.xdotool, .terminal), .done(.pasted(.xdotool)),
        ])
    }

    func testPreferredCurrentInvocationDoesNotReuseOrChangeArmedPickerTarget() throws {
        let h = DeliveryHarness(session: .otherX11)
        h.focus.target = .linux(session: .otherX11, x11WindowClass: "kitty")
        h.arm()
        h.focus.target = .linux(session: .otherX11, x11WindowClass: "Firefox")
        var captured: DeliveryInvocation?
        h.service.captureInvocation(source: .currentTarget) { captured = $0 }
        let invocation = try XCTUnwrap(captured)
        h.focus.target = .linux(session: .otherX11, x11WindowClass: "konsole")
        XCTAssertEqual(h.service.preferredChord(for: invocation), .standard)
        XCTAssertEqual(h.service.preferredChord, .terminal)
    }

    func testPreferredFallbackRetainsTerminalChordAcrossLadderAndCache() {
        let h = DeliveryHarness(session: .otherX11)
        h.focus.target = .linux(session: .otherX11, x11WindowClass: "Tilix")
        h.injectors[.xdotool]?.result = .failed(.toolMissing)
        h.injectors[.ydotool]?.result = .failed(.timeout)
        h.arm()
        for _ in 0..<2 {
            h.deliver(mode: .paste(h.service.preferredChord))
            h.settle()
        }
        let reason = CopyReason.backendsFailed([
            BackendFailure(backend: .xdotool, reason: .toolMissing),
            BackendFailure(backend: .ydotool, reason: .timeout),
        ])
        XCTAssertEqual(h.injectors[.xdotool]?.chords, [.terminal])
        XCTAssertEqual(h.injectors[.ydotool]?.chords, [.terminal])
        XCTAssertEqual(h.recorder.events.filter { $0 == .pressPaste(.terminal, reason) }.count, 2)
    }

    func testClipboardHideSettleRestoreInjectOrder() throws {
        let h = DeliveryHarness()
        h.arm()
        let target = try XCTUnwrap(h.focus.target)
        h.deliver()

        XCTAssertEqual(h.recorder.events, [.write("test"), .hideForDelivery, .wait(.milliseconds(100))])
        XCTAssertNil(h.service.lastDelivery)
        h.scheduler.advance(by: .milliseconds(99))
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [])
        h.scheduler.advance(by: .milliseconds(1))

        XCTAssertEqual(h.recorder.events, [
            .write("test"), .hideForDelivery, .wait(.milliseconds(100)), .restore(target),
            .paste(.cgEvent, .standard), .done(.pasted(.cgEvent)),
        ])
        XCTAssertEqual(h.clipboard.readText(), "test")
    }

    func testSettleDurationsForAllSessions() {
        let table: [(DesktopSession, Duration)] = [
            (.macOS, .milliseconds(100)), (.gnomeWayland, .milliseconds(140)),
            (.gnomeX11, .milliseconds(140)), (.kdeWayland, .milliseconds(140)),
            (.kdeX11, .milliseconds(140)), (.otherX11, .milliseconds(140)),
            (.wlroots, .milliseconds(140)), (.flatpak(host: .kdeWayland), .milliseconds(140)),
        ]
        for (session, delay) in table {
            let h = DeliveryHarness(session: session)
            h.arm()
            h.deliver()
            XCTAssertEqual(h.scheduler.delays, [delay])
            h.scheduler.advance(by: delay - .nanoseconds(1))
            XCTAssertNil(h.service.lastDelivery)
            h.scheduler.advance(by: .nanoseconds(1))
            XCTAssertNotNil(h.service.lastDelivery)
        }
    }

    func testCopyOnlyRestoresFocusBeforeNotificationWithoutInjecting() throws {
        let h = DeliveryHarness()
        h.arm()
        h.deliver(mode: .copyOnly)
        h.settle()

        XCTAssertEqual(h.recorder.events, [
            .write("test"), .hideForDelivery, .wait(Limits.settleDelayMacOS),
            .restore(try XCTUnwrap(h.focus.target)), .copied, .done(.copiedOnly(.requested)),
        ])
        XCTAssertTrue(h.injectors.values.allSatisfy { $0.chords.isEmpty })
    }

    func testFailureFallsThroughAndIsSkippedUntilReset() {
        let h = DeliveryHarness(session: .gnomeWayland)
        h.injectors[.remoteDesktopPortal]?.result = .failed(.portalDenied)
        h.arm()
        h.deliver()
        h.settle()
        XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.ydotool))
        XCTAssertEqual(h.cache.failure(for: .remoteDesktopPortal), .portalDenied)

        h.deliver()
        h.settle()
        XCTAssertEqual(h.injectors[.remoteDesktopPortal]?.chords.count, 1)
        XCTAssertEqual(h.injectors[.ydotool]?.chords.count, 2)

        h.service.resetFailures()
        h.injectors[.remoteDesktopPortal]?.result = .sent
        h.deliver()
        h.settle()
        XCTAssertEqual(h.cache.resets, 1)
        XCTAssertEqual(h.injectors[.remoteDesktopPortal]?.chords.count, 2)
        XCTAssertEqual(h.injectors[.ydotool]?.chords.count, 2)
        XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.remoteDesktopPortal))
    }

    func testUnreceivedFailureIsCachedOnlyAfterMainThreadRuns() {
        let h = DeliveryHarness()
        h.main.mode = .deferred

        h.service.recordUnreceived(.cgEvent)

        XCTAssertNil(h.cache.failure(for: .cgEvent))
        h.main.drain()
        XCTAssertEqual(h.cache.failure(for: .cgEvent), .notReceived)
    }

    func testExhaustedLadderNotifiesBeforeCompletingAndKeepsTypedReasons() {
        let h = DeliveryHarness(session: .kdeWayland)
        h.injectors[.ydotool]?.result = .failed(.toolMissing)
        h.injectors[.remoteDesktopPortal]?.result = .failed(.timeout)
        let reason = CopyReason.backendsFailed([
            BackendFailure(backend: .ydotool, reason: .toolMissing),
            BackendFailure(backend: .remoteDesktopPortal, reason: .timeout),
        ])
        h.arm()
        h.deliver(mode: .paste(.terminal))
        h.settle()
        XCTAssertEqual(Array(h.recorder.events.suffix(2)), [
            .pressPaste(.terminal, reason), .done(.copiedOnly(reason)),
        ])

        h.deliver(mode: .paste(.terminal))
        h.settle()
        XCTAssertEqual(h.injectors[.ydotool]?.chords, [.terminal])
        XCTAssertEqual(h.injectors[.remoteDesktopPortal]?.chords, [.terminal])
        XCTAssertEqual(h.service.lastDelivery?.outcome, .copiedOnly(reason))
    }

    func testUnconfirmedFocusStillInjectsAndIsRecordedInReceipt() {
        let h = DeliveryHarness()
        h.focus.confirmation = .unconfirmed
        h.arm()
        h.deliver()
        h.settle()
        XCTAssertEqual(h.service.lastDelivery, DeliveryReceipt(outcome: .pasted(.cgEvent), focus: .unconfirmed))
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [.standard])
    }

    func testNoCapturedTargetStillAttemptsBestEffortPaste() {
        let h = DeliveryHarness(session: .wlroots)
        h.focus.target = nil
        h.arm()
        h.deliver()
        h.settle()
        XCTAssertEqual(h.service.lastDelivery, DeliveryReceipt(outcome: .pasted(.ydotool), focus: .notCaptured))
        XCTAssertFalse(h.recorder.events.contains { if case .restore = $0 { return true }; return false })
    }

    func testDoneAndWorkerContinuationsEnterMainThread() throws {
        let h = DeliveryHarness()
        h.main.mode = .deferred
        h.focus.mode = .deferred
        h.injectors[.cgEvent]?.mode = .deferred
        h.arm()
        var done = false
        h.service.deliver("test", mode: .paste(.standard)) { _ in
            XCTAssertTrue(h.main.isRunning)
            done = true
        }
        XCTAssertTrue(h.recorder.events.isEmpty)
        h.main.drain()
        h.settle()
        XCTAssertFalse(h.recorder.events.contains(.restore(try XCTUnwrap(h.focus.target))))
        h.main.drain()
        h.focus.complete(.confirmed)
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [])
        h.main.drain()
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertFalse(done)
        h.main.drain()
        XCTAssertTrue(done)
        XCTAssertGreaterThanOrEqual(h.main.hops, 5)
    }

    func testDeliveryUsesTargetCapturedAtArm() throws {
        let h = DeliveryHarness()
        let original = try XCTUnwrap(h.focus.target)
        h.arm()
        h.focus.target = .macOS(processID: 99, bundleID: "test.other")
        h.deliver()
        h.settle()
        XCTAssertTrue(h.recorder.events.contains(.restore(original)))
        XCTAssertFalse(h.recorder.events.contains(.restore(try XCTUnwrap(h.focus.target))))
    }

    func testSingleBackendDoesNotFallThroughOrRespectCachedFailure() {
        let h = DeliveryHarness()
        h.cache.record(.permissionDenied, for: .cgEvent)
        h.injectors[.cgEvent]?.result = .failed(.permissionDenied)
        var outcome: DeliveryOutcome?
        h.service.performSelfTest { finished in
            h.service.deliverForSelfTest("test", through: .cgEvent) {
                outcome = $0
                finished()
            }
        }
        h.settle()
        XCTAssertEqual(outcome, .copiedOnly(.backendsFailed([
            BackendFailure(backend: .cgEvent, reason: .permissionDenied),
        ])))
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [.standard])
        XCTAssertEqual(h.injectors[.appleScript]?.chords, [])
    }

    func testMissingDriverIsAnExplicitFailureThenFallsThrough() {
        let h = DeliveryHarness(session: .otherX11, available: [.ydotool])
        h.arm()
        h.deliver()
        h.settle()
        XCTAssertEqual(h.cache.failure(for: .xdotool), .backendUnavailable)
        XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.ydotool))
    }

    func testOverlappingDeliveriesDoNotOverwriteClipboardDuringInjection() {
        let h = DeliveryHarness()
        h.injectors[.cgEvent]?.mode = .deferred
        h.arm()
        h.deliver("first")
        h.deliver("second")
        h.settle()
        XCTAssertEqual(h.clipboard.readText(), "first")
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 1)
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.clipboard.readText(), "second")
        h.settle()
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.recorder.events.filter { if case .done = $0 { return true }; return false }.count, 2)
    }

    func testDuplicateInjectorCompletionDoesNotInterleaveQueuedDeliveries() {
        let h = DeliveryHarness()
        h.injectors[.cgEvent]?.mode = .deferred
        h.arm()
        h.deliver("first")
        h.deliver("second")
        h.deliver("third")
        h.settle()
        h.injectors[.cgEvent]?.complete([.sent, .sent])

        XCTAssertEqual(h.clipboard.readText(), "second")
        XCTAssertFalse(h.recorder.events.contains(.write("third")))
        XCTAssertEqual(h.recorder.events.filter { if case .done = $0 { return true }; return false }.count, 1)
        h.settle()
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 2)
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.clipboard.readText(), "third")
        h.settle()
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.recorder.events.filter { if case .done = $0 { return true }; return false }.count, 3)
    }

    func testLateInjectorFailureDoesNotStartFallbackAfterCompletion() {
        let h = DeliveryHarness()
        h.injectors[.cgEvent]?.mode = .deferred
        h.arm()
        h.deliver()
        h.settle()
        h.injectors[.cgEvent]?.complete([.sent, .failed(.timeout)])

        XCTAssertNil(h.cache.failure(for: .cgEvent))
        XCTAssertEqual(h.injectors[.appleScript]?.chords, [])
        XCTAssertEqual(h.service.lastDelivery?.outcome, .pasted(.cgEvent))
        XCTAssertEqual(h.recorder.events.filter { if case .done = $0 { return true }; return false }.count, 1)
    }

    func testQueuedOperationsWaitUntilFocusRestoreCompletes() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.arm()
        h.deliver("first")
        h.deliver("second")
        h.service.show()
        h.settle()
        h.scheduler.advance(by: .seconds(1))

        XCTAssertEqual(h.clipboard.readText(), "first")
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [])
        XCTAssertFalse(h.recorder.events.contains(.show))
        XCTAssertFalse(h.recorder.events.contains(.write("second")))
        h.focus.complete(.unconfirmed)
        XCTAssertEqual(h.clipboard.readText(), "second")
        h.settle()
        h.focus.complete(.confirmed)
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 2)
        XCTAssertTrue(h.recorder.events.contains(.show))
    }

    func testDuplicateFocusCompletionDoesNotInjectTwice() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.injectors[.cgEvent]?.mode = .deferred
        h.arm()
        h.deliver("first")
        h.deliver("second")
        h.settle()
        h.focus.complete([.confirmed, .unconfirmed])

        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 1)
        XCTAssertEqual(h.clipboard.readText(), "first")
        h.injectors[.cgEvent]?.complete(.sent)
        XCTAssertEqual(h.clipboard.readText(), "second")
    }

    func testDuplicateSettleCallbackDoesNotRestoreTwice() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.arm()
        h.deliver()
        h.settle()
        h.scheduler.repeatLastCallback()

        XCTAssertEqual(h.recorder.events.filter { if case .restore = $0 { return true }; return false }.count, 1)
        h.focus.complete(.confirmed)
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 1)
    }

    func testDuplicateDismissCompletionDoesNotReleaseTheNextOperation() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.arm()
        h.service.dismiss()
        h.deliver("first")
        h.deliver("second")
        h.focus.complete([.unconfirmed, .confirmed])

        XCTAssertEqual(h.clipboard.readText(), "first")
        XCTAssertFalse(h.recorder.events.contains(.write("second")))
        h.settle()
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 1)
    }

    func testDuplicateSelfTestCompletionDoesNotReleaseTheNextOperation() throws {
        let h = DeliveryHarness()
        var finished: (() -> Void)?
        h.service.performSelfTest { finished = $0 }
        h.deliver("first")
        h.deliver("second")
        let finish = try XCTUnwrap(finished)
        finish()
        finish()

        XCTAssertEqual(h.clipboard.readText(), "first")
        XCTAssertFalse(h.recorder.events.contains(.write("second")))
        h.settle()
        XCTAssertEqual(h.injectors[.cgEvent]?.chords.count, 1)
    }

    func testShowCapturesBeforePresentingAndDismissRestoresWithoutDeliveryHide() throws {
        let h = DeliveryHarness()
        h.service.show()
        h.service.dismiss()
        XCTAssertEqual(h.recorder.events, [
            .capture, .show, .hide, .restore(try XCTUnwrap(h.focus.target)),
        ])
    }

    func testGraphReplacementInvalidatesShowQueuedBehindAnEarlierRestore() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.arm()
        h.service.dismiss() // Hide now, but hold the queue during restoration.
        h.service.show() // A picker request from the graph about to be replaced.
        h.service.dismiss() // Library replacement dismisses that picker first.
        h.service.invalidatePendingPresentation()
        h.focus.complete(.unconfirmed)

        XCTAssertFalse(h.recorder.events.contains(.show), "A retired picker must never present the replacement view")
        h.focus.target = nil
        h.service.show()
        XCTAssertEqual(h.recorder.events.filter { $0 == .show }.count, 1, "Discarding stale work must release the queue")
    }

    func testGraphReplacementInvalidatesOlderDismissalBeforeNewShow() {
        let h = DeliveryHarness()
        h.focus.mode = .deferred
        h.arm()
        h.service.dismiss()
        h.service.show()
        h.service.dismiss()
        h.service.invalidatePendingPresentation()
        h.service.show() // The replacement picker is now the user's choice.
        h.focus.complete(.unconfirmed)

        XCTAssertEqual(h.recorder.events.filter { $0 == .hide }.count, 1)
        XCTAssertEqual(h.recorder.events.filter { $0 == .show }.count, 1)
        XCTAssertEqual(h.recorder.events.last, .show)
    }

    func testProcessCacheCanBeSharedAndReset() {
        let cache = SessionPasteFailureCache()
        cache.record(.timeout, for: .remoteDesktopPortal)
        cache.record(.toolMissing, for: .ydotool)
        XCTAssertEqual(cache.failure(for: .remoteDesktopPortal), .timeout)
        cache.reset()
        XCTAssertNil(cache.failure(for: .remoteDesktopPortal))
        XCTAssertNil(cache.failure(for: .ydotool))
    }
}
