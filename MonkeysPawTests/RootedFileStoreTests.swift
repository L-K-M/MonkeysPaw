import Foundation
import Darwin
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class RootedFileStoreTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var outside: URL!
    private var store: RootedFileStore!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        outside = directory.appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        store = try RootedFileStore(root: root)
    }

    override func tearDown() { try? manager.removeItem(at: directory) }

    func testMissingRootReadAndListDoNotCreateDirectories() throws {
        XCTAssertTrue(try store.listFiles().isEmpty)
        XCTAssertNil(try store.stamp(at: "nested/a.md"))
        XCTAssertFalse(manager.fileExists(atPath: root.path))
        XCTAssertThrowsError(try store.read(at: "a.md")) {
            XCTAssertEqual($0 as? FileStoreError, .notFound)
        }
        XCTAssertThrowsError(try store.delete(at: "a.md")) {
            XCTAssertEqual($0 as? FileStoreError, .notFound)
        }
    }

    func testSymlinkedAncestorWithMissingTailSupportsFilesButRejectsChildSymlinks() throws {
        let real = directory.appendingPathComponent("real")
        let link = directory.appendingPathComponent("link")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        let bytes = Data("Through resolved root\r\n".utf8)
        let secret = outside.appendingPathComponent("secret.md")
        try Data("Outside".utf8).write(to: secret)

        for tail in ["library", "missing/deep/library"] {
            let libraryURL = link.appendingPathComponent(tail)
            let resolvedRoot = real.appendingPathComponent(tail)
            let linkedStore = try RootedFileStore(root: libraryURL)
            XCTAssertTrue(try linkedStore.listFiles().isEmpty)
            XCTAssertNil(try linkedStore.stamp(at: "nested/a.md"))
            XCTAssertFalse(manager.fileExists(atPath: resolvedRoot.path))

            try linkedStore.write(bytes, at: "nested/a.md")
            XCTAssertEqual(try Data(contentsOf: resolvedRoot.appendingPathComponent("nested/a.md")), bytes)
            XCTAssertEqual(try linkedStore.read(at: "nested/a.md"), bytes)
            let stamp = try XCTUnwrap(linkedStore.stamp(at: "nested/a.md"))
            XCTAssertEqual(try linkedStore.listFiles(), [StoredFile(relativePath: "nested/a.md", stamp: stamp)])

            try manager.createSymbolicLink(at: resolvedRoot.appendingPathComponent("internal"),
                                           withDestinationURL: resolvedRoot.appendingPathComponent("nested"))
            try manager.createSymbolicLink(at: resolvedRoot.appendingPathComponent("escape"), withDestinationURL: outside)
            try manager.createSymbolicLink(at: resolvedRoot.appendingPathComponent("alias.md"), withDestinationURL: secret)
            for path in ["internal/a.md", "escape/secret.md", "alias.md"] {
                assertOutsideRoot { _ = try linkedStore.stamp(at: path) }
                assertOutsideRoot { _ = try linkedStore.read(at: path) }
                assertOutsideRoot { try linkedStore.write(Data(), at: path) }
                assertOutsideRoot { try linkedStore.delete(at: path) }
                assertOutsideRoot { try linkedStore.move(from: path, to: "moved.md") }
                assertOutsideRoot { try linkedStore.move(from: "nested/a.md", to: path) }
            }
            XCTAssertEqual(try linkedStore.listFiles(), [StoredFile(relativePath: "nested/a.md", stamp: stamp)])
            XCTAssertEqual(try linkedStore.read(at: "nested/a.md"), bytes)
            XCTAssertEqual(try Data(contentsOf: secret), Data("Outside".utf8))
        }
    }

    func testTwoLevelSymlinkedAncestorWithMissingTailKeepsCanonicalRoot() throws {
        let real = directory.appendingPathComponent("real")
        let innerLink = directory.appendingPathComponent("inner-link")
        let outerLink = directory.appendingPathComponent("outer-link")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: innerLink, withDestinationURL: real)
        try manager.createSymbolicLink(at: outerLink, withDestinationURL: innerLink)
        let resolvedRoot = real.appendingPathComponent("missing/deep/library")
        let linkedStore = try RootedFileStore(root: outerLink.appendingPathComponent("missing/deep/library"))
        XCTAssertTrue(try linkedStore.listFiles().isEmpty)
        XCTAssertFalse(manager.fileExists(atPath: resolvedRoot.path))

        let bytes = Data("Through two links\r\n".utf8)
        try linkedStore.write(bytes, at: "nested/a.md")
        XCTAssertEqual(try Data(contentsOf: resolvedRoot.appendingPathComponent("nested/a.md")), bytes)

        try manager.removeItem(at: innerLink)
        try manager.createSymbolicLink(at: innerLink, withDestinationURL: outside)
        XCTAssertEqual(try linkedStore.read(at: "nested/a.md"), bytes)
        try linkedStore.write(bytes, at: "nested/b.md")
        XCTAssertEqual(try Data(contentsOf: resolvedRoot.appendingPathComponent("nested/b.md")), bytes)
        XCTAssertEqual(try linkedStore.listFiles().map(\.relativePath), ["nested/a.md", "nested/b.md"])
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testAtomicReplaceChangesInodeAndLeavesOpenReaderCompleteOldBytes() throws {
        let first = Data(repeating: 0x61, count: 256 * 1024)
        let second = Data("Complete replacement\r\n".utf8)
        try store.write(first, at: "nested/a.md")
        let url = root.appendingPathComponent("nested/a.md")
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let oldNumber = try manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        try store.write(second, at: "nested/a.md")
        XCTAssertEqual(try reader.readToEnd(), first, "An open inode keeps the entire previous file.")
        XCTAssertEqual(try store.read(at: "nested/a.md"), second)
        let newNumber = try manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(oldNumber, newNumber)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["a.md"])
        XCTAssertEqual(try store.listFiles().map(\.relativePath), ["nested/a.md"])
        try store.write(Data(), at: "nested/a.md")
        XCTAssertEqual(try store.read(at: "nested/a.md"), Data())
    }

    func testStampsChangeOnSameByteWritesAndDeleteRecreateWithRestoredMtime() throws {
        let bytes = Data("Same size and bytes".utf8)
        try store.write(bytes, at: "a.md")
        let first = try XCTUnwrap(store.stamp(at: "a.md"))
        XCTAssertEqual(try store.stamp(at: "a.md"), first)
        try store.write(bytes, at: "a.md")
        let replaced = try XCTUnwrap(store.stamp(at: "a.md"))
        XCTAssertNotEqual(first, replaced)
        let url = root.appendingPathComponent("a.md")
        let mtime = try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.modificationDate])
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try store.delete(at: "a.md")
        XCTAssertNil(try store.stamp(at: "a.md"))
        try store.write(bytes, at: "a.md")
        try manager.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        XCTAssertNotEqual(try store.stamp(at: "a.md"), replaced)
        let recreated = try store.stamp(at: "a.md")
        // Let a coarse filesystem timestamp tick before the in-place write.
        Thread.sleep(forTimeInterval: 1.05)
        try Data("Changed same length".utf8).write(to: url)
        try manager.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        XCTAssertNotEqual(try store.stamp(at: "a.md"), recreated, "Change time detects in-place writes too.")
    }

    func testRecursiveListingSkipsAllSymlinksAndNonregularFiles() throws {
        try store.write(Data("A".utf8), at: "nested/a.md")
        try store.write(Data("Z".utf8), at: "z.md")
        try Data("Outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("internal"), withDestinationURL: root.appendingPathComponent("nested"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("file.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        let listed = try store.listFiles()
        XCTAssertEqual(listed.map(\.relativePath), ["nested/a.md", "z.md"])
        XCTAssertEqual(listed[0].stamp, try store.stamp(at: "nested/a.md"))
    }

    func testSymlinkEscapesRejectedByEveryOperationAndOutsideBytesSurvive() throws {
        try store.write(Data("Inside".utf8), at: "a.md")
        let secret = outside.appendingPathComponent("secret.md")
        try Data("Outside".utf8).write(to: secret)
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("alias.md"), withDestinationURL: secret)
        for path in ["escape/secret.md", "alias.md"] {
            assertOutsideRoot { _ = try store.stamp(at: path) }
            assertOutsideRoot { _ = try store.read(at: path) }
            assertOutsideRoot { try store.write(Data("Overwrite".utf8), at: path) }
            assertOutsideRoot { try store.delete(at: path) }
            assertOutsideRoot { try store.move(from: path, to: "moved.md") }
            assertOutsideRoot { try store.move(from: "a.md", to: path) }
        }
        assertOutsideRoot { try store.write(Data(), at: "escape/new/child.md") }
        XCTAssertFalse(manager.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertEqual(try Data(contentsOf: secret), Data("Outside".utf8))
        XCTAssertEqual(try store.read(at: "a.md"), Data("Inside".utf8))
    }

    func testReplacedRootAndRootAncestorCannotRedirectStore() throws {
        try store.write(Data(), at: "a.md")
        try manager.removeItem(at: root)
        try manager.createSymbolicLink(at: root, withDestinationURL: outside)
        assertOutsideRoot { _ = try store.listFiles() }
        assertOutsideRoot { try store.write(Data(), at: "new.md") }
        try manager.removeItem(at: root)
        let parent = directory.appendingPathComponent("parent")
        let nestedStore = try RootedFileStore(root: parent.appendingPathComponent("nested"))
        try nestedStore.write(Data(), at: "a.md")
        try manager.removeItem(at: parent)
        try manager.createSymbolicLink(at: parent, withDestinationURL: outside)
        assertOutsideRoot { _ = try nestedStore.stamp(at: "a.md") }
        assertOutsideRoot { try nestedStore.write(Data(), at: "new.md") }
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testPathsRejectTraversalAbsoluteEmptySegmentsControlsAndByteOverflow() throws {
        try store.write(Data("Original".utf8), at: "a.md")
        let badPaths = ["", "/a.md", ".", "..", "./a.md", "a/../b.md", "a/./b.md", "a//b.md",
                        "a/", "a\\b.md", "a\0.md", "a\r.md", String(repeating: "é", count: 513)]
        for path in badPaths {
            let operations: [() throws -> Void] = [
                { _ = try self.store.stamp(at: path) }, { _ = try self.store.read(at: path) },
                { try self.store.write(Data(), at: path) }, { try self.store.delete(at: path) },
                { try self.store.move(from: "a.md", to: path) },
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? FileStoreError, .invalidPath) }
            }
        }
        XCTAssertEqual(try store.listFiles().map(\.relativePath), ["a.md"])
        let boundary = Array(repeating: "folder", count: 145).joined(separator: "/") + "/" + String(repeating: "x", count: 6) + ".md"
        XCTAssertEqual(boundary.utf8.count, Limits.maxPathBytes)
        // macOS also bounds the absolute OS path; the root adds bytes to this
        // valid relative boundary. Linux exercises the actual deep-tree write.
        try FileStorePath.validate(boundary)
    }

    func testMoveCreatesParentsNeverOverwritesAndDeleteIsExplicit() throws {
        try store.write(Data("A".utf8), at: "a.md")
        try store.write(Data("B".utf8), at: "b.md")
        XCTAssertThrowsError(try store.move(from: "a.md", to: "b.md")) {
            XCTAssertEqual($0 as? FileStoreError, .alreadyExists)
        }
        XCTAssertEqual(try store.read(at: "a.md"), Data("A".utf8))
        XCTAssertEqual(try store.read(at: "b.md"), Data("B".utf8))
        try store.move(from: "a.md", to: "nested/moved.md")
        XCTAssertNil(try store.stamp(at: "a.md"))
        XCTAssertEqual(try store.read(at: "nested/moved.md"), Data("A".utf8))
        try store.delete(at: "nested/moved.md")
        XCTAssertThrowsError(try store.delete(at: "nested/moved.md")) {
            XCTAssertEqual($0 as? FileStoreError, .notFound)
        }
    }

    func testDirectoriesAndFIFOsAreNeverReadOrReplacedAndErrorsAreSanitized() throws {
        try manager.createDirectory(at: root.appendingPathComponent("dir.md"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        for path in ["dir.md", "pipe.md"] {
            XCTAssertThrowsError(try store.read(at: path)) { XCTAssertEqual($0 as? FileStoreError, .notRegularFile) }
            XCTAssertThrowsError(try store.write(Data(), at: path)) { XCTAssertEqual($0 as? FileStoreError, .notRegularFile) }
            XCTAssertThrowsError(try store.delete(at: path)) { XCTAssertEqual($0 as? FileStoreError, .notRegularFile) }
        }
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: root.path)), ["dir.md", "pipe.md"])
        let marker = "sensitive-marker"
        try store.write(Data(), at: marker)
        XCTAssertThrowsError(try store.write(Data(), at: marker + "/child.md")) {
            XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
            XCTAssertFalse(String(describing: $0).contains(marker))
            XCTAssertFalse(String(describing: $0).contains(self.directory.path))
            XCTAssertFalse($0.localizedDescription.contains(marker))
            XCTAssertFalse($0.localizedDescription.contains(self.directory.path))
        }
    }

    func testLibraryLifecycleThroughRealStores() throws {
        let dataStore = try RootedFileStore(root: directory.appendingPathComponent("data"))
        let library = LibraryService(library: store, data: dataStore, clock: SystemClock(), entropy: SystemEntropy())
        let body = "  Raw body\r\n\r\n"
        try store.write(Data(body.utf8), at: "folder/a.md")
        let local = try XCTUnwrap(library.entries().first)
        let assigned = try library.assignIdentity(to: local.relativePath)
        let id = try XCTUnwrap(assigned.document.frontMatter.id)
        let edited = try library.save(PromptCodec.parse("Edited", filename: "a.md"), at: local.relativePath,
                                      expectedStamp: assigned.stamp)
        XCTAssertEqual(edited.identity, assigned.identity)
        let revisions = try library.history(for: assigned.identity)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(try dataStore.read(at: "history/" + id.rawValue + "/" + revisions[1].filename), Data(body.utf8))
        let moved = try library.move(from: local.relativePath, to: "moved.md")
        XCTAssertEqual(moved.identity, assigned.identity)
        let restored = try library.restore(revisions[1], at: "moved.md")
        XCTAssertEqual(restored.document.body, body)
        XCTAssertEqual(try library.history(for: assigned.identity).count, 3)
        try library.delete(at: "moved.md")
        XCTAssertEqual(try library.history(for: assigned.identity).count, 3)
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertEqual(try library.restore(revisions[1], at: "moved.md").identity, assigned.identity)
    }

    private func assertOutsideRoot(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot, file: file, line: line)
        }
    }

    func testInitializationErrorsDoNotExposeOSPaths() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory search permissions.") }
        let blocked = directory.appendingPathComponent("sensitive-parent")
        let child = blocked.appendingPathComponent("child")
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        XCTAssertThrowsError(try RootedFileStore(root: child)) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            XCTAssertFalse(String(describing: $0).contains("sensitive-parent"))
            XCTAssertFalse($0.localizedDescription.contains("sensitive-parent"))
            XCTAssertFalse(String(describing: $0).contains(self.directory.path))
            XCTAssertFalse($0.localizedDescription.contains(self.directory.path))
        }
    }
}
