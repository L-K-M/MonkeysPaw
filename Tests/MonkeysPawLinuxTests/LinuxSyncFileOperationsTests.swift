#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxSyncFileOperationsTests: XCTestCase {
    private var temporary: URL!
    private var root: URL!
    private var trash: URL!
    private var store: RootedFileStore!

    override func setUpWithError() throws {
        try GTKTestSupport.requireDisplay()
        _ = try FakePortal.requirePrivateBus()
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mp-sync-files-\(UUID())")
        root = temporary.appendingPathComponent("library")
        trash = temporary.appendingPathComponent("Trash")
        store = try RootedFileStore(root: root, trashRoot: trash)
        try store.createRoot()
        store.bindSyncRoot()
    }

    override func tearDown() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    func testSlashWithCombiningMarkStillTraversesAndChecksParents() throws {
        let path = "folder/\u{301}name.md"
        try store.write(Data("original".utf8), at: path)
        XCTAssertEqual(try store.read(at: path), Data("original".utf8))
        XCTAssertEqual(try store.listFiles().map(\.relativePath), [path])
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("folder"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("folder"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.write(Data("blocked".utf8), at: path)) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testDurablePublicationChecksBytesStampAndModesOnEveryReplacement() throws {
        let original = Data("original\r\n".utf8)
        let replacement = Data("replacement\n".utf8)
        let path: RelativePath = "nested/a.md"
        XCTAssertNil(try store.publish(original, at: path, expecting: .absent, mode: .readOnly).displacedBytes)
        XCTAssertEqual(try permissions(path), 0o444)
        let stamp = try XCTUnwrap(store.stamp(at: path.string))
        let publication = try store.publish(replacement, at: path, expecting: .matching(stamp: stamp, bytes: original), mode: .normal)
        XCTAssertEqual(publication.displacedBytes, original)
        XCTAssertEqual(try store.read(at: path.string), replacement)
        try store.write(Data(), at: "ordinary.md")
        XCTAssertEqual(try permissions(path), try permissions("ordinary.md"))
        assertFailure(.changed) {
            _ = try self.store.publish(original, at: path, expecting: .matching(stamp: stamp, bytes: original), mode: .readOnly)
        }
        assertFailure(.occupied) { _ = try self.store.publish(original, at: path, expecting: .absent, mode: .normal) }
        try store.setMode(.readOnly, at: path)
        XCTAssertEqual(try permissions(path), 0o444)
        try store.setMode(.normal, at: path)
        XCTAssertEqual(try permissions(path), try permissions("ordinary.md"))
        try store.flushFile(at: path)
        try store.flushDirectory(at: "nested")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("nested").path), ["a.md"])
    }

    func testAbsoluteRootTraversalAlsoSplitsSlashBeforeCombiningScalars() throws {
        let selected = URL(fileURLWithPath: temporary.path + "/parent/\u{301}selected", isDirectory: true)
        let files = try RootedFileStore(root: selected, trashRoot: trash)
        try files.createRoot()
        _ = try files.publish(Data("root".utf8), at: "a.md", expecting: .absent, mode: .normal)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("a.md")), Data("root".utf8))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["a.md"])
    }

    func testPostRenameFlushFailureReportsAppliedAndExactDisplacedBytes() throws {
        let bytes = Data("losing bytes".utf8)
        try store.write(bytes, at: "a.md")
        let stamp = try XCTUnwrap(store.stamp(at: "a.md"))
        let failing = try RootedFileStore(root: root, trashRoot: trash, syncDescriptor: { descriptor in
            var info = Glibc.stat()
            if fstat(descriptor, &info) == 0, info.st_mode & mode_t(Glibc.S_IFMT) == mode_t(Glibc.S_IFDIR) {
                errno = EIO
                return -1
            }
            return Glibc.fsync(descriptor)
        })
        XCTAssertThrowsError(try failing.publish(Data("installed".utf8), at: "a.md",
            expecting: .matching(stamp: stamp, bytes: bytes), mode: .readOnly)) {
            let error = $0 as? SyncFileOperationError
            XCTAssertEqual(error?.code, .durabilityFailed)
            XCTAssertEqual(error?.effect, .applied)
            XCTAssertEqual(error?.displacedBytes, bytes)
        }
        XCTAssertEqual(try store.read(at: "a.md"), Data("installed".utf8))
        XCTAssertEqual(try permissions("a.md"), 0o444)
        XCTAssertEqual(try store.listFiles().map(\.relativePath), ["a.md"])
    }

    func testPrePublicationFlushFailureLeavesOriginalUnchanged() throws {
        try store.write(Data("original".utf8), at: "a.md")
        let failing = try RootedFileStore(root: root, syncDescriptor: { _ in errno = EIO; return -1 })
        assertFailure(.durabilityFailed) {
            _ = try failing.publish(Data("new".utf8), at: "b.md", expecting: .absent, mode: .normal)
        }
        XCTAssertEqual(try store.read(at: "a.md"), Data("original".utf8))
        XCTAssertEqual(try store.listFiles().map(\.relativePath), ["a.md"])
    }

    func testMaximumWrappedPathAndEverySlashScalarArePreserved() throws {
        let wire = String(repeating: String(repeating: "a", count: 250) + "/", count: 4) + String(repeating: "b", count: 17) + ".md"
        let path = "Groups/" + String(repeating: "G", count: 255) + "/" + wire
        XCTAssertEqual(path.utf8.count, Limits.maxRootedPathBytes)
        _ = try store.publish(Data("full path".utf8), at: RelativePath(path), expecting: .absent, mode: .normal)
        XCTAssertEqual(try store.read(at: path), Data("full path".utf8))
        XCTAssertEqual(try store.listFiles().map(\.relativePath), [path])
        assertFailure(.invalidPath) { _ = try self.store.publish(Data(), at: RelativePath(path + "x"), expecting: .absent, mode: .normal) }
        for invalid in ["/a.md", "a//b.md", "a/../b.md", "a/./b.md", "a\\b.md", "a\u{0}.md"] {
            assertFailure(.invalidPath) { _ = try self.store.publish(Data(), at: RelativePath(invalid), expecting: .absent, mode: .normal) }
        }
    }

    func testManagedDirectoriesAreExclusiveAndIncarnationsSurviveChildrenAndRename() throws {
        try store.createDirectory(at: "Groups/Team")
        try store.createDirectory(at: ".hidden")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("Groups"))
        XCTAssertEqual(try store.directories(at: nil).map(\.string), [".hidden", "Groups"])
        let identity = try XCTUnwrap(store.directoryIdentity(at: "Groups/Team"))
        try store.write(Data("child".utf8), at: "Groups/Team/a.md")
        XCTAssertEqual(try store.directoryIdentity(at: "Groups/Team"), identity)
        assertFailure(.occupied) { try self.store.createDirectory(at: "Groups/Team") }
        assertFailure(.occupied) { try self.store.removeEmptyDirectory(at: "Groups/Team", expecting: identity) }
        assertFailure(.changed) { try self.store.removeEmptyDirectory(at: "Groups/Team", expecting: FileStamp("wrong")) }
        try store.createDirectory(at: "Groups/Other")
        assertFailure(.occupied) { try self.store.renameDirectory(from: "Groups/Team", to: "Groups/Other") }
        assertFailure(.notFound) { try self.store.renameDirectory(from: "Groups/Team", to: "missing/Team") }
        try store.renameDirectory(from: "Groups/Team", to: "Groups/Renamed")
        XCTAssertEqual(try store.directoryIdentity(at: "Groups/Renamed"), identity)
        try store.delete(at: "Groups/Renamed/a.md")
        try store.removeEmptyDirectory(at: "Groups/Renamed", expecting: identity)
        XCTAssertNil(try store.directoryIdentity(at: "Groups/Renamed"))
        try store.createDirectory(at: "Groups/Renamed")
        XCTAssertNotEqual(try store.directoryIdentity(at: "Groups/Renamed"), identity)
        assertFailure(.invalidPath) { _ = try self.store.directories(at: "alias") }
    }

    func testTrashPreservesBytesModesAndRecoverableMetadataWithoutOverwriting() throws {
        let path: RelativePath = "nested/é #.md"
        let bytes = Data("recoverable".utf8)
        for _ in 0..<2 {
            _ = try store.publish(bytes, at: path, expecting: .absent, mode: .readOnly)
            let stamp = try XCTUnwrap(store.stamp(at: path.string))
            assertFailure(.changed) { try self.store.trash(at: path, expecting: .matching(stamp: FileStamp("old"), bytes: bytes)) }
            try store.trash(at: path, expecting: .matching(stamp: stamp, bytes: bytes))
            XCTAssertNil(try store.stamp(at: path.string))
        }
        let files = try FileManager.default.contentsOfDirectory(at: trash.appendingPathComponent("files"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o444)
            let info = trash.appendingPathComponent("info/" + file.lastPathComponent + ".trashinfo")
            let metadata = try String(contentsOf: info, encoding: .utf8)
            XCTAssertTrue(metadata.hasPrefix("[Trash Info]\nPath=/"))
            XCTAssertTrue(metadata.contains("%C3%A9%20%23.md\nDeletionDate="))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: info.path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testBoundRootWithoutBirthTimeFailsClosedWhileOrdinaryReadsWork() throws {
        // procfs has no birth time; no mutation of this tree is needed.
        let files = try RootedFileStore(root: URL(fileURLWithPath: "/proc", isDirectory: true))
        try files.requireRoot()
        XCTAssertThrowsError(try files.directories(at: nil)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .ioFailure)
        }
        files.bindSyncRoot()
        XCTAssertThrowsError(try files.requireRoot()) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
    }

    func testIndependentStoresCanInitializeTheSameTrashConcurrently() throws {
        for attempt in 0..<16 {
            trash = temporary.appendingPathComponent("missing-\(attempt)/shared-parent/Trash")
            let bytes = Data("recoverable\n".utf8)
            let inputs = try (0..<16).map { index -> (RootedFileStore, FileStamp) in
                let files = try RootedFileStore(root: temporary.appendingPathComponent("library-\(attempt)-\(index)"), trashRoot: trash)
                try files.write(bytes, at: "a.md")
                return (files, try XCTUnwrap(files.stamp(at: "a.md")))
            }
            let lock = NSLock()
            var failures: [SyncFileFailureCode] = []
            DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                let (files, stamp) = inputs[index]
                do { try files.trash(at: "a.md", expecting: .matching(stamp: stamp, bytes: bytes)) }
                catch {
                    lock.lock()
                    failures.append((error as? SyncFileOperationError)?.code ?? .invalidState)
                    lock.unlock()
                }
            }
            XCTAssertTrue(failures.isEmpty, "Shared trash initialization failed: \(failures)")
            let trashed = try FileManager.default.contentsOfDirectory(at: trash.appendingPathComponent("files"), includingPropertiesForKeys: nil)
            XCTAssertEqual(trashed.count, inputs.count)
            for file in trashed { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        }
    }

    func testTrashKeepsPrivateModesUnderOwnerRestrictiveUmasks() throws {
        let bytes = Data("recoverable\n".utf8)
        for mask: mode_t in [0o222, 0o777] {
            let selectedTrash = temporary.appendingPathComponent("Trash-\(mask)")
            let files = try RootedFileStore(root: root, trashRoot: selectedTrash)
            try files.write(bytes, at: "a.md")
            let stamp = try XCTUnwrap(files.stamp(at: "a.md"))
            do {
                let previous = umask(mask)
                defer { _ = umask(previous) }
                try files.trash(at: "a.md", expecting: .matching(stamp: stamp, bytes: bytes))
            }
            XCTAssertNil(try files.stamp(at: "a.md"))
            for directory in [selectedTrash, selectedTrash.appendingPathComponent("files"), selectedTrash.appendingPathComponent("info")] {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
            }
        }
    }

    func testReplacedRootNeverCreatesAFileOrReportsAnEmptyLibrary() throws {
        try store.write(Data("original".utf8), at: "a.md")
        try FileManager.default.moveItem(at: root, to: temporary.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.listFiles()) { XCTAssertEqual($0 as? FileStoreError, .invalidRoot) }
        assertFailure(.invalidPath) { _ = try self.store.publish(Data(), at: "a.md", expecting: .absent, mode: .normal) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func permissions(_ path: RelativePath) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path.string).path)[.posixPermissions] as? Int
    }

    private func assertFailure(_ code: SyncFileFailureCode, _ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, code, file: file, line: line)
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .unchanged, file: file, line: line)
        }
    }
}
#endif
