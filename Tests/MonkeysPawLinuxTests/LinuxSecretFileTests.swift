#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxSecretFileTests: XCTestCase {
    private let account = try! SecretAccount(namespace: "provider", name: "test")

    func testLabelVersionModeAndAtomicReplacementPreserveOtherAccounts() throws {
        let (tools, store, file) = try fixture()
        let other = try SecretAccount(namespace: "device", name: "test")
        XCTAssertNil(try store.read(account: account))
        try store.write(SecretValue("old-key"), account: account)
        let descriptor = Glibc.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let old = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? old.close() }
        let original = try Data(contentsOf: file)
        var oldInfo = stat()
        XCTAssertEqual(fstat(descriptor, &oldInfo), 0)

        try store.write(SecretValue("device-token"), account: other)
        try store.write(SecretValue("new-key"), account: account)
        XCTAssertEqual(try old.readToEnd(), original, "An open reader sees the complete old inode")
        var newInfo = stat()
        XCTAssertEqual(lstat(file.path, &newInfo), 0)
        XCTAssertNotEqual(newInfo.st_ino, oldInfo.st_ino)
        XCTAssertEqual(newInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(newInfo.st_uid, geteuid())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["storage"] as? String, "unencrypted")
        XCTAssertEqual(try store.read(account: account), SecretValue("new-key"))
        XCTAssertEqual(try store.read(account: other), SecretValue("device-token"))
        try store.write(nil, account: account)
        try store.write(nil, account: account)
        XCTAssertNil(try store.read(account: account))
        XCTAssertEqual(try store.read(account: other), SecretValue("device-token"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
            [file.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tools.directory.path))
    }

    func testOversizedWritePreservesOldMapAndLeavesNoTemporaryCopies() throws {
        let (tools, store, file) = try fixture()
        defer { withExtendedLifetime(tools) {} }
        try store.write(SecretValue("old-key"), account: account)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.write(SecretValue(String(repeating: "s", count: Limits.valuesFileCapBytes)),
            account: account))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
            [file.lastPathComponent])
    }

    func testLeafSymlinksIncludingDanglingLinksAreRefusedWithoutChangingTarget() throws {
        let (tools, store, file) = try fixture()
        try store.write(SecretValue("initial"), account: account)
        try FileManager.default.removeItem(at: file)
        let target = tools.directory.appendingPathComponent("target")
        try Data("target-bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("secret"), account: account))
        XCTAssertThrowsError(try store.write(nil, account: account))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target-bytes")
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("secret"), account: account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testConfigRootAndAncestorSymlinksAreRefused() throws {
        let (tools, store, file) = try fixture()
        try store.write(SecretValue("old-key"), account: account)
        let root = file.deletingLastPathComponent()
        let original = try Data(contentsOf: file)
        let moved = tools.directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(file.lastPathComponent)), original)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: moved, to: root)
        let config = root.deletingLastPathComponent()
        let movedConfig = tools.directory.appendingPathComponent("moved-config")
        try FileManager.default.moveItem(at: config, to: movedConfig)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: movedConfig)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
    }

    func testHardlinksInsecureModesAndNonregularFilesAreRefused() throws {
        let (tools, store, file) = try fixture()
        try store.write(SecretValue("key"), account: account)
        let link = tools.directory.appendingPathComponent("hardlink")
        XCTAssertEqual(Glibc.link(file.path, link.path), 0)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
        try FileManager.default.removeItem(at: link)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let start = ContinuousClock.now
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
    }

    func testCorruptFutureUnlabelledAndOversizedRecordsArePreserved() throws {
        let (tools, store, file) = try fixture()
        defer { withExtendedLifetime(tools) {} }
        try store.write(SecretValue("key"), account: account)
        for record in [
            Data("not-json".utf8),
            Data(#"{"version":2,"storage":"unencrypted","secrets":{}}"#.utf8),
            Data(#"{"version":1,"storage":"encrypted","secrets":{}}"#.utf8),
            Data(#"{"version":1,"storage":"unencrypted","secrets":{"bad:account:name":"key"}}"#.utf8),
            Data(repeating: 65, count: Limits.valuesFileCapBytes + 1)
        ] {
            try record.write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertThrowsError(try store.read(account: account))
            XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account))
            XCTAssertThrowsError(try store.write(nil, account: account))
            XCTAssertEqual(try Data(contentsOf: file), record)
        }
    }

    private func fixture() throws -> (FakeLinuxTools, LinuxSecretFile, URL) {
        let tools = try FakeLinuxTools()
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        let paths = LinuxPaths(environment: tools.environment)
        return (tools, LinuxSecretFile(paths: paths), paths.configDirectory.appendingPathComponent("secrets-unencrypted.json"))
    }
}
#endif
