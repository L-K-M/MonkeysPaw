import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncStateFileOperationsTests: XCTestCase {
    private let fileErrors: [(FileStoreError, SyncFileFailureCode)] = [
        (.invalidPath, .invalidPath), (.outsideRoot, .invalidPath), (.invalidRoot, .invalidPath),
        (.notRegularFile, .invalidPath), (.notFound, .notFound), (.alreadyExists, .occupied), (.ioFailure, .ioFailure)
    ]

    func testReadFailuresUsePortErrorCodes() throws {
        for (underlying, code) in fileErrors {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            try files.put("bytes", at: "File.md")
            files.onRead = { _ in throw underlying }
            assertFailure(code) { try operations.flushFile(at: "File.md") }
            assertFailure(code) { try operations.setMode(.readOnly, at: "File.md") }
            XCTAssertTrue(operations.modes.isEmpty)
            XCTAssertEqual(operations.flushCount, 0)
        }
    }

    func testStampFailuresUsePortErrorCodes() throws {
        for (underlying, code) in fileErrors {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            try operations.createDirectory(at: "Source")
            files.onStamp = { _, _ in throw underlying }
            assertFailure(code) { _ = try operations.publish(Data(), at: "File.md", expecting: .absent, mode: .normal) }
            assertFailure(code) { try operations.trash(at: "File.md", expecting: .absent) }
            assertFailure(code) { try operations.createDirectory(at: "New") }
            assertFailure(code) { try operations.renameDirectory(from: "Source", to: "Destination") }
            XCTAssertEqual(try operations.directories(at: nil), [RelativePath("Source")])
        }
    }

    func testInvalidPathsUsePortErrorCodeOnEveryOperation() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let invalid = RelativePath("../escape")
        assertFailure(.invalidPath) { _ = try operations.publish(Data(), at: invalid, expecting: .absent, mode: .normal) }
        assertFailure(.invalidPath) { try operations.flushFile(at: invalid) }
        assertFailure(.invalidPath) { try operations.flushDirectory(at: invalid) }
        assertFailure(.invalidPath) { try operations.setMode(.readOnly, at: invalid) }
        assertFailure(.invalidPath) { try operations.trash(at: invalid, expecting: .absent) }
        assertFailure(.invalidPath) { try operations.createDirectory(at: invalid) }
        assertFailure(.invalidPath) { try operations.renameDirectory(from: invalid, to: "Destination") }
        assertFailure(.invalidPath) { try operations.renameDirectory(from: "Source", to: invalid) }
        assertFailure(.invalidPath) { _ = try operations.directories(at: invalid) }
        XCTAssertTrue(try files.listFiles().isEmpty)
        XCTAssertTrue(try operations.directories(at: nil).isEmpty)
    }

    func testMissingFilesUsePortErrorCodeWithoutChangingMode() throws {
        let operations = MemorySyncFileOperations(files: MemoryFileStore())
        assertFailure(.notFound) { try operations.flushFile(at: "Missing.md") }
        assertFailure(.notFound) { try operations.setMode(.readOnly, at: "Missing.md") }
        XCTAssertTrue(operations.modes.isEmpty)
    }

    func testFailedWriteUsesPortErrorCodeAndPreservesBytes() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let bytes = Data("original".utf8)
        try files.write(bytes, at: "File.md")
        let stamp = try XCTUnwrap(files.stamp(at: "File.md"))
        files.failNextWrite = true
        assertFailure(.ioFailure) {
            _ = try operations.publish(Data("replacement".utf8), at: "File.md",
                expecting: .matching(stamp: stamp, bytes: bytes), mode: .readOnly)
        }
        XCTAssertEqual(try files.read(at: "File.md"), bytes)
        XCTAssertTrue(operations.modes.isEmpty)
    }

    func testFailedDeleteAndMoveUsePortErrorCodes() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let bytes = Data("original".utf8)
        try files.write(bytes, at: "Source/File.md")
        let stamp = try XCTUnwrap(files.stamp(at: "Source/File.md"))
        files.failNextDelete = true
        assertFailure(.ioFailure) { try operations.trash(at: "Source/File.md", expecting: .matching(stamp: stamp, bytes: bytes)) }
        XCTAssertNil(operations.trashed["Source/File.md"])
        files.failMoveNumber = 1
        assertFailure(.ioFailure) { try operations.renameDirectory(from: "Source", to: "Destination") }
        XCTAssertEqual(try files.read(at: "Source/File.md"), bytes)
        XCTAssertNil(try files.stamp(at: "Destination/File.md"))
    }

    func testFailedDirectoryRenameReportsAppliedAfterMovingAFile() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        try files.put("first", at: "Source/Z.md")
        try files.put("second", at: "Source/A.md")
        files.failMoveNumber = 2
        XCTAssertThrowsError(try operations.renameDirectory(from: "Source", to: "Destination")) {
            let error = $0 as? SyncFileOperationError
            XCTAssertEqual(error?.code, .ioFailure)
            XCTAssertEqual(error?.effect, .applied)
        }
        XCTAssertEqual(try files.text(at: "Destination/Z.md"), "first")
        XCTAssertEqual(try files.text(at: "Source/A.md"), "second")
    }

    func testDirectoryRenameRequiresExistingDestinationParent() throws {
        for hasFile in [false, true] {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            try operations.createDirectory(at: "Groups/Source")
            if hasFile { try files.put("original", at: "Groups/Source/File.md") }
            assertFailure(.notFound) { try operations.renameDirectory(from: "Groups/Source", to: "Missing/Destination") }
            XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Source")])
            XCTAssertEqual(try operations.directories(at: nil), [RelativePath("Groups")])
            if hasFile { XCTAssertEqual(try files.text(at: "Groups/Source/File.md"), "original") }
            XCTAssertNil(try files.stamp(at: "Missing/Destination/File.md"))
        }
    }

    func testDirectoryRenameRejectsOwnSubtreeWithoutMutation() throws {
        for hasFile in [false, true] {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            try operations.createDirectory(at: "Source")
            if hasFile { try files.put("original", at: "Source/File.md") }
            let flushCount = operations.flushCount
            assertFailure(.invalidPath) { try operations.renameDirectory(from: "Source", to: "Source/Child") }
            XCTAssertEqual(try operations.directories(at: nil), [RelativePath("Source")])
            XCTAssertTrue(try operations.directories(at: "Source").isEmpty)
            XCTAssertEqual(files.moveCount, 0)
            XCTAssertEqual(operations.flushCount, flushCount)
            if hasFile { XCTAssertEqual(try files.text(at: "Source/File.md"), "original") }
            XCTAssertNil(try files.stamp(at: "Source/Child/File.md"))
        }
    }

    func testPublicationCreatesParentsAndFlushesEveryAffectedDirectory() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let path = RelativePath("Missing/Nested/File.md")
        let bytes = Data("complete bytes".utf8)
        let publication = try operations.publish(bytes, at: path, expecting: .absent, mode: .normal)
        XCTAssertNil(publication.displacedBytes)
        XCTAssertEqual(try files.read(at: path.string), bytes)
        XCTAssertEqual(operations.flushedFiles, [path])
        XCTAssertEqual(operations.flushedDirectories, [RelativePath("Missing/Nested"), "Missing", nil])
        XCTAssertEqual(try operations.directories(at: nil), [RelativePath("Missing")])
        XCTAssertEqual(try operations.directories(at: "Missing"), [RelativePath("Missing/Nested")])
    }

    func testNewParentFlushFailuresReportAppliedPublication() throws {
        for failure in 2...4 {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            operations.failFlushNumber = failure
            let bytes = Data("complete bytes".utf8)
            XCTAssertThrowsError(try operations.publish(bytes, at: "Missing/Nested/File.md", expecting: .absent, mode: .normal)) {
                let error = $0 as? SyncFileOperationError
                XCTAssertEqual(error?.code, .durabilityFailed)
                XCTAssertEqual(error?.effect, .applied)
                XCTAssertNil(error?.displacedBytes)
            }
            XCTAssertEqual(try files.read(at: "Missing/Nested/File.md"), bytes)
        }
    }

    private func assertFailure(_ code: SyncFileFailureCode, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            let error = $0 as? SyncFileOperationError
            XCTAssertEqual(error?.code, code, file: file, line: line)
            XCTAssertEqual(error?.effect, .unchanged, file: file, line: line)
            XCTAssertNil(error?.displacedBytes, file: file, line: line)
        }
    }
}
