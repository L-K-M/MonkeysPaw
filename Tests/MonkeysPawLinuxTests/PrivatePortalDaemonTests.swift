#if os(Linux)
import Foundation
import XCTest

final class PrivatePortalDaemonTests: XCTestCase {
    func testKilledDaemonSocketIsInsideItsPrivateDirectory() throws {
        _ = try FakePortal.requirePrivateBus()
        let daemon = try PrivatePortalDaemon()
        defer { daemon.stop() }
        let path = try XCTUnwrap(daemon.address.components(separatedBy: "path=").last?
            .components(separatedBy: ",").first)
        XCTAssertTrue(URL(fileURLWithPath: path).deletingLastPathComponent()
            .lastPathComponent.hasPrefix("mp-portal-bus-"))
    }

    func testFiredWatchdogAllowsIdempotentStop() throws {
        _ = try FakePortal.requirePrivateBus()
        let daemon = try PrivatePortalDaemon(lifetime: .milliseconds(100))
        XCTAssertTrue(GTKTestSupport.spin { !daemon.isRunning })
        daemon.stop()
        daemon.stop()
    }
}
#endif
