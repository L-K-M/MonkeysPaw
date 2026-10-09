#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class KDEHotkeyChoiceStoreTests: XCTestCase {
    func testChoiceIsAnAtomicPrivateEnumRecordWithoutShortcutValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LinuxPaths(environment: ["XDG_DATA_HOME": directory.path], home: directory)
        let file = paths.dataDirectory.appendingPathComponent("shortcut-mechanism.json")
        let store = KDEHotkeyChoiceStore(paths: paths)
        XCTAssertEqual(store.load(), .absent)
        try store.save(.portal)
        let first = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((first[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String], ["mechanism": "portal"])
        try store.save(.native)
        let replacement = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(first[.systemFileNumber] as? NSNumber, replacement[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(store.load(), .loaded(.native))
        for invalid in [Data("{\"mechanism\":\"other\"}".utf8), Data("{\"mechanism\":true}".utf8),
                        Data(repeating: 0x78, count: Limits.shortcutChoiceFileMaxBytes + 1)] {
            try invalid.write(to: file)
            XCTAssertEqual(store.load(), .corrupt)
        }
        try store.save(.portal)
        XCTAssertEqual(store.load(), .loaded(.portal))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path), ["shortcut-mechanism.json"])
    }

    func testSymlinkFIFOAndInsecureRecordRecoverOnlyThroughExplicitSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LinuxPaths(environment: ["XDG_DATA_HOME": directory.path], home: directory)
        let store = KDEHotkeyChoiceStore(paths: paths)
        let file = paths.dataDirectory.appendingPathComponent("shortcut-mechanism.json")
        try store.save(.portal)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(store.load(), .corrupt)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertEqual(store.load(), .corrupt)
        try store.save(.native)
        let other = directory.appendingPathComponent("foreign.json")
        try Data("{\"mechanism\":\"portal\"}".utf8).write(to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertEqual(store.load(), .corrupt)
        try store.save(.native)
        XCTAssertEqual(store.load(), .loaded(.native))
        XCTAssertEqual(try Data(contentsOf: other), Data("{\"mechanism\":\"portal\"}".utf8))
    }
}
#endif
