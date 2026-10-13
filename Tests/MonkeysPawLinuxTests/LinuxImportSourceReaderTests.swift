#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxImportSourceReaderTests: XCTestCase {
    func testEnumeratesRelativePathsWithoutFollowingLinksOrSpecialFiles() throws {
        let tools = try FakeLinuxTools()
        let sources = tools.directory.appendingPathComponent("Sources")
        let files = try RootedFileStore(root: sources)
        try files.write(Data("Alpha".utf8), at: "a.md")
        try files.write(Data("Beta".utf8), at: "nested/b.prompt")
        let outside = tools.directory.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("Outside".utf8).write(to: outside.appendingPathComponent("outside.md"))
        try FileManager.default.createSymbolicLink(at: sources.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: sources.appendingPathComponent("link.md"), withDestinationURL: outside.appendingPathComponent("outside.md"))
        XCTAssertEqual(mkfifo(sources.appendingPathComponent("pipe.md").path, 0o600), 0)
        let reader = LinuxImportSourceReader()
        let entries = try reader.listFiles(in: sources.path).sorted { $0.relativePath < $1.relativePath }
        XCTAssertEqual(entries, [ImportSourceEntry(relativePath: "a.md"),
            ImportSourceEntry(relativePath: "link.md", kind: .symbolicLink),
            ImportSourceEntry(relativePath: "linked", kind: .symbolicLink),
            ImportSourceEntry(relativePath: "nested/b.prompt"), ImportSourceEntry(relativePath: "pipe.md", kind: .other)])
        XCTAssertEqual(try reader.readFile(at: sources.appendingPathComponent("nested/b.prompt").path, maximumBytes: 4), Data("Beta".utf8))
        assertError(.symbolicLink) { _ = try reader.readFile(at: sources.appendingPathComponent("link.md").path, maximumBytes: 4) }
        assertError(.notRegularFile) { _ = try reader.readFile(at: sources.appendingPathComponent("pipe.md").path, maximumBytes: 4) }
        assertError(.symbolicLink) { _ = try reader.listFiles(in: sources.appendingPathComponent("linked").path) }
    }

    func testRetainedRootAndNoFollowWalkRejectReplacedInteriorButAllowSelectionAncestors() throws {
        let tools = try FakeLinuxTools()
        let sources = tools.directory.appendingPathComponent("Sources")
        let files = try RootedFileStore(root: sources)
        try files.write(Data("Original".utf8), at: "nested/a.md")
        let alias = tools.directory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sources)
        let reader = LinuxImportSourceReader()
        XCTAssertEqual(try reader.readFile(at: alias.appendingPathComponent("nested/a.md").path, maximumBytes: 8), Data("Original".utf8))
        _ = try reader.listFiles(in: sources.path)
        let moved = tools.directory.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: sources, to: moved)
        let outside = tools.directory.appendingPathComponent("Outside")
        let other = try RootedFileStore(root: outside)
        try other.write(Data("Redirected".utf8), at: "nested/a.md")
        try FileManager.default.createSymbolicLink(at: sources, withDestinationURL: outside)
        XCTAssertEqual(try reader.readFile(at: sources.appendingPathComponent("nested/a.md").path, maximumBytes: 8), Data("Original".utf8))
        try FileManager.default.removeItem(at: moved.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(at: moved.appendingPathComponent("nested"), withDestinationURL: outside.appendingPathComponent("nested"))
        assertError(.symbolicLink) { _ = try reader.readFile(at: sources.appendingPathComponent("nested/a.md").path, maximumBytes: 8) }
    }

    func testVanishedEnumerationEntryRemainsForTypedReadSkip() throws {
        let tools = try FakeLinuxTools()
        let files = try RootedFileStore(root: tools.directory)
        try files.write(Data("Gone".utf8), at: "gone.md")
        try files.write(Data("Kept".utf8), at: "kept.md")
        let reader = LinuxImportSourceReader(inspectEntry: { path in
            if path == "gone.md" { try? files.delete(at: path) }
        })
        XCTAssertEqual(Set(try reader.listFiles(in: tools.directory.path).map(\.relativePath)), ["gone.md", "kept.md"])
        assertError(.notFound) { _ = try reader.readFile(at: tools.directory.appendingPathComponent("gone.md").path, maximumBytes: 4) }
        XCTAssertEqual(try reader.readFile(at: tools.directory.appendingPathComponent("kept.md").path, maximumBytes: 4), Data("Kept".utf8))
    }

    func testUnreadableSubdirectoryIsReportedWithoutLosingReadableSiblings() throws {
        let tools = try FakeLinuxTools()
        let files = try RootedFileStore(root: tools.directory)
        try files.write(Data("Blocked".utf8), at: "blocked/nested.md")
        try files.write(Data("Kept".utf8), at: "kept.md")
        for code in [EACCES, EPERM, ENOTDIR] {
            let reader = LinuxImportSourceReader(openDirectory: { parent, name in
                if name == "blocked" { errno = code; return -1 }
                return Glibc.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            })
            let entries = try reader.listFiles(in: tools.directory.path)
            XCTAssertEqual(Set(entries.map(\.relativePath)), ["blocked", "kept.md"])
            XCTAssertTrue(entries.contains(ImportSourceEntry(relativePath: "blocked", kind: .other)))
            XCTAssertEqual(try reader.readFile(at: tools.directory.appendingPathComponent("kept.md").path, maximumBytes: 4), Data("Kept".utf8))
        }
    }

    func testNonUTF8FilenameFailsListingInsteadOfReturningAnUnreportedPartialList() throws {
        let tools = try FakeLinuxTools()
        try Data("Kept".utf8).write(to: tools.directory.appendingPathComponent("kept.md"))
        let rawPath: [CChar] = tools.directory.path.utf8.map { CChar(bitPattern: $0) } + [47, -1, 46, 109, 100, 0]
        let descriptor = rawPath.withUnsafeBufferPointer {
            Glibc.open($0.baseAddress!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        _ = Glibc.close(descriptor)
        defer { rawPath.withUnsafeBufferPointer { _ = Glibc.unlink($0.baseAddress!) } }
        assertError(.invalidPath) { _ = try LinuxImportSourceReader().listFiles(in: tools.directory.path) }
    }

    func testRetainedFolderRejectsEmptyRelativePathsAndDotComponents() throws {
        let tools = try FakeLinuxTools()
        let folder = tools.directory.appendingPathComponent("Folder")
        let files = try RootedFileStore(root: folder)
        try files.write(Data("Inside".utf8), at: "nested/a.md")
        try Data("Outside".utf8).write(to: tools.directory.appendingPathComponent("outside.md"))
        let reader = LinuxImportSourceReader()
        _ = try reader.listFiles(in: folder.path)
        for relative in ["", "/", "../outside.md", "nested/../../outside.md", "./nested/a.md", "nested/.", "nested/.."] {
            assertError(.invalidPath) { _ = try reader.readFile(at: folder.path + "/" + relative, maximumBytes: 8) }
        }
        XCTAssertEqual(try reader.readFile(at: folder.path + "/nested/a.md", maximumBytes: 8), Data("Inside".utf8))
    }

    func testNoFollowWalkRecognizesSlashBeforeCombiningMark() throws {
        let tools = try FakeLinuxTools()
        let root = tools.directory.appendingPathComponent("Sources")
        let parent = root.appendingPathComponent("ordinary")
        let directory = parent.appendingPathComponent("\u{301}nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("a.md")
        try Data("Original".utf8).write(to: url)
        let reader = LinuxImportSourceReader()
        XCTAssertEqual(try reader.readFile(at: url.path, maximumBytes: 8), Data("Original".utf8))
        _ = try reader.listFiles(in: root.path)
        XCTAssertEqual(try reader.readFile(at: url.path, maximumBytes: 8), Data("Original".utf8))
        let outside = tools.directory.appendingPathComponent("Outside")
        let redirected = outside.appendingPathComponent("\u{301}nested")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try Data("Escaped".utf8).write(to: redirected.appendingPathComponent("a.md"))
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        assertError(.symbolicLink) { _ = try reader.readFile(at: url.path, maximumBytes: 8) }
    }

    func testCapsReadsAndRejectsInvalidAbsolutePathsBeforeAccess() throws {
        let tools = try FakeLinuxTools()
        let file = tools.directory.appendingPathComponent("a.md")
        try Data("1234".utf8).write(to: file)
        let reader = LinuxImportSourceReader()
        XCTAssertEqual(try reader.readFile(at: file.path, maximumBytes: 4), Data("1234".utf8))
        assertError(.fileTooLarge) { _ = try reader.readFile(at: file.path, maximumBytes: 3) }
        assertError(.fileTooLarge) { _ = try reader.readFile(at: file.path, maximumBytes: 0) }
        try Data(repeating: 65, count: Limits.importFileCapBytes + 1).write(to: file)
        assertError(.fileTooLarge) { _ = try reader.readFile(at: file.path, maximumBytes: Int.max) }
        for path in ["relative.md", "/tmp/../a.md", "/tmp//a.md", "/tmp/a\\b.md", "/tmp/a\n.md", "/tmp/a.md/"] {
            assertError(.invalidPath) { _ = try reader.readFile(at: path, maximumBytes: 1) }
            assertError(.invalidPath) { _ = try reader.listFiles(in: path) }
        }
        assertError(.notRegularFile) { _ = try reader.readFile(at: "/", maximumBytes: 1) }
    }

    func testTraversalBoundsDepthWithCorePathLimit() throws {
        let tools = try FakeLinuxTools()
        let deep = tools.directory.appendingPathComponent("Deep")
        var directory = deep
        while directory.path.utf8.count - deep.path.utf8.count <= Limits.maxPathBytes {
            directory.appendPathComponent(String(repeating: "a", count: 128))
        }
        try XCTSkipIf(directory.path.utf8.count >= Int(PATH_MAX),
                      "The overlong Core path fixture exceeds this host's absolute path limit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Sibling".utf8).write(to: deep.appendingPathComponent("valid.md"))
        let reader = LinuxImportSourceReader()
        let entries = try reader.listFiles(in: deep.path)
        XCTAssertTrue(entries.contains(ImportSourceEntry(relativePath: "valid.md")))
        // Only directories occupy the deepest levels; the pruned node must remain reportable.
        XCTAssertTrue(entries.contains { $0.relativePath.utf8.count > Limits.maxPathBytes })
    }

    func testAggregateListingCountsRelativeNamesWithCoreByteLimit() throws {
        let tools = try FakeLinuxTools()
        let wide = tools.directory.appendingPathComponent("Wide")
        let prefix = Array(repeating: String(repeating: "d", count: 240), count: 3).joined(separator: "/")
        let directory = wide.appendingPathComponent(prefix, isDirectory: true)
        let relativeBytes = prefix.utf8.count + 1 + 250
        XCTAssertLessThanOrEqual(relativeBytes, Limits.maxPathBytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileCount = Limits.importFileCapBytes / relativeBytes + 1
        XCTAssertGreaterThan(fileCount * relativeBytes, Limits.importFileCapBytes)
        XCTAssertLessThanOrEqual(fileCount, 10_000, "Four decimal digits keep each filename at 250 bytes")
        for index in 0..<fileCount {
            let name = String(repeating: "x", count: 246) + String(format: "%04d", index)
            try Data().write(to: directory.appendingPathComponent(name))
        }
        assertError(.fileTooLarge) { _ = try LinuxImportSourceReader().listFiles(in: wide.path) }
    }

    private func assertError(_ expected: ImportSourceError, _ work: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual($0 as? ImportSourceError, expected, file: file, line: line)
        }
    }
}
#endif
