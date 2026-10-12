#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxProcessSignalTests: XCTestCase {
    func testStartupAllowsStderrLoggingToAClosedPipe() throws {
        // SwiftPM can inherit SIG_IGN. Start from SIG_DFL so the test proves
        // the app's hook, then restore the runner's disposition on every exit.
        let previous = Glibc.signal(SIGPIPE, SIG_DFL)
        defer { _ = Glibc.signal(SIGPIPE, previous) }
        MonkeysPawLinuxApp.ignoreBrokenPipeSignal()

        // Reinstalling SIG_IGN inspects the hook without risking termination
        // of the test runner if the hook regresses.
        let installed = Glibc.signal(SIGPIPE, SIG_IGN)
        guard unsafeBitCast(installed, to: UInt.self) == unsafeBitCast(SIG_IGN, to: UInt.self) else {
            XCTFail("App startup must ignore SIGPIPE before any I/O")
            return
        }

        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForReading.close()
        StandardErrorLog(output: pipe.fileHandleForWriting).write(.warning, "File logging unavailable")

        var byte: UInt8 = 0
        XCTAssertEqual(Glibc.write(pipe.fileHandleForWriting.fileDescriptor, &byte, 1), -1)
        XCTAssertEqual(errno, EPIPE)
    }
}
#endif
