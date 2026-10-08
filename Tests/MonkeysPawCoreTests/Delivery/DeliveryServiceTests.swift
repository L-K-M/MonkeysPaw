@testable import MonkeysPawCore
import XCTest

final class DeliveryServiceTests: XCTestCase {
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
