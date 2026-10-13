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
    }

    func testMixedSelectionsClassifyDirectoriesWithoutFollowingLinkedSelections() throws {
        let file = try put("folder/file.md")
        let folder = file.deletingLastPathComponent()
        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        let reader = MacImportSourceReader()
        XCTAssertEqual(reader.requests(for: [file, folder, linked]), [.files([file.path, linked.path]), .folder(folder.path)])
    }
}
