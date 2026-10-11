#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLogCompositionTests: XCTestCase {
    func testDefaultPolicyWritesOnlyWarningsAndErrorsIntoInjectedXDGDataRoot() throws {
        try withEnvironment(logValue: nil) { environment, file in
            environment.log.write(.debug, "stage started")
            environment.log.write(.info, "loaded 3 prompts")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            environment.log.write(.warning, "backend unavailable")
            environment.log.write(.error, "save failed")

            let output = try String(contentsOf: file, encoding: .utf8)
            let lines = output.split(separator: "\n")
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines[0].hasSuffix(" warning: backend unavailable"))
            XCTAssertTrue(lines[1].hasSuffix(" error: save failed"))
            let timestamp = try XCTUnwrap(lines[0].split(separator: " ").first)
            XCTAssertTrue(timestamp.hasSuffix("Z"))
            XCTAssertNotNil(ISO8601DateFormatter().date(from: String(timestamp)))
        }
    }

    func testPolicyUsesInjectedEnvironmentValue() throws {
        try withEnvironment(logValue: "DeBuG") { environment, file in
            environment.log.write(.debug, "stage started")
            let output = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(output.hasSuffix(" debug: stage started\n"))
        }
    }

    private func withEnvironment(logValue: String?, body: (LinuxEnvironment, URL) throws -> Void) throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["MONKEYSPAW_LOG"] = logValue
        let environment = LinuxEnvironment(application: application, environment: tools.environment)
        defer { environment.shutdown() }
        let file = tools.directory.appendingPathComponent("data/monkeyspaw/logs/monkeyspaw.log")
        try body(environment, file)
    }
}
#endif
