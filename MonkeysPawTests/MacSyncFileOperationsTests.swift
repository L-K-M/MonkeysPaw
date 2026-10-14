import Darwin
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacSyncFileOperationsTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var files: RootedFileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
        try files.pinRoot()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func expectation(_ path: String) throws -> SyncFileExpectation {
        .matching(stamp: try XCTUnwrap(files.stamp(at: path)), bytes: try files.read(at: path))
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber).intValue
    }

    private func failure(_ code: SyncFileFailureCode, effect: SyncFileMutationEffect = .unchanged,
                         _ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual((error as? SyncFileOperationError)?.code, code, file: file, line: line)
            XCTAssertEqual((error as? SyncFileOperationError)?.effect, effect, file: file, line: line)
        }
    }

    func testPublicationAndRoleTransitionsKeepExactBytesAndNormalUmaskMode() throws {
        let path = RelativePath("Groups/Team/one.md")
        let bytes = Data("---\ntitle: 'Exact' # kept\n---\nLine\r\n".utf8)
        XCTAssertNil(try files.publish(bytes, at: path, expecting: .absent, mode: .readOnly).displacedBytes)
        XCTAssertEqual(try files.read(at: path.string), bytes)
        XCTAssertEqual(try mode(path.string), 0o444)
        try files.create(Data(), at: "ordinary.md")
        let ordinary = try mode("ordinary.md")
        try files.setMode(.normal, at: path)
        XCTAssertEqual(try mode(path.string), ordinary)
        try files.setMode(.readOnly, at: path)
        let next = Data("Replacement\n".utf8)
        let publication = try files.publish(next, at: path, expecting: expectation(path.string), mode: .normal)
        XCTAssertEqual(publication.displacedBytes, bytes)
        XCTAssertEqual(try files.read(at: path.string), next)
        XCTAssertEqual(try mode(path.string), ordinary)
        XCTAssertFalse(try files.listFiles().contains { $0.relativePath.contains(".monkeyspaw-sync-") })
    }

    func testCheckedBytesAndIncarnationRejectStaleExpectations() throws {
        try files.write(Data("Before".utf8), at: "one.md")
        let old = try expectation("one.md")
        try files.write(Data("Changed".utf8), at: "one.md")
        failure(.changed) { _ = try files.publish(Data("Incoming".utf8), at: "one.md", expecting: old, mode: .normal) }
        XCTAssertEqual(try files.read(at: "one.md"), Data("Changed".utf8))
        failure(.changed) { _ = try files.publish(Data(), at: "one.md", expecting: .absent, mode: .normal) }
        let stamp = try XCTUnwrap(files.stamp(at: "one.md"))
        failure(.changed) {
            _ = try files.publish(Data(), at: "one.md", expecting: .matching(stamp: stamp, bytes: Data("Wrong".utf8)), mode: .normal)
        }
    }

    func testPostPublicationFlushFailureRetainsDisplacedBytesForRecovery() throws {
        let before = Data("Losing version".utf8), after = Data("Server version".utf8)
        try files.write(before, at: "one.md")
        let old = try expectation("one.md")
        var published = false
        let faulty = try RootedFileStore(root: root, syncIO: .init(flush: { descriptor in
            !published && fsync(descriptor) == 0
        }, rename: { from, source, to, destination in
            let result = renameat(from, source, to, destination) == 0
            published = result
            return result
        }))
        XCTAssertThrowsError(try faulty.publish(after, at: "one.md", expecting: old, mode: .readOnly)) { error in
            let failure = error as? SyncFileOperationError
            XCTAssertEqual(failure?.effect, .applied)
            XCTAssertEqual(failure?.code, .durabilityFailed)
            XCTAssertEqual(failure?.displacedBytes, before)
        }
        XCTAssertEqual(try files.read(at: "one.md"), after)
        XCTAssertEqual(try mode("one.md"), 0o444)
        // Replay recognizes installed bytes instead of pretending the failed
        // publication left the old version. Reflush through a fresh driver.
        let recovered = try RootedFileStore(root: root)
        failure(.changed) { _ = try recovered.publish(after, at: "one.md", expecting: old, mode: .readOnly) }
        try recovered.flushFile(at: "one.md")
        try recovered.flushDirectory(at: nil)
        XCTAssertEqual(try recovered.read(at: "one.md"), after)
    }

    func testFailedPrepublicationFlushAndRenameLeaveOriginalBytes() throws {
        try files.write(Data("Original".utf8), at: "one.md")
        let old = try expectation("one.md")
        let flushFailure = try RootedFileStore(root: root, syncIO: .init(flush: { _ in false }))
        failure(.durabilityFailed) { _ = try flushFailure.publish(Data("Incoming".utf8), at: "one.md", expecting: old, mode: .normal) }
        let renameFailure = try RootedFileStore(root: root, syncIO: .init(rename: { _, _, _, _ in false }))
        failure(.ioFailure) { _ = try renameFailure.publish(Data("Incoming".utf8), at: "one.md", expecting: old, mode: .normal) }
        XCTAssertEqual(try files.read(at: "one.md"), Data("Original".utf8))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["one.md"])
    }

    func testDirectoryFlushFailureIsAppliedAfterPublicationAndRemode() throws {
        try files.write(Data("Before".utf8), at: "one.md")
        var published = false
        let faulty = try RootedFileStore(root: root, syncIO: .init(flush: { descriptor in
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0 else { return false }
            if published && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return false }
            return fsync(descriptor) == 0
        }, rename: { from, source, to, destination in
            published = renameat(from, source, to, destination) == 0
            return published
        }))
        failure(.durabilityFailed, effect: .applied) {
            _ = try faulty.publish(Data("After".utf8), at: "one.md", expecting: expectation("one.md"), mode: .normal)
        }
        XCTAssertEqual(try files.read(at: "one.md"), Data("After".utf8))
        let remode = try RootedFileStore(root: root, syncIO: .init(flush: { _ in false }))
        failure(.durabilityFailed, effect: .applied) { try remode.setMode(.readOnly, at: "one.md") }
        XCTAssertEqual(try mode("one.md"), 0o444)
    }

    func testTrashFailurePreservesSourceAndSuccessfulMoveRemainsRecoverableAfterFlushFailure() throws {
        let bytes = Data("Recoverable".utf8)
        try files.write(bytes, at: "one.md")
        let old = try expectation("one.md")
        let refused = try RootedFileStore(root: root, syncIO: .init(trash: { _ in throw FileStoreError.ioFailure }))
        failure(.ioFailure) { try refused.trash(at: "one.md", expecting: old) }
        XCTAssertEqual(try files.read(at: "one.md"), bytes)
        let trash = directory.appendingPathComponent("fake-system-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let destination = trash.appendingPathComponent("one.md")
        let unflushed = try RootedFileStore(root: root, syncIO: .init(flush: { _ in false }, trash: { source in
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }))
        failure(.durabilityFailed, effect: .applied) { try unflushed.trash(at: "one.md", expecting: old) }
        XCTAssertNil(try files.stamp(at: "one.md"))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testDirectoryOperationsNeverMergeRecurseOrCreateRenameParents() throws {
        try files.createDirectory(at: "Groups/Team")
        try files.createDirectory(at: "Groups/Occupied")
        try files.write(Data("Member".utf8), at: "Groups/Team/one.md")
        failure(.occupied) { try files.createDirectory(at: "Groups/Team") }
        failure(.occupied) { try files.renameDirectory(from: "Groups/Team", to: "Groups/Occupied") }
        failure(.notFound) { try files.renameDirectory(from: "Groups/Team", to: "missing/Team") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        let identity = try XCTUnwrap(files.directoryIdentity(at: "Groups/Team"))
        failure(.occupied) { try files.removeEmptyDirectory(at: "Groups/Team", expecting: identity) }
        try files.renameDirectory(from: "Groups/Team", to: "Groups/Renamed")
        XCTAssertEqual(try files.directoryIdentity(at: "Groups/Renamed"), identity)
        XCTAssertEqual(try files.read(at: "Groups/Renamed/one.md"), Data("Member".utf8))
        try files.delete(at: "Groups/Renamed/one.md")
        try files.removeEmptyDirectory(at: "Groups/Renamed", expecting: identity)
        try files.createDirectory(at: "Groups/Renamed")
        XCTAssertNotEqual(try files.directoryIdentity(at: "Groups/Renamed"), identity)
        failure(.changed) { try files.removeEmptyDirectory(at: "Groups/Renamed", expecting: identity) }
    }

    func testDirectoryIdentityIgnoresChildEditsAndEnumerationIncludesEmptyHiddenDirectories() throws {
        try files.createDirectory(at: "Groups/Empty")
        try files.createDirectory(at: "Groups/.hidden")
        let identity = try files.directoryIdentity(at: "Groups/Empty")
        try files.write(Data("Child".utf8), at: "Groups/Empty/one.md")
        XCTAssertEqual(try files.directoryIdentity(at: "Groups/Empty"), identity)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Groups/link"), withDestinationURL: outside)
        XCTAssertEqual(try files.directories(at: "Groups"), ["Groups/.hidden", "Groups/Empty"])
        failure(.invalidPath) { _ = try files.directoryIdentity(at: "Groups/link") }
    }

    func testMaximumWrappedPathWorksThroughOrdinaryAndDurableOperations() throws {
        let wire = (Array(repeating: String(repeating: "a", count: 200), count: 4)
            + [String(repeating: "b", count: 217) + ".md"]).joined(separator: "/")
        let path = "Groups/" + String(repeating: "g", count: 255) + "/" + wire
        XCTAssertEqual(wire.utf8.count, Limits.maxPathBytes)
        XCTAssertEqual(path.utf8.count, Limits.maxRootedPathBytes)
        let bytes = Data("Maximum path".utf8)
        _ = try files.publish(bytes, at: RelativePath(path), expecting: .absent, mode: .readOnly)
        XCTAssertEqual(try files.read(at: path), bytes)
        XCTAssertNotNil(try files.stamp(at: path))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), [path])
        try files.setMode(.normal, at: RelativePath(path))
        try files.write(Data("Edited".utf8), at: path)
        XCTAssertEqual(try files.read(at: path), Data("Edited".utf8))
        failure(.invalidPath) { _ = try files.publish(Data(), at: RelativePath(path + "x"), expecting: .absent, mode: .normal) }
        try files.delete(at: path)
        XCTAssertNil(try files.stamp(at: path))
    }

    func testSlashCombiningTraversalAndLinkedParentsStayInsideRoot() throws {
        let path = "one/\u{301}two/three.md"
        _ = try files.publish(Data("Exact path".utf8), at: RelativePath(path), expecting: .absent, mode: .normal)
        XCTAssertEqual(try files.listFiles().map(\.relativePath), [path])
        XCTAssertEqual(try files.read(at: path), Data("Exact path".utf8))
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        for path in ["../escape.md", "a/../escape.md", "link/\u{301}escape.md"] {
            failure(.invalidPath) { _ = try files.publish(Data(), at: RelativePath(path), expecting: .absent, mode: .normal) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling.md"), withDestinationURL: outside.appendingPathComponent("missing"))
        failure(.invalidPath) { _ = try files.publish(Data(), at: "dangling.md", expecting: .absent, mode: .normal) }
    }

    func testPinnedLostOrReplacedRootNeverBecomesAnEmptyWritableLibrary() throws {
        try files.write(Data("Cached".utf8), at: "one.md")
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("old"))
        XCTAssertThrowsError(try files.listFiles())
        XCTAssertThrowsError(try files.write(Data(), at: "late.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let replacement = try RootedFileStore(root: root)
        try replacement.createRoot()
        try replacement.write(Data("New graph".utf8), at: "new.md")
        XCTAssertThrowsError(try files.listFiles())
        failure(.notFound) { _ = try files.publish(Data(), at: "late.md", expecting: .absent, mode: .normal) }
        XCTAssertEqual(try replacement.listFiles().map(\.relativePath), ["new.md"])
    }
}
