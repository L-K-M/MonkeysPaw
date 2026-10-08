#if os(Linux)
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxFocusTrackerTests: XCTestCase {
    func testX11CapturesClassAndSkipsOurOwnClass() throws {
        let tools = try FakeLinuxTools()
        let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
        let tracker = LinuxFocusTracker(session: session, runner: tools.runner)
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments + "\nprintf '%s\\n' XTerm")
        XCTAssertEqual(tracker.captureTarget(), .linux(session: .otherX11, x11WindowClass: "XTerm"))
        XCTAssertEqual(tools.arguments, [["getactivewindow", "getwindowclassname"]])
        try tools.install("xdotool", script: "printf '%s\\n' '\(AppIdentity.linuxAppID.uppercased())'")
        XCTAssertNil(tracker.captureTarget())
    }

    func testWaylandNeverQueriesXWayland() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments + "\nprintf XTerm")
        let session = LinuxSessionProbe(environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"], flatpakInfoExists: false)
        XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
        XCTAssertTrue(tools.log.isEmpty)
    }

    func testHungCaptureIsBoundedAndRestoreReportsOnce() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: "exec /bin/sleep 10")
        let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
        let tracker = LinuxFocusTracker(session: session, runner: tools.runner)
        let start = ContinuousClock().now
        XCTAssertNil(tracker.captureTarget())
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(1))
        var callbacks = 0
        tracker.restore(.linux(session: .otherX11, x11WindowClass: "XTerm")) {
            XCTAssertEqual($0, .unconfirmed)
            callbacks += 1
        }
        XCTAssertEqual(callbacks, 1)
    }
}
#endif
