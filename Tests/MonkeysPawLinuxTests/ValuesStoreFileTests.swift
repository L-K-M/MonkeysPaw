#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class ValuesStoreFileTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var outside: URL!
    private var files: RootedFileStore!
    private var values: ValuesStore!
    private let manager = FileManager.default
    private let identity = PromptIdentity.local(String(repeating: "a", count: 64))
    private let other = PromptIdentity.local(String(repeating: "b", count: 64))

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("data")
        outside = directory.appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        files = try RootedFileStore(root: root)
        values = ValuesStore(files: files)
    }

    override func tearDown() { try? manager.removeItem(at: directory) }

    func testForgetReplacementsKeep0600AndOtherPromptFields() throws {
        // umask is process-wide; this suite runs serially within the process.
        let previousMask = umask(0)
        defer { _ = umask(previousMask) }
        let url = root.appendingPathComponent("values.json")
        try values.record(identity: identity, values: ["field": "forgotten", "stale": "old"])
        let retained = ["field": "kept", "empty": "", "other": "also kept"]
        try values.record(identity: other, values: retained)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try values.remove(identity: identity)
        XCTAssertEqual(try values.rememberedValues(for: identity), [:])
        XCTAssertEqual(try values.rememberedValues(for: other), retained)
        XCTAssertEqual(try permissions(at: url), 0o600)

        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try values.removeAll()
        XCTAssertEqual(try files.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        XCTAssertEqual(try ValuesStore(files: files).rememberedValues(for: other), [:])
        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path), ["values.json"])
    }

    func testAbsentPromptDoesNotCreateRootButGlobalResetCreatesPrivateDocument() throws {
        try values.remove(identity: identity)
        XCTAssertFalse(manager.fileExists(atPath: root.path))

        try values.removeAll()
        XCTAssertEqual(try files.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        XCTAssertEqual(try permissions(at: root.appendingPathComponent("values.json")), 0o600)
    }

    func testGlobalResetRecoversUnreadableRegularFileWithoutReadingIt() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses file read permissions.") }
        let url = root.appendingPathComponent("values.json")
        try values.record(identity: identity, values: ["field": "old"])
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        XCTAssertThrowsError(try values.remove(identity: identity)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try permissions(at: url), 0)

        try values.removeAll()
        XCTAssertEqual(try files.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        XCTAssertEqual(try permissions(at: url), 0o600)
    }

    func testForgetRejectsLinkedValuesWithoutChangingOutsideTarget() throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("private.json")
        let bytes = Data("outside state".utf8)
        try bytes.write(to: target)
        let link = root.appendingPathComponent("values.json")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        for operation in [{ try self.values.remove(identity: self.identity) },
                          { try self.values.removeAll() }] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
            }
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertEqual(try manager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
                           .typeSymbolicLink)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path), ["values.json"])
        }
    }

    func testGlobalResetRejectsNonregularValuesAndReplacedDataRoot() throws {
        let path = root.appendingPathComponent("values.json")
        try manager.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try values.removeAll()) {
            XCTAssertEqual($0 as? FileStoreError, .notRegularFile)
        }
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: root.path), ["values.json"])

        try manager.removeItem(at: root)
        let target = outside.appendingPathComponent("values.json")
        let bytes = Data("outside state".utf8)
        try bytes.write(to: target)
        try manager.createSymbolicLink(at: root, withDestinationURL: outside)
        XCTAssertThrowsError(try values.removeAll()) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: outside.path), ["values.json"])
    }

    private func permissions(at url: URL) throws -> Int? {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}
#endif
