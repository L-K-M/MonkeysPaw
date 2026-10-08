#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class PortalTokenStoreTests: XCTestCase {
    private var directory: URL!
    private var paths: LinuxPaths!
    private var store: PortalTokenStore!
    private var file: URL { paths.dataDirectory.appendingPathComponent("portal.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = LinuxPaths(environment: ["XDG_DATA_HOME": directory.path], home: directory)
        store = PortalTokenStore(paths: paths)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testAbsentCreateAndReplaceEverySave() throws {
        XCTAssertEqual(store.load(), .absent)
        let first = try XCTUnwrap(PortalRestoreToken("fixture-first"))
        let second = try XCTUnwrap(PortalRestoreToken("fixture-second"))
        try store.save(first)
        XCTAssertEqual(store.load(), .loaded(first))
        let initial = try FileManager.default.attributesOfItem(atPath: file.path)
        try store.save(second)
        XCTAssertEqual(store.load(), .loaded(second))
        let replacement = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(initial[.systemFileNumber] as? NSNumber, replacement[.systemFileNumber] as? NSNumber)
        try store.save(second)
        let repeated = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(replacement[.systemFileNumber] as? NSNumber, repeated[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path), ["portal.json"])
    }

    func testFileIsOwnerPrivateEvenWhenReplacingAnInsecureFile() throws {
        let token = try XCTUnwrap(PortalRestoreToken("fixture-permissions"))
        try store.save(token)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(paths.dataDirectory), 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.ownerAccountID] as? NSNumber)?.uint32Value,
                       geteuid())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(store.load(), .corrupt)
        try store.save(token)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(store.load(), .loaded(token))
    }

    func testCorruptAndOversizedInputCanBeReplaced() throws {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        let samples = [Data(), Data("not JSON".utf8), Data("{}".utf8),
            Data("{\"restoreToken\": 7}".utf8), Data("{\"restoreToken\": \"\"}".utf8),
            Data("{\"restoreToken\": \"bad\\u0000token\"}".utf8),
            Data(repeating: 0x78, count: Limits.portalTokenFileMaxBytes + 1)]
        for sample in samples {
            try sample.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertEqual(store.load(), .corrupt)
        }
        let token = try XCTUnwrap(PortalRestoreToken("fixture-recovery"))
        try store.save(token)
        XCTAssertEqual(store.load(), .loaded(token))
    }

    func testTokenRepresentationIsBoundedOpaqueAndRedacted() throws {
        XCTAssertNil(PortalRestoreToken(""))
        XCTAssertNil(PortalRestoreToken("line\nbreak"))
        XCTAssertNil(PortalRestoreToken("null\0byte"))
        XCTAssertNil(PortalRestoreToken(String(repeating: "x", count: Limits.portalTokenMaxBytes + 1)))
        let opaque = try XCTUnwrap(PortalRestoreToken("opaque/Unicode-λ-✓"))
        XCTAssertEqual(opaque.description, "<portal restore token>")
        try store.save(opaque)
        XCTAssertEqual(store.load(), .loaded(opaque))
    }

    func testSymlinkAndNonregularFilesAreNotRead() throws {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("other.json")
        try Data("{\"restoreToken\": \"fixture-other\"}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertEqual(store.load(), .corrupt)
        let token = try XCTUnwrap(PortalRestoreToken("fixture-replacement"))
        try store.save(token)
        XCTAssertEqual(store.load(), .loaded(token))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertEqual(store.load(), .corrupt)
    }

    func testWriteFailureIsExplicitAndLeavesNoTemporaryFiles() throws {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let token = try XCTUnwrap(PortalRestoreToken("fixture-failure"))
        XCTAssertThrowsError(try store.save(token)) { error in
            XCTAssertTrue(error is PortalTokenStore.WriteError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path), ["portal.json"])
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
#endif
