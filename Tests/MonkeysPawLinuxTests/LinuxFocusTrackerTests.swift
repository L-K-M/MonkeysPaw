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
        try tools.install("xdotool", script: Self.activeWindowScript)
        try tools.install("xprop", script: FakeLinuxTools.recordArguments + #"""

            [ "$#" -eq 3 ] && [ "$1" = -id ] && [ "$2" = 12345 ] && [ "$3" = WM_CLASS ] || exit 1
            printf '%s\n' 'WM_CLASS(STRING) = "xterm", "XTerm"'
            """#)
        XCTAssertEqual(tracker.captureTarget(), .linux(session: .otherX11, x11WindowClass: "XTerm"))
        XCTAssertEqual(tools.arguments, [["getactivewindow"], ["-id", "12345", "WM_CLASS"]])
        try tools.install("xprop", script: "printf '%s\\n' 'WM_CLASS(STRING) = \"instance\", \"\(AppIdentity.linuxAppID.uppercased())\"'")
        XCTAssertNil(tracker.captureTarget())
        try tools.install("xprop", script: "printf '%s\\n' 'WM_CLASS(STRING) = \"\(AppIdentity.linuxAppID.uppercased())\", \"Class\"'")
        XCTAssertNil(tracker.captureTarget())
    }

    func testX11RejectsMalformedWindowIDsBeforeQueryingClass() throws {
        for windowID in ["", "0", "-1", "+12345", "0x3039", "12345\n67890", "12 345", "１２３４５",
                         "18446744073709551616"] {
            let tools = try FakeLinuxTools()
            tools.environment["FAKE_WINDOW_ID"] = windowID
            try tools.install("xdotool", script: Self.activeWindowScript)
            try tools.install("xprop", script: FakeLinuxTools.recordArguments + "\nexit 1")
            let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
            XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
            XCTAssertEqual(tools.arguments, [["getactivewindow"]])
        }
    }

    func testX11RequiresXprop() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: Self.activeWindowScript)
        let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
        XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
        XCTAssertEqual(tools.arguments, [["getactivewindow"]])
    }

    func testX11RejectsMalformedWMClass() throws {
        let invalidProperties = [
            "", "XTerm", "WM_CLASS:  not found.",
            #"WM_CLASS(ATOM) = "xterm", "XTerm""#,
            #"WM_CLASS(STRING) = "XTerm""#,
            #"WM_CLASS(STRING) = xterm, "XTerm""#,
            #"WM_CLASS(STRING) = "xterm", XTerm"#,
            #"WM_CLASS(STRING) = "xterm", """#,
            #"WM_CLASS(STRING) = "xterm", "XTerm", "extra""#,
            #"WM_CLASS(STRING) = "xterm", "XTerm" trailing"#,
            #"prefix WM_CLASS(STRING) = "xterm", "XTerm""#,
            #"WM_CLASS(STRING) = "xterm", "X\"Term""#,
            "WM_CLASS(STRING) = \"xterm\", \"XTerm\"\nextra",
            "WM_CLASS(STRING) = \"xterm\", \"X\nTerm\"",
        ]
        for property in invalidProperties {
            let tools = try FakeLinuxTools()
            tools.environment["FAKE_WM_CLASS"] = property
            try tools.install("xdotool", script: Self.activeWindowScript)
            try tools.install("xprop", script: FakeLinuxTools.recordArguments + "\nprintf '%s\\n' \"$FAKE_WM_CLASS\"")
            let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
            XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
            XCTAssertEqual(tools.arguments, [["getactivewindow"], ["-id", "12345", "WM_CLASS"]])
        }
    }

    func testX11ClassQueryTimeoutReturnsNoTarget() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: Self.activeWindowScript)
        try tools.install("xprop", script: "exec /bin/sleep 10")
        let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
        let start = ContinuousClock().now
        XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(1))
    }

    func testX11QueriesShareOneProbeBudget() throws {
        let tools = try FakeLinuxTools()
        // Each tool fits in 250 ms separately; their combined wait does not.
        try tools.install("xdotool", script: "/bin/sleep 0.15\n" + Self.activeWindowScript)
        try tools.install("xprop", script: FakeLinuxTools.recordArguments + #"""

            /bin/sleep 0.15
            printf '%s\n' 'WM_CLASS(STRING) = "xterm", "XTerm"'
            """#)
        let session = LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false)
        let start = ContinuousClock().now
        XCTAssertNil(LinuxFocusTracker(session: session, runner: tools.runner).captureTarget())
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(1))
        XCTAssertEqual(tools.arguments, [["getactivewindow"], ["-id", "12345", "WM_CLASS"]])
    }

    func testWaylandNeverQueriesXWayland() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments + "\nprintf XTerm")
        try tools.install("xprop", script: FakeLinuxTools.recordArguments + "\nexit 1")
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

    private static let activeWindowScript = FakeLinuxTools.recordArguments + #"""

        # xdotool 3.20160805 rejects getwindowclassname.
        for argument in "$@"; do
            [ "$argument" != getwindowclassname ] || exit 1
        done
        [ "$#" -eq 1 ] && [ "$1" = getactivewindow ] || exit 1
        printf '%s\n' "${FAKE_WINDOW_ID-12345}"
        """#
}
#endif
