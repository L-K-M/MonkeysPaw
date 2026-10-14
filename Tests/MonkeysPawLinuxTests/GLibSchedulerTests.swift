#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GLibSchedulerTests: XCTestCase {
    private final class Lifetime {}

    func testTimersRunOnceOnGLibThreadAndReleaseCapturedWork() {
        let scheduler = GLibScheduler()
        defer { scheduler.shutdown() }
        weak var lifetime: Lifetime?
        var calls = 0
        do {
            let value = Lifetime()
            lifetime = value
            scheduler.after(.zero) {
                XCTAssertTrue(Thread.isMainThread)
                withExtendedLifetime(value) { calls += 1 }
            }
        }
        XCTAssertTrue(GTKTestSupport.spin { calls == 1 })
        XCTAssertNil(lifetime)
        _ = g_main_context_iteration(nil, 0)
        XCTAssertEqual(calls, 1)
    }

    func testDisableRemovesNativeTimerAndShutdownRejectsQueuedRegistration() {
        let scheduler = GLibScheduler()
        weak var lifetime: Lifetime?
        var registered = false
        do {
            let value = Lifetime()
            lifetime = value
            scheduler.after(.seconds(86_400)) {
                withExtendedLifetime(value) { XCTFail("A disabled timer ran") }
            }
        }
        GTK.onMainLoop { registered = true }
        XCTAssertTrue(GTKTestSupport.spin { registered })
        XCTAssertNotNil(lifetime)
        scheduler.suspend()
        XCTAssertNil(lifetime)
        scheduler.resume()
        var calls = 0
        scheduler.after(.zero) { calls += 1 }
        scheduler.shutdown()
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
        XCTAssertEqual(calls, 0)
        scheduler.shutdown() // Idempotent, with fatal GLib warnings enabled.
    }

    func testWorkerRegistrationAfterShutdownCannotReviveTimer() {
        let scheduler = GLibScheduler()
        scheduler.shutdown()
        var calls = 0
        let completed = NSLock()
        var queued = false
        DispatchQueue.global().async {
            scheduler.after(.zero) { calls += 1 }
            completed.withLock { queued = true }
        }
        XCTAssertTrue(GTKTestSupport.spin { completed.withLock { queued } })
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
        XCTAssertEqual(calls, 0)
    }
}
#endif
