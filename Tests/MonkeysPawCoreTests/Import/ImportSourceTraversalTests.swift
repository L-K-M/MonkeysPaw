import Foundation
import XCTest
@testable import MonkeysPawCore

final class ImportSourceTraversalTests: XCTestCase {
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
        let sources = TestImportFileReader()
        let entries = try sources.listFiles(in: selected.path)
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["nested/inside.md", "linked-folder", "linked.md"])
        XCTAssertEqual(entries.filter { $0.kind == .symbolicLink }.count, 2)
        XCTAssertFalse(entries.contains { $0.relativePath.contains("secret") })
        for path in [selected.appendingPathComponent("linked.md").path,
                     selected.appendingPathComponent("linked-folder/secret.md").path] {
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
        let reader = TestImportFileReader()
        XCTAssertThrowsError(try reader.readFile(at: file.path, maximumBytes: Limits.importFileCapBytes)) {
            XCTAssertEqual($0 as? ImportSourceError, .fileTooLarge)
        }
        XCTAssertEqual(reader.lastReadBytes, Limits.importFileCapBytes + 1)
    }
}

/// Test-only adapter exercises the source port's required traversal/read
/// contract against real files. Production drivers remain in native slices.
private final class TestImportFileReader: ImportSourceReading {
    private(set) var readPaths: [String] = []
    private(set) var lastReadBytes = 0

    func listFiles(in folderPath: String) throws -> [ImportSourceEntry] {
        try rejectSymlinks(in: folderPath)
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
        try visit(folderPath, relative: "")
        return entries
    }

    func readFile(at path: String, maximumBytes: Int) throws -> Data {
        try rejectSymlinks(in: path)
        let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        guard type == .typeRegular else { throw ImportSourceError.notRegularFile }
        readPaths.append(path)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
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

    private func rejectSymlinks(in path: String) throws {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            let type = try FileManager.default.attributesOfItem(atPath: prefix)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw ImportSourceError.symbolicLink }
        }
    }
}
