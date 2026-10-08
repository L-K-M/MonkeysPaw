#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawLinux

/// An isolated PATH snapshot, never a mutation of the test process's environment.
final class FakeLinuxTools {
    let directory: URL
    var environment: [String: String]
    private var sockets: [Int32] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        environment = ["PATH": directory.path, "FAKE_LOG": directory.appendingPathComponent("argv").path]
    }

    deinit {
        sockets.forEach { _ = Glibc.close($0) }
        try? FileManager.default.removeItem(at: directory)
    }

    func install(_ name: String, script: String) throws {
        let executable = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func makeSocket(name: String = ".ydotool_socket") throws -> String {
        let path = directory.appendingPathComponent(name).path
        let descriptor = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        sockets.append(descriptor)
        let status = try XCTUnwrap(YdotoolSocket.withAddress(path) {
            bind(descriptor, $0, $1)
        })
        XCTAssertEqual(status, 0)
        return path
    }

    var log: [String] {
        arguments.map { $0.joined(separator: " ") }
    }

    var arguments: [[String]] {
        let path = directory.appendingPathComponent("argv")
        return (try? String(contentsOf: path, encoding: .utf8))?
            .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) } ?? []
    }

    var runner: LinuxToolRunner { LinuxToolRunner(environment: environment) }

    static let recordArguments = #"printf '%s\t' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG""#
}
#endif
