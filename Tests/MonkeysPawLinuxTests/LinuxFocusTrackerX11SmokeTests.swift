#if os(Linux)
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

/// The smoke script owns the window manager and activates each real target.
final class LinuxFocusTrackerX11SmokeTests: XCTestCase {
    func testCapturesXtermClass() throws {
        let tracker = try smokeTracker()
        let target = tracker.captureTarget()
        // Keep the observed property out of failure diagnostics too.
        XCTAssertTrue(target == .linux(session: .otherX11, x11WindowClass: "XTerm"),
                      "Capture should return the active xterm's class.")
        // The smoke customizes XTerm's binding. It proves explicit delivery,
        // never stock XTerm support or automatic terminal classification.
        XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: .otherX11), .standard)
        XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: .otherX11,
                                                      defaultChord: .terminal), .terminal)
    }

    func testSkipsOurOwnWindow() throws {
        let tracker = try smokeTracker()
        XCTAssertTrue(tracker.captureTarget() == nil, "Capture should exclude the active picker.")
    }

    private func smokeTracker() throws -> LinuxFocusTracker {
        guard ProcessInfo.processInfo.environment["MONKEYSPAW_X11_SMOKE"] == "1" else {
            throw XCTSkip("Run through scripts/linux-delivery-smoke.sh with its active X11 targets.")
        }
        return LinuxFocusTracker(session: LinuxSessionProbe(), runner: LinuxToolRunner())
    }
}
#endif
