#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxSecretToolRunnerTests: XCTestCase {
    func testChildEnvironmentOmitsProviderOverridesAndKeepsSessionSettings() throws {
        let tools = try FakeLinuxTools()
        let variable = "MONKEYSPAW_PROVIDER_0123456789ABCDEF0123456789ABCDEF_API_KEY"
        tools.environment[variable] = "parent-only-key"
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = "test-session-bus"
        try tools.install("secret-tool", script: #"""
        if [ "${MONKEYSPAW_PROVIDER_0123456789ABCDEF0123456789ABCDEF_API_KEY+x}" ]; then exit 9; fi
        printf '%s' "$DBUS_SESSION_BUS_ADDRESS"
        """#)
        let output = try tools.runner.run("secret-tool", arguments: []).get()
        XCTAssertEqual(output.text, "test-session-bus")
        XCTAssertEqual(tools.runner.environment[variable], "parent-only-key")
    }

    func testSecretStdinAndVerbatimStdoutUseAbsoluteExecutableAndSeparateArguments() throws {
        let tools = try FakeLinuxTools()
        try tools.install("secret-tool", script: #"printf '%s\n' "$0" > "$FAKE_EXEC""# + "\n"
            + FakeLinuxTools.recordArguments + "\n/bin/cat")
        tools.environment["FAKE_EXEC"] = tools.directory.appendingPathComponent("executable").path
        let secret = "  stdin-only\nsecret\n"
        let arguments = ["store", "--label", "Monkey's Paw", "account", "provider:one"]

        let output = try tools.runner.run("secret-tool", arguments: arguments,
            input: Data(secret.utf8), textOutput: .verbatim).get()

        XCTAssertEqual(output.text, secret)
        XCTAssertEqual(tools.arguments, [arguments])
        XCTAssertEqual(try String(contentsOfFile: tools.environment["FAKE_EXEC"]!, encoding: .utf8),
            tools.directory.appendingPathComponent("secret-tool").path + "\n")
        XCTAssertFalse(tools.log.joined().contains(secret))
    }

    func testStdinAndStdoutDrainTogetherAndStderrIsDiscarded() throws {
        let tools = try FakeLinuxTools()
        try tools.install("secret-tool", script: "/usr/bin/head -c 131072 /dev/zero >&2\n"
            + "/usr/bin/head -c 32768 /dev/zero\n/bin/cat >/dev/null\nprintf 'done'")
        let output = try tools.runner.run("secret-tool", arguments: [],
            input: Data(repeating: 65, count: 131_072)).get()
        XCTAssertEqual(output.text.utf8.count, 32_772)
        XCTAssertTrue(output.text.hasSuffix("done"))
    }

    func testNonzeroBasedStdinSlicePreservesAllBytes() throws {
        let tools = try FakeLinuxTools()
        try tools.install("secret-tool", script: "exec /bin/cat")
        let data = Data(("discard" + String(repeating: "  slice\n", count: 2_048)).utf8)
        let input = data.dropFirst(7)
        XCTAssertGreaterThan(input.startIndex, 0)

        let output = try tools.runner.run("secret-tool", arguments: [],
            input: input, textOutput: .verbatim).get()

        XCTAssertEqual(Data(output.text.utf8), input)
    }

    func testNonzeroExitDoesNotExposeToolOutput() throws {
        let tools = try FakeLinuxTools()
        let stdout = "stdout-sentinel-\(UUID().uuidString)"
        let stderr = "stderr-sentinel-\(UUID().uuidString)"
        tools.environment["FAKE_STDOUT"] = stdout
        tools.environment["FAKE_STDERR"] = stderr
        try tools.install("secret-tool", script: #"printf '%s' "$FAKE_STDOUT"; printf '%s' "$FAKE_STDERR" >&2; exit 1"#)
        let result = tools.runner.run("secret-tool", arguments: [], input: Data("secret".utf8))
        guard case .failure(let error) = result else { return XCTFail("Nonzero exit must be a typed failure") }
        guard case .unknown = error else { return XCTFail("Expected a typed unknown failure") }
        for output in [String(describing: error), String(reflecting: error), String(reflecting: result), tools.log.joined()] {
            XCTAssertFalse(output.contains(stdout))
            XCTAssertFalse(output.contains(stderr))
        }
    }

    func testClosedStdinReturnsFailureWithoutSigpipe() throws {
        // SIGPIPE is process-global; this bundle uses serial XCTest execution.
        let previous = Glibc.signal(SIGPIPE, SIG_IGN)
        defer { _ = Glibc.signal(SIGPIPE, previous) }
        let tools = try FakeLinuxTools()
        try tools.install("secret-tool", script: "exec 0<&-\nexec /bin/sleep 10")
        let start = ContinuousClock.now
        guard case .failure(.unknown) = tools.runner.run("secret-tool", arguments: [],
            input: Data(repeating: 65, count: 131_072)) else { return XCTFail("EPIPE must fail safely") }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testFullStdinHasOneDeadlineAndKilledChildIsReaped() throws {
        let tools = try FakeLinuxTools()
        let pidFile = tools.directory.appendingPathComponent("pid")
        tools.environment["FAKE_PID"] = pidFile.path
        try tools.install("secret-tool", script: #"printf '%s' "$$" > "$FAKE_PID""#
            + "\nexec /bin/sleep 10")
        let start = ContinuousClock.now
        guard case .failure(.timeout) = tools.runner.run("secret-tool", arguments: [],
            timeout: .milliseconds(100), input: Data(repeating: 65, count: 131_072)) else {
            return XCTFail("A blocked writer must respect the deadline")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        let pid = try String(contentsOf: pidFile, encoding: .utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: "/proc/\(pid)/stat"), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/proc/\(pid)/stat"))
    }
}
#endif
