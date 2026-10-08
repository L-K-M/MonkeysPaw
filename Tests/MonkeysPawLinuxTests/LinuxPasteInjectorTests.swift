#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPasteInjectorTests: XCTestCase {
    private let modernHelp = "printf 'Usage: ydotool <cmd> <args>\\n  key\\nYDOTOOL_SOCKET\\n'"

    func testXdotoolChordsUseArgumentArrays() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments)
        let injector = XdotoolPasteInjector(runner: tools.runner)
        assertPaste(injector, chord: .standard, equals: .sent)
        assertPaste(injector, chord: .terminal, equals: .sent)
        XCTAssertEqual(tools.log, ["key --clearmodifiers ctrl+v", "key --clearmodifiers ctrl+shift+v"])
    }

    func testPathSkipsAnExecutableDirectory() throws {
        let first = try FakeLinuxTools()
        let actual = try FakeLinuxTools()
        try FileManager.default.createDirectory(at: first.directory.appendingPathComponent("xdotool"),
                                               withIntermediateDirectories: true)
        try actual.install("xdotool", script: "exit 0")
        first.environment["PATH"] = first.directory.path + ":" + actual.directory.path
        XCTAssertEqual(first.runner.executable("xdotool")?.path,
                       actual.directory.appendingPathComponent("xdotool").path)
        assertPaste(XdotoolPasteInjector(runner: first.runner), equals: .sent)
    }

    func testModernYdotoolChordsAndExplicitSocket() throws {
        let tools = try modernTools()
        try tools.install("ydotool", script: """
            \(FakeLinuxTools.recordArguments)
            if [ "$1" = help ]; then \(modernHelp); exit 0; fi
            printf '%s\\n' "$YDOTOOL_SOCKET" >> "$FAKE_LOG"
            """)
        let injector = YdotoolPasteInjector(runner: tools.runner)
        assertPaste(injector, chord: .standard, equals: .sent)
        assertPaste(injector, chord: .terminal, equals: .sent)
        XCTAssertEqual(tools.log, ["help", "key 29:1 47:1 47:0 29:0", tools.environment["YDOTOOL_SOCKET"]!,
            "key 29:1 42:1 47:1 47:0 42:0 29:0", tools.environment["YDOTOOL_SOCKET"]!])
    }

    func testLegacyHelpOnStderrUsesOnlySymbolicKeys() throws {
        let tools = try FakeLinuxTools()
        try tools.install("ydotool", script: """
            \(FakeLinuxTools.recordArguments)
            if [ "$1" = help ]; then printf 'Usage: ydotool <cmd> <args>\\n  key\\n' >&2; exit 1; fi
            """)
        let injector = YdotoolPasteInjector(runner: tools.runner, socketReachable: {
            XCTAssertEqual($0, YdotoolSocket.legacyPath)
            return true
        })
        assertPaste(injector, chord: .standard, equals: .sent)
        assertPaste(injector, chord: .terminal, equals: .sent)
        XCTAssertEqual(tools.log, ["help", "key ctrl+v", "key ctrl+shift+v"])
    }

    func testUnrecognizedOrAmbiguousHelpNeverInjects() throws {
        for help in ["printf unknown", modernHelp + "; exit 1", "printf 'Usage: ydotool <cmd> <args>\\n  key\\n'"] {
            let tools = try FakeLinuxTools()
            try tools.install("ydotool", script: FakeLinuxTools.recordArguments + "\n" + help)
            assertPaste(YdotoolPasteInjector(runner: tools.runner), equals: .failed(.unknown))
            XCTAssertEqual(tools.log, ["help"])
        }
    }

    func testMissingToolsAndNonzeroExitAreTyped() throws {
        let tools = try FakeLinuxTools()
        assertPaste(XdotoolPasteInjector(runner: tools.runner), equals: .failed(.toolMissing))
        assertPaste(YdotoolPasteInjector(runner: tools.runner), equals: .failed(.toolMissing))
        try tools.install("xdotool", script: "printf 'tool diagnostic' >&2\nexit 2")
        assertPaste(XdotoolPasteInjector(runner: tools.runner), equals: .failed(.unknown))
        let modern = try modernTools()
        try modern.install("ydotool", script: "if [ \"$1\" = help ]; then \(modernHelp); exit 0; fi\nexit 2")
        assertPaste(YdotoolPasteInjector(runner: modern.runner), equals: .failed(.unknown))
    }

    func testMissingUnreadableAndStaleSocketsDenyInjection() throws {
        let tools = try FakeLinuxTools()
        try tools.install("ydotool", script: FakeLinuxTools.recordArguments + "\n" + modernHelp)
        tools.environment["YDOTOOL_SOCKET"] = tools.directory.appendingPathComponent("missing").path
        assertPaste(YdotoolPasteInjector(runner: tools.runner), equals: .failed(.permissionDenied))
        let socket = try tools.makeSocket()
        tools.environment["YDOTOOL_SOCKET"] = socket
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: socket)
        assertPaste(YdotoolPasteInjector(runner: tools.runner), equals: .failed(.permissionDenied))
        XCTAssertTrue(tools.log.allSatisfy { $0 == "help" })
        let stale = tools.directory.appendingPathComponent("regular-file")
        try Data().write(to: stale)
        XCTAssertFalse(YdotoolSocket.isReachable(stale.path))
    }

    func testSocketResolutionHonorsOverrideThenRuntimeThenTmp() throws {
        let tools = try FakeLinuxTools()
        let socket = try tools.makeSocket()
        XCTAssertEqual(YdotoolSocket.path(in: ["YDOTOOL_SOCKET": "/explicit", "XDG_RUNTIME_DIR": tools.directory.path]), "/explicit")
        XCTAssertEqual(YdotoolSocket.path(in: ["XDG_RUNTIME_DIR": tools.directory.path]), socket)
        XCTAssertEqual(YdotoolSocket.path(in: ["XDG_RUNTIME_DIR": "/missing"]), YdotoolSocket.legacyPath)
        XCTAssertTrue(YdotoolSocket.isReachable(socket))
    }

    func testHangingToolCompletesOnceWithTimeout() throws {
        let tools = try FakeLinuxTools()
        // exec ensures the killed process is the sleeper, with no orphan child.
        let pidFile = tools.directory.appendingPathComponent("child-pid")
        tools.environment["FAKE_PID"] = pidFile.path
        try tools.install("xdotool", script: "printf '%s' \"$$\" > \"$FAKE_PID\"\nexec /bin/sleep 10")
        let start = ContinuousClock().now
        assertPaste(XdotoolPasteInjector(runner: tools.runner), equals: .failed(.timeout))
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(4))
        let pid = try String(contentsOf: pidFile, encoding: .utf8)
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: "/proc/\(pid)/stat"), ContinuousClock().now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Foundation's Process monitor must reap the SIGKILL'd child even though
        // the driver never blocks the callback on waitUntilExit.
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/proc/\(pid)/stat"))
    }

    func testLargeStderrDoesNotBlock() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: "/usr/bin/head -c 131072 /dev/zero >&2\nexit 0")
        let start = ContinuousClock().now
        assertPaste(XdotoolPasteInjector(runner: tools.runner), equals: .sent)
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(4))
    }

    func testImmediateExitPreservesFinalOutput() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: "printf 'final-marker'\nexit 0")

        let output = try tools.runner.run("xdotool", arguments: []).get()
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.text, "final-marker")
    }

    func testExitAfterEmptyReadPreservesFinalOutput() throws {
        let tools = try FakeLinuxTools()
        let pidFile = tools.directory.appendingPathComponent("child-pid")
        tools.environment["FAKE_PID"] = pidFile.path
        try tools.install("xdotool", script: """
            printf '%s' "$$" > "$FAKE_PID"
            printf 'final-marker'
            exit 0
            """)

        var firstRead = true
        let runner = LinuxToolRunner(environment: tools.environment, readOutput: { descriptor, buffer, capacity in
            if !firstRead { return Glibc.read(descriptor, buffer, capacity) }
            firstRead = false

            // Force the scheduling race: an empty read is followed by the tool's
            // write and exit before the runner checks isRunning. Leave its bytes
            // in the real pipe so only a subsequent drain can recover them.
            let deadline = ContinuousClock().now.advanced(by: .seconds(1))
            var reaped = false
            while ContinuousClock().now < deadline {
                if let pid = try? String(contentsOf: pidFile, encoding: .utf8),
                   !pid.isEmpty, !FileManager.default.fileExists(atPath: "/proc/\(pid)/stat") {
                    reaped = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            XCTAssertTrue(reaped, "The tool must exit before the simulated empty read returns")
            errno = EAGAIN
            return -1
        })

        let output = try runner.run("xdotool", arguments: []).get()
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.text, "final-marker")
    }

    func testInheritedPipeCannotExtendTheToolDeadline() throws {
        let tools = try FakeLinuxTools()
        try tools.install("xdotool", script: "/bin/sleep 3 &\nexit 0")
        let start = ContinuousClock().now
        let result = tools.runner.run("xdotool", arguments: [], timeout: .milliseconds(100))
        guard case .failure(let failure) = result else {
            XCTFail("An inherited writer must not bypass the tool deadline")
            return
        }
        XCTAssertEqual(failure, .timeout)
        XCTAssertLessThan(ContinuousClock().now - start, .seconds(2))
    }

    private func modernTools() throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        tools.environment["YDOTOOL_SOCKET"] = try tools.makeSocket()
        return tools
    }

    private func assertPaste(_ injector: PasteInjector, chord: PasteChord = .standard,
                             equals expected: PasteAttemptResult,
                             file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "Exactly one paste completion")
        done.assertForOverFulfill = true
        injector.paste(chord: chord) { result in
            XCTAssertFalse(Thread.isMainThread, file: file, line: line)
            XCTAssertEqual(result, expected, file: file, line: line)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
#endif
