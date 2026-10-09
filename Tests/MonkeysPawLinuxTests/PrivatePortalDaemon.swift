#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawLinux

/// A second isolated bus lets a test kill the daemon without breaking GTK's
/// private session. Arguments, output reads and the child lifetime are bounded.
final class PrivatePortalDaemon {
    private static let addressCap = 4_096
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mp-portal-bus-" + UUID().uuidString)
    private let process = Process()
    private let output = Pipe()
    private var watchdog: guint = 0
    private(set) var address = ""

    var isRunning: Bool { process.isRunning }

    init(lifetime: Duration = .seconds(5)) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = directory.appendingPathComponent("bus.conf")
            try Data(Self.config(socket: directory.appendingPathComponent("socket").path).utf8).write(to: config)
            process.executableURL = try XCTUnwrap(LinuxToolRunner().executable("dbus-daemon"))
            process.arguments = ["--config-file=" + config.path, "--nofork", "--print-address=1"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try output.fileHandleForWriting.close()

            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw NSError(domain: "PrivatePortalDaemon", code: 1)
            }
            watchdog = GTK.after(lifetime.timeInterval) { [weak self] in
                guard let self else { return }
                self.watchdog = 0
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: Self.addressCap)
            XCTAssertTrue(GTKTestSupport.spin(until: {
                let count = Glibc.read(descriptor, &buffer, buffer.count)
                if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
                return bytes.contains(0x0a) || bytes.count > Self.addressCap || !self.process.isRunning
            }, timeout: .seconds(1)), "Private daemon startup timed out.")
            guard bytes.count <= Self.addressCap, bytes.contains(0x0a),
                  let text = String(data: bytes, encoding: .utf8), text.hasPrefix("unix:") else {
                throw NSError(domain: "PrivatePortalDaemon", code: 2)
            }
            address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            stop()
            throw NSError(domain: "PrivatePortalDaemon", code: 3)
        }
    }

    deinit { stop() }

    func stop() {
        if watchdog != 0 { g_source_remove(watchdog); watchdog = 0 }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        XCTAssertTrue(GTKTestSupport.spin(until: { !self.process.isRunning }, timeout: .seconds(1)),
                      "Private daemon did not exit.")
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func config(socket: String) -> String { """
        <busconfig>
          <type>session</type><listen>unix:path=\(socket)</listen>
          <policy context='default'>
            <allow own='*'/><allow send_destination='*'/><allow receive_sender='*'/>
          </policy>
        </busconfig>
        """ }
}
#endif
