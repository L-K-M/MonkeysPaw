import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class WorkspaceFocusTrackerTests: XCTestCase {
    private let ownPID: Int32 = 42
    private let target = DeliveryTarget.macOS(processID: 123, bundleID: "test.external")

    func testCaptureSkipsOwnProcessAndKeepsExternalIdentity() {
        var frontmost: DeliveryTarget? = .macOS(processID: ownPID, bundleID: "test.own")
        let tracker = makeTracker(frontmost: { frontmost })
        XCTAssertNil(tracker.captureTarget())

        frontmost = target
        XCTAssertEqual(tracker.captureTarget(), target)
        frontmost = nil
        XCTAssertNil(tracker.captureTarget())
    }

    func testDismissalDoesNotActivateAfterUserSwitchesApps() {
        let scheduler = ManualScheduler()
        var activations = 0
        let tracker = makeTracker(frontmost: { self.target }, scheduler: scheduler,
                                  activate: { _ in activations += 1; return true })
        var results: [FocusConfirmation] = []
        tracker.restore(target) { results.append($0) }
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(results, [.unconfirmed])
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testRestoreAlsoRefusesOurOwnProcess() {
        let tracker = makeTracker(frontmost: { self.target }, activate: { _ in
            XCTFail("Our own app is never a restore target")
            return true
        })
        var results: [FocusConfirmation] = []
        tracker.prepareForRestore(.delivery)
        tracker.restore(.macOS(processID: ownPID, bundleID: "test.own")) { results.append($0) }
        XCTAssertEqual(results, [.unconfirmed])
    }

    func testDeliveryActivatesEvenWithoutAccessibilityAndCompletesOnce() {
        let scheduler = ManualScheduler()
        var frontmost: DeliveryTarget? = .macOS(processID: 999, bundleID: "test.third")
        var activations = 0
        let tracker = makeTracker(frontmost: { frontmost }, scheduler: scheduler, activate: { target in
            activations += 1
            frontmost = target
            return true
        })
        var results: [FocusConfirmation] = []
        tracker.prepareForRestore(.delivery)
        tracker.restore(target) { results.append($0) }
        XCTAssertEqual(activations, 1)
        scheduler.fire(Limits.activationRetryDelay)
        scheduler.fire(Limits.accessibilityFocusWait)
        XCTAssertEqual(results, [.unconfirmed])

        // The explicit delivery mode is consumed. A later dismissal is guarded.
        frontmost = .macOS(processID: 999, bundleID: "test.third")
        tracker.restore(target) { results.append($0) }
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(results, [.unconfirmed, .unconfirmed])
    }

    func testActivationRetriesAreBoundedAndDoNotOverrideThirdApp() {
        let scheduler = ManualScheduler()
        var frontmost: DeliveryTarget? = .macOS(processID: ownPID, bundleID: "test.own")
        var activations = 0
        let tracker = makeTracker(frontmost: { frontmost }, scheduler: scheduler,
                                  activate: { _ in activations += 1; return true })
        var results: [FocusConfirmation] = []
        tracker.restore(target) { results.append($0) }
        for _ in 0...Limits.activationRetryCount { scheduler.fire(Limits.activationRetryDelay) }
        scheduler.fire(Limits.accessibilityFocusWait)
        XCTAssertEqual(activations, 1 + Limits.activationRetryCount)
        XCTAssertEqual(results, [.unconfirmed])

        tracker.restore(target) { results.append($0) }
        frontmost = .macOS(processID: 999, bundleID: "test.third")
        scheduler.fire(Limits.activationRetryDelay)
        scheduler.fire(Limits.accessibilityFocusWait)
        XCTAssertEqual(activations, 2 + Limits.activationRetryCount)
        XCTAssertEqual(results, [.unconfirmed, .unconfirmed])
    }

    func testLateAXConfirmationCannotCompleteAfterDeadline() {
        let scheduler = ManualScheduler()
        let queryStarted = expectation(description: "Fake AX query started")
        let queryReturned = expectation(description: "Late AX result delivered to main thread")
        let releaseQuery = DispatchSemaphore(value: 0)
        let mainThread = ObservingMainThread(onBackgroundDelivery: { queryReturned.fulfill() })
        let source = WorkspaceFocusTracker.Source(frontmost: { self.target }, activate: { _ in true })
        let tracker = WorkspaceFocusTracker(source: source, ownPID: ownPID,
                                            mainThread: mainThread, scheduler: scheduler,
                                            isTrusted: { true }, waitForFocus: { _, _ in
            queryStarted.fulfill()
            _ = releaseQuery.wait(timeout: .now() + 2)
            return .confirmed
        })
        var results: [FocusConfirmation] = []
        tracker.prepareForRestore(.delivery)
        tracker.restore(target) { results.append($0) }
        wait(for: [queryStarted], timeout: 2)
        scheduler.fire(Limits.accessibilityFocusWait)
        releaseQuery.signal()
        wait(for: [queryReturned], timeout: 2)
        XCTAssertEqual(results, [.unconfirmed])
    }

    func testAXWaitWithFakeClockConfirmsMatchingFocusedElement() {
        var time: TimeInterval = 0
        var queries = 0
        let result = AccessibilityFocusWait.wait(for: 123, timeout: Limits.accessibilityFocusWait.timeInterval,
                                                now: { time }, pause: { time += $0 }, focusedPID: { _ in
            queries += 1
            return queries == 3 ? 123 : self.ownPID
        })
        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(queries, 3)
        XCTAssertLessThan(time, Limits.accessibilityFocusWait.timeInterval)
    }

    func testAXWaitWithFakeClockStopsAtDeadlineAndRejectsLateAnswer() {
        let timeout = Limits.accessibilityFocusWait.timeInterval
        var time: TimeInterval = 0
        let result = AccessibilityFocusWait.wait(for: 123, timeout: timeout,
                                                now: { time }, pause: { time += $0 }, focusedPID: { remaining in
            XCTAssertGreaterThan(remaining, 0)
            XCTAssertLessThanOrEqual(remaining, timeout)
            return nil
        })
        XCTAssertEqual(result, .unconfirmed)
        XCTAssertEqual(time, timeout, accuracy: 0.000001)

        time = 0
        let late = AccessibilityFocusWait.wait(for: 123, timeout: timeout,
                                              now: { time }, pause: { time += $0 }, focusedPID: { _ in
            time = timeout
            return 123
        })
        XCTAssertEqual(late, .unconfirmed)
    }

    private func makeTracker(frontmost: @escaping () -> DeliveryTarget?,
                             scheduler: ManualScheduler = ManualScheduler(),
                             activate: @escaping (DeliveryTarget) -> Bool = { _ in true }) -> WorkspaceFocusTracker {
        WorkspaceFocusTracker(source: .init(frontmost: frontmost, activate: activate), ownPID: ownPID,
                              mainThread: DispatchMainThread(), scheduler: scheduler, isTrusted: { false })
    }
}

private final class ManualScheduler: Scheduler {
    var pending: [(Duration, () -> Void)] = []

    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append((delay, work)) }

    func fire(_ delay: Duration) {
        guard let index = pending.firstIndex(where: { $0.0 == delay }) else {
            XCTFail("No scheduled callback for \(delay)")
            return
        }
        pending.remove(at: index).1()
    }
}

private struct ObservingMainThread: MainThread {
    let onBackgroundDelivery: () -> Void

    func run(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work(); return }
        DispatchQueue.main.async {
            work()
            onBackgroundDelivery()
        }
    }
}
