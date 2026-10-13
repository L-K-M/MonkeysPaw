#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

/// Launch the real executable on the private bus and observe its X11 windows.
/// Calling the environment directly would bypass remote command-line routing.
final class LinuxLauncherStartupTests: XCTestCase {
    private var bus: FakeStatusNotifierWatcher!
    private var tools: FakeLinuxTools!
    private var windowTools: LinuxToolRunner!
    private var childEnvironment: [String: String] = [:]
    private var children: [Process] = []
    private var files: RootedFileStore!
    private var settings: SettingsModel!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        try GTKTestSupport.requireDisplay()
        var environment = ProcessInfo.processInfo.environment
        if let libraries = environment["MONKEYSPAW_HOST_X11_LIBRARIES"] {
            environment["LD_LIBRARY_PATH"] = libraries
        }
        windowTools = LinuxToolRunner(environment: environment)
        guard environment["DISPLAY"]?.isEmpty == false,
              windowTools.executable("xdotool") != nil,
              windowTools.executable("gapplication") != nil,
              windowTools.executable("xprop") != nil,
              let openbox = windowTools.executable("openbox") else {
            if environment["MONKEYSPAW_REQUIRE_DISPLAY"] == "1" {
                XCTFail("Executable launcher tests require X11, xdotool, gapplication, xprop and Openbox.")
                throw NSError(domain: "LinuxLauncherStartupTests", code: 1)
            }
            throw XCTSkip("Requires X11, xdotool, gapplication, xprop and Openbox.")
        }

        let windowManager = Process()
        windowManager.executableURL = openbox
        windowManager.arguments = ["--sm-disable"]
        windowManager.environment = environment
        windowManager.standardInput = FileHandle.nullDevice
        windowManager.standardOutput = FileHandle.nullDevice
        windowManager.standardError = FileHandle.nullDevice
        try windowManager.run()
        children.append(windowManager)
        XCTAssertTrue(GTKTestSupport.spin {
            guard case .success(let output) = self.windowTools.run("xprop",
                arguments: ["-root", "_NET_SUPPORTING_WM_CHECK"], timeout: .seconds(1)) else { return false }
            return windowManager.isRunning && output.text.contains("0x")
        }, "The test window manager did not start.")

        bus = try FakeStatusNotifierWatcher(address: address)
        tools = try FakeLinuxTools()
        childEnvironment = environment
        childEnvironment["DBUS_SESSION_BUS_ADDRESS"] = address
        childEnvironment["PATH"] = tools.directory.path
        childEnvironment["HOME"] = tools.directory.path
        childEnvironment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        childEnvironment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        childEnvironment["XDG_SESSION_TYPE"] = "wayland"
        childEnvironment["XDG_CURRENT_DESKTOP"] = "sway"
        childEnvironment["GDK_BACKEND"] = "x11"
        let paths = LinuxPaths(environment: childEnvironment)
        files = try RootedFileStore(root: paths.configDirectory)
        settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        settings.markSetupPresented()
        XCTAssertNil(settings.error)
    }

    override func tearDown() {
        for child in children.reversed() {
            // Let Openbox remove its root properties before the next test.
            if child.isRunning { child.terminate() }
            if !GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(1)) {
                kill(child.processIdentifier, SIGKILL)
            }
            XCTAssertTrue(GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(1)),
                "The test app did not exit during cleanup.")
        }
        children.removeAll()
        bus?.shutdown()
        bus = nil
        settings = nil
        files = nil
        tools = nil
        windowTools = nil
        childEnvironment = [:]
    }

    func testResidentLaunchResumesPendingFolderStep() throws {
        XCTAssertFalse(settings.firstRun.libraryFolderCompleted)
        try assertPendingStepResumes()
    }

    func testResidentLaunchResumesPendingSeedOffer() throws {
        settings.completeLibraryFolderStep()
        XCTAssertNil(settings.error)
        XCTAssertFalse(settings.firstRun.seedsOffered)
        try assertPendingStepResumes()
    }

    func testResidentLaunchResumesStartupLibraryRecovery() throws {
        completeFirstRun()
        settings.setLibraryFolder(tools.directory.appendingPathComponent("missing-library").path)
        XCTAssertNil(settings.error)
        try assertPendingStepResumes()
    }

    func testCompletedFirstRunLaunchOpensAndRaisesPicker() throws {
        completeFirstRun()
        let primary = try launch([])
        let picker = try waitForWindow(titled: AppIdentity.displayName, in: primary)
        try focus(picker)

        // A launcher request opens/raises even an already focused picker.
        // Explicit toggle actions retain their separate close behavior.
        assertCleanExit(try launch([]))
        XCTAssertEqual(try waitForWindow(titled: AppIdentity.displayName, in: primary), picker)
        try close(picker, titled: AppIdentity.displayName, in: primary)
        assertCleanExit(try launch([]))
        XCTAssertEqual(try waitForWindow(titled: AppIdentity.displayName, in: primary), picker)
        XCTAssertNil(visibleWindow(titled: LinuxStrings.onboarding, in: primary))
        XCTAssertNil(visibleWindow(titled: LinuxStrings.setup, in: primary))
        try quit(primary)
    }

    func testServiceLaunchStaysHiddenAndToggleActionStillOpensAndClosesPicker() throws {
        let primary = try launch(["--gapplication-service"])
        XCTAssertTrue(GTKTestSupport.spin { self.bus.hasOwner(AppIdentity.linuxAppID) })
        XCTAssertNil(visibleWindow(titled: LinuxStrings.onboarding, in: primary))
        XCTAssertNil(visibleWindow(titled: AppIdentity.displayName, in: primary))
        assertCleanExit(try launch(["--gapplication-service"]))
        XCTAssertNil(visibleWindow(titled: AppIdentity.displayName, in: primary))

        try action(.toggle)
        let picker = try waitForWindow(titled: AppIdentity.displayName, in: primary)
        XCTAssertNil(visibleWindow(titled: LinuxStrings.onboarding, in: primary))
        try focus(picker)
        try action(.toggle)
        XCTAssertTrue(GTKTestSupport.spin {
            self.visibleWindow(titled: AppIdentity.displayName, in: primary) == nil
        })
        XCTAssertTrue(primary.isRunning)
        try quit(primary)
    }

    func testOrdinaryLaunchOfServicePrimaryResumesPendingFolderStep() throws {
        let primary = try launch(["--gapplication-service"])
        XCTAssertTrue(GTKTestSupport.spin { self.bus.hasOwner(AppIdentity.linuxAppID) })
        assertCleanExit(try launch([]))
        let onboarding = try waitForWindow(titled: LinuxStrings.onboarding, in: primary)
        try close(onboarding, titled: LinuxStrings.onboarding, in: primary)
        assertCleanExit(try launch([]))
        XCTAssertEqual(try waitForWindow(titled: LinuxStrings.onboarding, in: primary), onboarding)
        XCTAssertNil(visibleWindow(titled: AppIdentity.displayName, in: primary))
        try quit(primary)
    }

    private func assertPendingStepResumes() throws {
        let progress = try files.read(at: "settings.json")
        let primary = try launch([])
        let onboarding = try waitForWindow(titled: LinuxStrings.onboarding, in: primary)
        XCTAssertNil(visibleWindow(titled: LinuxStrings.setup, in: primary))
        XCTAssertNil(visibleWindow(titled: AppIdentity.displayName, in: primary))
        try close(onboarding, titled: LinuxStrings.onboarding, in: primary)
        XCTAssertTrue(primary.isRunning, "Closing onboarding must leave the primary resident.")

        assertCleanExit(try launch([]))
        XCTAssertEqual(try waitForWindow(titled: LinuxStrings.onboarding, in: primary), onboarding,
            "An ordinary remote launch must reopen the pending onboarding window.")
        // The same saved progress and unavailable root keep the same step
        // pending; presenting or closing it must not consume folder/seeds.
        XCTAssertEqual(try files.read(at: "settings.json"), progress)
        XCTAssertNil(visibleWindow(titled: LinuxStrings.setup, in: primary))
        XCTAssertNil(visibleWindow(titled: AppIdentity.displayName, in: primary))
        try quit(primary)
    }

    private func completeFirstRun() {
        settings.completeLibraryFolderStep()
        settings.markSeedsOffered()
        settings.completeTour()
        XCTAssertNil(settings.error)
    }

    private static let launchedWindowTimeout: Duration = .seconds(20)

    private func visibleWindow(titled title: String, in child: Process) -> String? {
        let result = windowTools.run("xdotool", arguments: ["search", "--onlyvisible", "--all",
            "--pid", String(child.processIdentifier), "--name", "^" + NSRegularExpression.escapedPattern(for: title) + "$"],
            timeout: .seconds(1), acceptedStatuses: [0, 1])
        guard case .success(let output) = result else {
            XCTFail("Could not query the test app's X11 windows.")
            return nil
        }
        return output.text.split(separator: "\n").first.map(String.init)
    }

    private func waitForWindow(titled title: String, in child: Process) throws -> String {
        var window: String?
        // A cold child launch on a loaded CI runner can take several seconds,
        // and each probe is a bounded xdotool process.
        _ = GTKTestSupport.spin(until: {
            window = self.visibleWindow(titled: title, in: child)
            return window != nil || !child.isRunning
        }, timeout: Self.launchedWindowTimeout)
        if let window { return window }

        return try XCTUnwrap(window, windowFailureDetails(titled: title, in: child))
    }

    private func windowFailureDetails(titled title: String, in child: Process) -> String {
        let state = child.isRunning ? "still running"
            : "exited with status \(child.terminationStatus) (\(child.terminationReason))"
        var details = ["Expected visible window '\(title)' from PID \(child.processIdentifier); child \(state)."]
        // Include hidden windows and our app class: GTK can omit _NET_WM_PID
        // in a sandbox, so repeating only the failed PID query loses evidence.
        guard case .success(let output) = windowTools.run("xdotool",
            arguments: ["search", "--any", "--pid", String(child.processIdentifier),
                "--class", "^" + NSRegularExpression.escapedPattern(for: AppIdentity.linuxAppID) + "$"],
            timeout: .seconds(1), acceptedStatuses: [0, 1]) else {
            details.append("Could not query the child's X11 windows.")
            return details.joined(separator: "\n")
        }
        let windows = output.text.split(separator: "\n")
        if windows.isEmpty { details.append("No X11 windows matched the child PID or app class.") }
        for window in windows {
            if case .success(let properties) = windowTools.run("xprop",
                arguments: ["-id", String(window), "WM_NAME", "WM_CLASS", "_NET_WM_PID", "WM_STATE"],
                timeout: .seconds(1)) {
                details.append("Window \(window): \(properties.text)")
            } else {
                details.append("Could not read X11 properties of window \(window).")
            }
        }
        return details.joined(separator: "\n")
    }

    private func close(_ window: String, titled title: String, in child: Process) throws {
        // Send the native close protocol to this exact window. A global Alt+F4
        // depends on the window manager's current keyboard focus;
        // xdotool's windowclose destroys X11 windows instead of requesting close.
        let display = try XCTUnwrap(gdk_display_get_default())
        let instance = UnsafeMutableRawPointer(display).assumingMemoryBound(to: GTypeInstance.self)
        guard g_type_check_instance_is_a(instance, gdk_x11_display_get_type()) != 0 else {
            XCTFail("Native launcher close tests require an X11 display.")
            throw NSError(domain: "LinuxLauncherStartupTests", code: 4)
        }
        let xdisplay = try XCTUnwrap(gdk_x11_display_get_xdisplay(display))
        let id = try XCTUnwrap(UInt(window))
        var event = XEvent()
        event.xclient.type = ClientMessage
        event.xclient.display = xdisplay
        event.xclient.window = id
        event.xclient.message_type = gdk_x11_get_xatom_by_name_for_display(display, "WM_PROTOCOLS")
        event.xclient.format = 32
        event.xclient.data.l.0 = Int(gdk_x11_get_xatom_by_name_for_display(display, "WM_DELETE_WINDOW"))

        // GTK links Xlib transitively; resolve this test-only call without
        // adding an Xlib dependency to the package or production shim.
        let library = try XCTUnwrap(dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(library) }
        typealias SendEvent = @convention(c) (OpaquePointer?, UInt, Int32, Int, UnsafeMutablePointer<XEvent>?) -> Int32
        let send = unsafeBitCast(try XCTUnwrap(dlsym(library, "XSendEvent")), to: SendEvent.self)
        XCTAssertNotEqual(send(xdisplay, id, 0, 0, &event), 0)
        gdk_display_flush(display)
        XCTAssertTrue(GTKTestSupport.spin { self.visibleWindow(titled: title, in: child) == nil },
            "Native close did not hide the app window.")
    }

    private func focus(_ window: String) throws {
        try runTool("xdotool", arguments: ["windowactivate", "--sync", window])
        // A toggle hides only an active picker, and the hotkey path debounces
        // repeats. Wait until the window manager reports the picker active and
        // the debounce interval has passed before sending the next toggle.
        XCTAssertTrue(GTKTestSupport.spin {
            guard case .success(let output) = self.windowTools.run("xdotool", arguments: ["getactivewindow"],
                timeout: .seconds(1)) else { return false }
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines) == window
        }, "The picker did not become the active window.")
        let settled = Date().addingTimeInterval(Limits.toggleDebounce.timeInterval * 3)
        _ = GTKTestSupport.spin { Date() >= settled }
    }

    private func action(_ action: ActionName) throws {
        try runTool("gapplication", arguments: ["action", AppIdentity.linuxAppID, action.rawValue])
    }

    private func runTool(_ name: String, arguments: [String]) throws {
        guard case .success = windowTools.run(name, arguments: arguments, timeout: .seconds(3)) else {
            XCTFail("The executable lifecycle test tool did not complete successfully.")
            throw NSError(domain: "LinuxLauncherStartupTests", code: 2)
        }
    }

    private func quit(_ primary: Process) throws {
        try action(.quit)
        assertCleanExit(primary)
    }

    private func launch(_ arguments: [String]) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/monkeyspaw")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Build the monkeyspaw product before running executable lifecycle tests.")
            throw NSError(domain: "LinuxLauncherStartupTests", code: 3)
        }
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        child.environment = childEnvironment
        child.standardInput = FileHandle.nullDevice
        // Keep GTK/GLib startup errors in the test log, including early exits
        // that would otherwise look like a window-mapping timeout.
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run()
        children.append(child)
        return child
    }

    private func assertCleanExit(_ child: Process, file: StaticString = #filePath, line: UInt = #line) {
        let exited = GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(8))
        XCTAssertTrue(exited, "The app did not exit.", file: file, line: line)
        guard exited else { return }
        XCTAssertEqual(child.terminationReason, .exit, file: file, line: line)
        XCTAssertEqual(child.terminationStatus, 0, file: file, line: line)
    }
}
#endif
