import ApplicationServices
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

    func testBlurDismissalKeepsOurSetupOrSelfTestFocused() {
        let scheduler = ManualScheduler()
        let tracker = makeTracker(
            frontmost: { .macOS(processID: self.ownPID, bundleID: "test.own") },
            scheduler: scheduler, activate: { _ in
                XCTFail("Blur must not take focus from an owned window")
                return true
            })
        var results: [FocusConfirmation] = []
        tracker.prepareForRestore(.blur)
        tracker.restore(target) { results.append($0) }
        XCTAssertEqual(results, [.unconfirmed])
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testFailedActivationRelinquishesUnusedFocusOnlyOnce() {
        let scheduler = ManualScheduler()
        var resignations = 0
        let tracker = WorkspaceFocusTracker(
            source: .init(frontmost: { .macOS(processID: self.ownPID, bundleID: "test.own") },
                          activate: { _ in false }), ownPID: ownPID,
            mainThread: DispatchMainThread(), scheduler: scheduler,
            isTrusted: { false }, deactivateIfUnused: { resignations += 1 })
        var results: [FocusConfirmation] = []
        tracker.restore(target) { results.append($0) }
        for _ in 0...Limits.activationRetryCount { scheduler.fire(Limits.activationRetryDelay) }
        scheduler.fire(Limits.accessibilityFocusWait)
        XCTAssertEqual(results, [.unconfirmed])
        XCTAssertEqual(resignations, 1)
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
        }, deactivateIfUnused: {})
        var results: [FocusConfirmation] = []
        tracker.prepareForRestore(.delivery)
        tracker.restore(target) { results.append($0) }
        wait(for: [queryStarted], timeout: 2)
        scheduler.fire(Limits.accessibilityFocusWait)
        releaseQuery.signal()
        wait(for: [queryReturned], timeout: 2)
        XCTAssertEqual(results, [.unconfirmed])
    }

    func testSecondRestoreConfirmsWhileSupersededWaitNeverFocuses() {
        let scheduler = ManualScheduler()
        let firstPaused = expectation(description: "First fake AX poll is sleeping")
        let secondCompleted = expectation(description: "Second restore confirms independently")
        secondCompleted.assertForOverFulfill = true
        let answersReturned = expectation(description: "Both workers return to main")
        answersReturned.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let second = DeliveryTarget.macOS(processID: 456, bundleID: "test.second")
        var frontmost: DeliveryTarget? = target
        let tracker = WorkspaceFocusTracker(
            source: .init(frontmost: { frontmost }, activate: { frontmost = $0; return true }),
            ownPID: ownPID,
            mainThread: ObservingMainThread(onBackgroundDelivery: { answersReturned.fulfill() }),
            scheduler: scheduler, isTrusted: { true }, waitForFocus: { pid, timeout in
                var time: TimeInterval = 0
                var didPause = false
                return AccessibilityFocusWait.wait(for: pid, timeout: timeout, now: { time }, pause: { delay in
                    if !didPause {
                        didPause = true
                        firstPaused.fulfill()
                        // Hold the obsolete poll until the second request completes.
                        // A serial focus queue cannot run the second query in time.
                        _ = releaseFirst.wait(timeout: .now() + 5)
                    }
                    time += delay
                }, focusedPID: { _ in pid == 456 ? 456 : nil })
            }, deactivateIfUnused: {})

        var firstResults: [FocusConfirmation] = []
        tracker.prepareForRestore(.delivery)
        tracker.restore(target) { firstResults.append($0) }
        wait(for: [firstPaused], timeout: 2)

        _ = tracker.captureTarget()
        tracker.prepareForRestore(.delivery)
        var secondResults: [FocusConfirmation] = []
        tracker.restore(second) { result in
            secondResults.append(result)
            secondCompleted.fulfill()
        }
        wait(for: [secondCompleted], timeout: 2)
        XCTAssertEqual(secondResults, [.confirmed])

        releaseFirst.signal()
        wait(for: [answersReturned], timeout: 2)
        scheduler.fire(Limits.accessibilityFocusWait)
        scheduler.fire(Limits.accessibilityFocusWait)
        XCTAssertEqual(firstResults, [.unconfirmed])
        XCTAssertEqual(secondResults, [.confirmed])
    }

    func testMissingAXElementFallsBackToFocusedApplicationWithoutSleeping() {
        var time: TimeInterval = 0
        var attributes: [String] = []
        let result = AccessibilityFocusWait.wait(
            for: 123, timeout: Limits.accessibilityFocusWait.timeInterval,
            now: { time }, pause: { time += $0 }, focusedPID: { remaining in
                AccessibilityFocusWait.readFocusedPID(timeout: remaining, now: { time }, query: { attribute, _ in
                    attributes.append(attribute as String)
                    return attribute as String == kAXFocusedApplicationAttribute as String ? 123 : nil
                })
            })

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(time, 0)
        XCTAssertEqual(attributes, [kAXFocusedUIElementAttribute as String, kAXFocusedApplicationAttribute as String])
    }

    func testAXElementTakesPrecedenceAndFallbackKeepsOriginalDeadline() {
        let timeout = Limits.accessibilityFocusWait.timeInterval
        let elementPID = AccessibilityFocusWait.readFocusedPID(timeout: timeout, query: { attribute, _ in
            XCTAssertEqual(attribute as String, kAXFocusedUIElementAttribute as String)
            return self.ownPID
        })
        XCTAssertEqual(elementPID, ownPID)

        var time: TimeInterval = 0
        var remainingBudgets: [TimeInterval] = []
        let applicationPID = AccessibilityFocusWait.readFocusedPID(timeout: timeout, now: { time }, query: { attribute, budget in
            remainingBudgets.append(budget)
            if attribute as String == kAXFocusedUIElementAttribute as String {
                time += timeout / 2
                return nil
            }
            return 123
        })
        XCTAssertEqual(applicationPID, 123)
        XCTAssertEqual(remainingBudgets, [timeout, timeout / 2])

        time = 0
        var queries = 0
        XCTAssertNil(AccessibilityFocusWait.readFocusedPID(timeout: timeout, now: { time }, query: { _, _ in
            queries += 1
            time = timeout
            return nil
        }))
        XCTAssertEqual(queries, 1)
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
                              mainThread: DispatchMainThread(), scheduler: scheduler,
                              isTrusted: { false }, deactivateIfUnused: {})
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
