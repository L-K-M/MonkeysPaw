#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

/// Exercise the executable's primary/remote/diagnostic lifecycle on the real
/// private bus, so composition tests alone cannot mask a missing start hook.
final class LinuxTrayStartupTests: XCTestCase {
    private var watcher: FakeStatusNotifierWatcher!
    private var tools: FakeLinuxTools!
    private var childEnvironment: [String: String] = [:]
    private var children: [Process] = []

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        try GTKTestSupport.requireDisplay()
        watcher = try FakeStatusNotifierWatcher(address: address)
        tools = try FakeLinuxTools()
        childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["DBUS_SESSION_BUS_ADDRESS"] = address
        childEnvironment["PATH"] = tools.directory.path
        childEnvironment["HOME"] = tools.directory.path
        childEnvironment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        childEnvironment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        childEnvironment["XDG_SESSION_TYPE"] = "wayland"
        childEnvironment["XDG_CURRENT_DESKTOP"] = "sway"
        if let libraries = childEnvironment["MONKEYSPAW_HOST_X11_LIBRARIES"] {
            childEnvironment["LD_LIBRARY_PATH"] = libraries
        }
        let paths = LinuxPaths(environment: childEnvironment)
        let settings = SettingsModel(settings: SettingsService(store:
            SettingsStore(files: try RootedFileStore(root: paths.configDirectory))))
        settings.markSetupPresented()
        settings.completeLibraryFolderStep()
        settings.markSeedsOffered()
        XCTAssertNil(settings.error)
    }

    override func tearDown() {
        for child in children {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            XCTAssertTrue(GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(1)),
                "The test app did not exit during cleanup.")
        }
        children.removeAll()
        watcher?.shutdown()
        watcher = nil
        tools = nil
        childEnvironment = [:]
    }

    func testInteractiveStartupRegistersAndTrayQuitExitsCleanly() throws {
        try assertResidentStartupAndQuit(arguments: [])
    }

    func testServiceStartupRegistersAndTrayQuitExitsCleanly() throws {
        try assertResidentStartupAndQuit(arguments: ["--gapplication-service"])
    }

    func testRemoteLaunchesDoNotStartAnotherItem() throws {
        try watcher.ownName()
        let primary = try launch(["--gapplication-service"])
        let name = itemName(for: primary)
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.map(\.service) == [name] })
        for arguments in [[], ["--gapplication-service"]] {
            let remote = try launch(arguments)
            assertCleanExit(remote)
            XCTAssertFalse(watcher.hasOwner(itemName(for: remote)))
            XCTAssertTrue(primary.isRunning)
            XCTAssertEqual(watcher.registrations.map(\.service), [name])
        }
        try quitFromTray(primary)
        assertCleanExit(primary)
    }

    func testCLIOneShotsDoNotStartATrayItem() throws {
        try watcher.ownName()
        for arguments in [["--version"], ["--help"], ["--selftest"]] {
            let child = try launch(arguments)
            assertCleanExit(child)
            XCTAssertTrue(watcher.registrations.isEmpty, "A CLI one-shot registered a tray item.")
            XCTAssertFalse(watcher.hasOwner(itemName(for: child)))
        }
    }

    func testServiceWithoutWatcherStaysResidentAndExistingQuitActionExits() throws {
        // Stock GNOME has no StatusNotifierWatcher. Missing tools are isolated
        // too, so this cannot change the host's GNOME shortcut configuration.
        childEnvironment["XDG_CURRENT_DESKTOP"] = "GNOME"
        let child = try launch(["--gapplication-service"])
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.hasOwner(self.itemName(for: child)) })
        XCTAssertTrue(child.isRunning)
        XCTAssertTrue(watcher.registrations.isEmpty)
        XCTAssertFalse(watcher.hasOwner("org.kde.StatusNotifierWatcher"))
        let reply = watcher.call(path: "/ch/lkmc/monkeyspaw", interface: "org.gtk.Actions", method: "Activate",
            body: "('quit', @av [], @a{sv} {})", destination: AppIdentity.linuxAppID)
        XCTAssertFalse(reply.failed)
        assertCleanExit(child)
        XCTAssertFalse(watcher.hasOwner(itemName(for: child)))
    }

    private func assertResidentStartupAndQuit(arguments: [String]) throws {
        try watcher.ownName()
        let child = try launch(arguments)
        let name = itemName(for: child)
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.map(\.service) == [name] })
        XCTAssertTrue(child.isRunning)
        XCTAssertTrue(watcher.hasOwner(name))
        let sender = try XCTUnwrap(watcher.registrations.first?.sender)
        XCTAssertFalse(watcher.call(method: "GetLayout", body: "(0, -1, @as [])", destination: name).failed)
        try quitFromTray(child)
        assertCleanExit(child)
        XCTAssertFalse(watcher.hasOwner(name))
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(0, -1, @as [])", destination: sender).failed)
    }

    private func quitFromTray(_ child: Process) throws {
        let reply = watcher.call(method: "Event", body: "(5, 'clicked', <0>, uint32 0)", destination: itemName(for: child))
        XCTAssertFalse(reply.failed)
        guard !reply.failed else { throw NSError(domain: "LinuxTrayStartupTests", code: 1) }
    }

    private func launch(_ arguments: [String]) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/monkeyspaw")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Build the monkeyspaw product before running executable lifecycle tests.")
            throw NSError(domain: "LinuxTrayStartupTests", code: 2)
        }
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        child.environment = childEnvironment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        children.append(child)
        return child
    }

    private func assertCleanExit(_ child: Process, file: StaticString = #filePath, line: UInt = #line) {
        let exited = GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(8))
        XCTAssertTrue(exited, "The app did not release its hold and exit.", file: file, line: line)
        guard exited else { return }
        XCTAssertEqual(child.terminationReason, .exit, file: file, line: line)
        XCTAssertEqual(child.terminationStatus, 0, file: file, line: line)
    }

    private func itemName(for child: Process) -> String {
        "org.kde.StatusNotifierItem-\(child.processIdentifier)-1"
    }
}
#endif
