import Darwin
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacImportSourceReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func put(_ name: String, bytes: Data = Data("Inside".utf8)) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        return file
    }

    func testCanonicalSelectionAncestorsAndLinkedLeaves() throws {
        let inside = try put("actual/selected/nested/inside.md")
        let selected = directory.appendingPathComponent("actual/selected")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory.appendingPathComponent("actual"))
        let linkedFile = selected.appendingPathComponent("linked.md")
        let linkedFolder = selected.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: inside)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: inside.deletingLastPathComponent())
        let reader = MacImportSourceReader()
        let selection = alias.appendingPathComponent("selected")
        let entries = try reader.listFiles(in: selection.path)
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["nested/inside.md", "linked.md", "linked-folder"])
        XCTAssertEqual(entries.filter { $0.kind == .symbolicLink }.count, 2)
        XCTAssertEqual(try reader.readFile(at: selection.appendingPathComponent("nested/inside.md").path, maximumBytes: 6), Data("Inside".utf8))
        for path in [selection.appendingPathComponent("linked.md").path,
                     selection.appendingPathComponent("linked-folder/inside.md").path] {
            XCTAssertThrowsError(try reader.readFile(at: path, maximumBytes: 20)) {
                XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
            }
        }
        XCTAssertThrowsError(try reader.listFiles(in: alias.path)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }
        let individual = MacImportSourceReader()
        XCTAssertEqual(try individual.readFile(at: selection.appendingPathComponent("nested/inside.md").path, maximumBytes: 6), Data("Inside".utf8))
        XCTAssertThrowsError(try individual.readFile(at: linkedFile.path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }
    }

    func testEnumerationAnchorRefusesReplacedInteriorAncestorAndRetainsSelectedRoot() throws {
        let inside = try put("selected/nested/inside.md")
        let outside = try put("outside/inside.md", bytes: Data("Outside".utf8))
        let selected = directory.appendingPathComponent("selected")
        let reader = MacImportSourceReader()
        _ = try reader.listFiles(in: selected.path)
        try FileManager.default.moveItem(at: inside.deletingLastPathComponent(), to: selected.appendingPathComponent("saved"))
        try FileManager.default.createSymbolicLink(at: inside.deletingLastPathComponent(), withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertThrowsError(try reader.readFile(at: inside.path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }
        try FileManager.default.moveItem(at: selected, to: directory.appendingPathComponent("old-selection"))
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertEqual(try reader.readFile(at: selected.appendingPathComponent("saved/inside.md").path, maximumBytes: 20), Data("Inside".utf8))
    }

    func testBoundedReadsAndNonregularSources() throws {
        let exact = try put("exact.md", bytes: Data(repeating: 65, count: Limits.importFileCapBytes))
        let oversized = try put("large.md", bytes: Data(repeating: 65, count: Limits.importFileCapBytes + 1))
        let empty = try put("empty.md", bytes: Data())
        let reader = MacImportSourceReader()
        XCTAssertEqual(try reader.readFile(at: exact.path, maximumBytes: Limits.importFileCapBytes).count, Limits.importFileCapBytes)
        XCTAssertEqual(try reader.readFile(at: empty.path, maximumBytes: 0), Data())
        XCTAssertThrowsError(try reader.readFile(at: oversized.path, maximumBytes: Limits.importFileCapBytes)) {
            XCTAssertEqual($0 as? ImportSourceError, .fileTooLarge)
        }
        XCTAssertThrowsError(try reader.readFile(at: directory.path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .notRegularFile)
        }
        let fifo = directory.appendingPathComponent("pipe.md")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try reader.readFile(at: fifo.path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .notRegularFile)
        }
        XCTAssertEqual(try reader.listFiles(in: directory.path).first { $0.relativePath == "pipe.md" }?.kind, .other)
        XCTAssertThrowsError(try reader.listFiles(in: exact.path)) {
            XCTAssertEqual($0 as? ImportSourceError, .notRegularFile)
        }
        XCTAssertThrowsError(try reader.readFile(at: directory.appendingPathComponent("missing.md").path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .notFound)
        }
        XCTAssertThrowsError(try reader.readFile(at: directory.path, maximumBytes: 20)) {
            XCTAssertEqual($0 as? ImportSourceError, .notRegularFile)
        }
    }

    func testVanishedEntryIsReportedWithoutLosingReadableFiles() throws {
        let gone = try put("selected/gone.md")
        _ = try put("selected/kept.md")
        let reader = MacImportSourceReader(willInspectEntry: { path in
            if path == "gone.md" { try? FileManager.default.removeItem(at: gone) }
        })
        let report = try importFolder(directory.appendingPathComponent("selected"), reader: reader)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.files.first { $0.sourcePath.hasSuffix("gone.md") }?.outcome, .skipped(.source(.notFound)))
        XCTAssertEqual(report.files.first { $0.sourcePath.hasSuffix("kept.md") }?.outcome, .created(path: "Imported/kept.md"))
    }

    func testUnreadableSubdirectoryIsReportedWithoutLosingReadableFiles() throws {
        guard Darwin.geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions") }
        _ = try put("selected/kept.md")
        _ = try put("selected/blocked/hidden.md")
        let blocked = directory.appendingPathComponent("selected/blocked")
        XCTAssertEqual(Darwin.chmod(blocked.path, 0), 0)
        defer { _ = Darwin.chmod(blocked.path, 0o700) }
        let report = try importFolder(directory.appendingPathComponent("selected"), reader: MacImportSourceReader())
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.files.first { $0.sourcePath.hasSuffix("blocked") }?.outcome, .skipped(.notRegularFile))
    }

    func testEnumerationHasABoundedPathByteBudget() throws {
        let selected = directory.appendingPathComponent("selected")
        let stem = String(repeating: "a", count: Limits.promptFilenameMaxBytes - 8)
        var pathBytes = 0
        var index = 0
        while pathBytes <= Limits.importFileCapBytes {
            let name = stem + String(index) + ".md"
            _ = try put("selected/" + name, bytes: Data())
            pathBytes += name.utf8.count + 1
            index += 1
        }
        let report = try importFolder(selected, reader: MacImportSourceReader())
        XCTAssertEqual(report.failure, .source(.ioFailure))
        XCTAssertTrue(report.files.isEmpty)
        XCTAssertEqual(report.createdCount, 0)
    }

    func testDeepTreeBelowCoreBoundsStillImports() throws {
        let relative = Array(repeating: "d", count: 128).joined(separator: "/") + "/inside.md"
        _ = try put("selected/" + relative)
        let report = try importFolder(directory.appendingPathComponent("selected"), reader: MacImportSourceReader())
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.files.first?.outcome, .created(path: "Imported/" + relative))
        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(report.skippedCount, 0)
    }

    func testEnumerationBoundsNestedRelativePaths() throws {
        let selected = directory.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let root = Darwin.open(selected.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { XCTFail("Could not open fixture root"); return }
        var descriptors = [root]
        let name = String(repeating: "d", count: Limits.promptFilenameMaxBytes)
        defer {
            for index in (1..<descriptors.count).reversed() {
                _ = Darwin.close(descriptors[index])
                _ = Darwin.unlinkat(descriptors[index - 1], name, AT_REMOVEDIR)
            }
            _ = Darwin.close(root)
        }
        // openat creates a tree whose relative path exceeds the Core cap
        // without relying on the host's absolute-path length limit.
        for _ in 0...Limits.maxPathBytes / Limits.promptFilenameMaxBytes {
            let parent = try XCTUnwrap(descriptors.last)
            XCTAssertEqual(Darwin.mkdirat(parent, name, 0o700), 0)
            let child = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard child >= 0 else {
                _ = Darwin.unlinkat(parent, name, AT_REMOVEDIR)
                XCTFail("Could not open fixture child")
                return
            }
            descriptors.append(child)
        }
        XCTAssertThrowsError(try MacImportSourceReader().listFiles(in: selected.path)) {
            XCTAssertEqual($0 as? ImportSourceError, .invalidPath)
        }
    }

    private func importFolder(_ folder: URL, reader: MacImportSourceReader) throws -> ImportReport {
        let files = try RootedFileStore(root: directory.appendingPathComponent("library"))
        let data = try RootedFileStore(root: directory.appendingPathComponent("data"))
        try files.createRoot()
        try data.createRoot()
        let library = LibraryService(library: files, data: data, clock: SystemClock(), entropy: SystemEntropy())
        let model = ImportModel(service: ImportService(library: library, sources: reader,
            work: MacSourceInlineWork(), main: MacSourceInlineMain()))
        model.importFolder(at: folder.path)
        return try XCTUnwrap(model.state.report)
    }

    func testMixedSelectionsClassifyDirectoriesWithoutFollowingLinkedSelections() throws {
        let file = try put("folder/file.md")
        let folder = file.deletingLastPathComponent()
        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        let reader = MacImportSourceReader()
        XCTAssertEqual(reader.requests(for: [file, folder, linked]), [.files([file.path, linked.path]), .folder(folder.path)])
    }

    func testInvalidAbsolutePathsAreRejectedBeforeFileAccess() {
        let reader = MacImportSourceReader()
        for path in ["relative.md", "/a/../file.md", "/a/./file.md", "/a//file.md", "/a/", "/a/\\file.md", "/a/\u{0}file.md"] {
            XCTAssertThrowsError(try reader.readFile(at: path, maximumBytes: 20)) {
                XCTAssertEqual($0 as? ImportSourceError, .invalidPath)
            }
            XCTAssertThrowsError(try reader.listFiles(in: path)) {
                XCTAssertEqual($0 as? ImportSourceError, .invalidPath)
            }
        }
    }
}

private struct MacSourceInlineWork: BackgroundWork {
    func run(_ work: @escaping () -> Void) { work() }
}

private struct MacSourceInlineMain: MainThread {
    func run(_ work: @escaping () -> Void) { work() }
}
