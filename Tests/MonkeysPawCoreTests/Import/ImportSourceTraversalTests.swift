import Foundation
import XCTest
@testable import MonkeysPawCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ImportSourceTraversalTests: XCTestCase {
    func testSymlinkedAncestorOfSelectionIsAllowedButLinksInsideAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let selected = actual.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: selected.appendingPathComponent("inside.md"))
        try FileManager.default.createSymbolicLink(atPath: selected.appendingPathComponent("linked.md").path,
                                                  withDestinationPath: "inside.md")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: actual.path)
        let selection = alias.appendingPathComponent("selected")
        let reader = try TestImportFileReader(selectedRoot: selection)
        let entries = try reader.listFiles(in: selection.path)
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["inside.md", "linked.md"])
        XCTAssertEqual(entries.first { $0.relativePath == "linked.md" }?.kind, .symbolicLink)
        XCTAssertEqual(try reader.readFile(at: selection.appendingPathComponent("inside.md").path, maximumBytes: 10), Data("inside".utf8))
        XCTAssertThrowsError(try reader.readFile(at: selection.appendingPathComponent("linked.md").path, maximumBytes: 10)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }
        XCTAssertThrowsError(try TestImportFileReader(selectedRoot: alias)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }
    }

    func testSelectedFolderDoesNotFollowLinkedFilesDirectoriesOrAncestors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        let nested = selected.appendingPathComponent("nested")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: nested.appendingPathComponent("inside.md"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(atPath: selected.appendingPathComponent("linked-folder").path,
                                                  withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: selected.appendingPathComponent("linked.md").path,
                                                  withDestinationPath: outside.appendingPathComponent("secret.md").path)
        let sources = try TestImportFileReader(selectedRoot: selected)
        let entries = try sources.listFiles(in: selected.path)
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["nested/inside.md", "linked-folder", "linked.md"])
        XCTAssertEqual(entries.filter { $0.kind == .symbolicLink }.count, 2)
        XCTAssertFalse(entries.contains { $0.relativePath.contains("secret") })
        for path in [selected.appendingPathComponent("linked.md").path,
                     selected.appendingPathComponent("linked-folder/secret.md").path,
                     selected.appendingPathComponent("linked-folder/\u{301}secret.md").path] {
            XCTAssertThrowsError(try sources.readFile(at: path, maximumBytes: Limits.importFileCapBytes)) {
                XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
            }
        }
        XCTAssertThrowsError(try sources.listFiles(in: selected.appendingPathComponent("linked-folder").path)) {
            XCTAssertEqual($0 as? ImportSourceError, .symbolicLink)
        }

        let graph = ImportTestGraph()
        let service = ImportService(library: graph.library, sources: sources, work: graph.work, main: ImportInlineMain())
        var report: ImportReport?
        service.import(.folder(selected.path)) { report = $0 }
        graph.work.drain()
        XCTAssertEqual(report?.createdCount, 1)
        XCTAssertEqual(report?.skippedCount, 2)
        XCTAssertEqual(try graph.files.text(at: "Imported/nested/inside.md"), "inside")
        XCTAssertTrue(sources.readPaths.allSatisfy { !$0.contains("linked") && !$0.contains("outside") })
    }

    func testReaderCapsTheBytesRatherThanTrustingOnlyStatSize() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 65, count: Limits.importFileCapBytes + 5).write(to: file)
        let reader = try TestImportFileReader(selectedRoot: file.deletingLastPathComponent())
        XCTAssertThrowsError(try reader.readFile(at: file.path, maximumBytes: Limits.importFileCapBytes)) {
            XCTAssertEqual($0 as? ImportSourceError, .fileTooLarge)
        }
        XCTAssertEqual(reader.lastReadBytes, Limits.importFileCapBytes + 1)
    }
}

/// Test-only adapter exercises the source port's required traversal/read
/// contract against real files. Production drivers remain in native slices.
private final class TestImportFileReader: ImportSourceReading {
    private let selectedRoot: String
    private let canonicalRoot: String
    private(set) var readPaths: [String] = []
    private(set) var lastReadBytes = 0

    init(selectedRoot: URL) throws {
        let type = try FileManager.default.attributesOfItem(atPath: selectedRoot.path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw ImportSourceError.symbolicLink }
        guard type == .typeDirectory else { throw ImportSourceError.notRegularFile }
        guard let resolved = realpath(selectedRoot.path, nil) else { throw ImportSourceError.ioFailure }
        defer { free(resolved) }
        self.selectedRoot = selectedRoot.path
        canonicalRoot = String(cString: resolved)
    }

    func listFiles(in folderPath: String) throws -> [ImportSourceEntry] {
        let folder = try checkedPath(folderPath)
        var entries: [ImportSourceEntry] = []
        func visit(_ absolute: String, relative: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: absolute) {
                let path = absolute + "/" + name
                let relativePath = relative.isEmpty ? name : relative + "/" + name
                let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
                switch type {
                case .typeDirectory: try visit(path, relative: relativePath)
                case .typeSymbolicLink: entries.append(ImportSourceEntry(relativePath: relativePath, kind: .symbolicLink))
                case .typeRegular: entries.append(ImportSourceEntry(relativePath: relativePath))
                default: entries.append(ImportSourceEntry(relativePath: relativePath, kind: .other))
                }
            }
        }
        try visit(folder, relative: "")
        return entries
    }

    func readFile(at path: String, maximumBytes: Int) throws -> Data {
        let checked = try checkedPath(path)
        let type = try FileManager.default.attributesOfItem(atPath: checked)[.type] as? FileAttributeType
        guard type == .typeRegular else { throw ImportSourceError.notRegularFile }
        readPaths.append(path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: checked))
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count <= maximumBytes {
            let next = try handle.read(upToCount: maximumBytes + 1 - bytes.count) ?? Data()
            if next.isEmpty { break }
            bytes.append(next)
        }
        lastReadBytes = bytes.count
        guard bytes.count <= maximumBytes else { throw ImportSourceError.fileTooLarge }
        return bytes
    }

    private func checkedPath(_ path: String) throws -> String {
        let relative: String
        if path.utf8.elementsEqual(selectedRoot.utf8) || path.utf8.elementsEqual(canonicalRoot.utf8) {
            relative = ""
        } else if let root = [selectedRoot, canonicalRoot].first(where: {
            path.utf8.starts(with: ($0 + ($0 == "/" ? "" : "/")).utf8)
        }) {
            let prefixCount = root.utf8.count + (root == "/" ? 0 : 1)
            relative = String(decoding: path.utf8.dropFirst(prefixCount), as: UTF8.self)
            guard FileStorePath.isValid(relative, mode: .relative) else { throw ImportSourceError.invalidPath }
        } else { throw ImportSourceError.invalidPath }

        // Only the selected root's ancestors were resolved. Walk its remaining
        // components without resolving an in-tree link or following its target.
        var prefix = canonicalRoot
        let rootType = try FileManager.default.attributesOfItem(atPath: prefix)[.type] as? FileAttributeType
        if rootType == .typeSymbolicLink { throw ImportSourceError.symbolicLink }
        for component in relative.unicodeScalars.split(separator: "/") {
            prefix += (prefix == "/" ? "" : "/") + String(String.UnicodeScalarView(component))
            let type = try FileManager.default.attributesOfItem(atPath: prefix)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw ImportSourceError.symbolicLink }
        }
        return prefix
    }
}
