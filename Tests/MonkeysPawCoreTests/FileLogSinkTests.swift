import Foundation
import XCTest
@testable import MonkeysPawCore

final class FileLogSinkTests: XCTestCase {
    private let manager = FileManager.default
    private var dataDirectory: URL!
    private let timestamp = "1970-01-01T00:00:00Z"

    override func setUpWithError() throws {
        dataDirectory = manager.temporaryDirectory.appendingPathComponent("mp-log-\(UUID())")
        try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try manager.removeItem(at: dataDirectory)
    }

    func testFormatIsUTCWithLevelAndOneLinePerRecord() throws {
        let sink = makeLog()
        sink.write(.debug, "stage started")
        sink.write(.info, "loaded 3 prompts")
        sink.write(.warning, "backend unavailable")
        sink.write(.error, "first\r\nsecond")

        XCTAssertEqual(try contents(), """
        \(timestamp) debug: stage started
        \(timestamp) info: loaded 3 prompts
        \(timestamp) warning: backend unavailable
        \(timestamp) error: first\\r\\nsecond

        """)
    }

    func testCreatesPrivateDirectoryAndFileBelowAMissingDataRoot() throws {
        let root = dataDirectory.appendingPathComponent("missing/data", isDirectory: true)
        let sink = makeLog(directory: root)
        sink.write(.warning, "safe metadata")
        let directory = root.appendingPathComponent("logs")
        let file = directory.appendingPathComponent("monkeyspaw.log")

        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "\(timestamp) warning: safe metadata\n")
    }

    func testFilteredRecordsDoNotCreateLogFiles() {
        let root = dataDirectory.appendingPathComponent("unused")
        let log = CompositeLogSink(sinks: [makeLog(directory: root)])
        log.write(.debug, "stage started")
        log.write(.info, "loaded 3 prompts")
        XCTAssertFalse(manager.fileExists(atPath: root.path))
    }

    func testRecordLandingExactlyAtLimitDoesNotRotate() throws {
        let record = "\(timestamp) warning: boundary\n"
        let before = Data(repeating: 0x78, count: Limits.logFileMaxBytes - record.utf8.count)
        try seed(before)
        makeLog().write(.warning, "boundary")

        XCTAssertEqual(try Data(contentsOf: file()), before + Data(record.utf8))
        XCTAssertEqual(try size(file()), Limits.logFileMaxBytes)
        XCTAssertFalse(manager.fileExists(atPath: file(archive: 1).path))
    }

    func testRecordExceedingLimitByOneByteRotatesBeforeWrite() throws {
        let record = "\(timestamp) warning: boundary\n"
        let before = Data(repeating: 0x78, count: Limits.logFileMaxBytes - record.utf8.count + 1)
        try seed(before)
        makeLog().write(.warning, "boundary")

        XCTAssertEqual(try contents(), record)
        XCTAssertEqual(try Data(contentsOf: file(archive: 1)), before)
        XCTAssertEqual(try permissions(file()), 0o600)
        XCTAssertEqual(try permissions(file(archive: 1)), 0o600)
    }

    func testRetainsActiveAndFourArchivesDroppingTheOldest() throws {
        let sink = makeLog()
        let messageSize = Limits.logFileMaxBytes - "\(timestamp) warning: \n".utf8.count
        // Two more full files than the retention cap demonstrate oldest-first deletion.
        for number in 0..<(Limits.logFileKeep + 2) {
            sink.write(.warning, String(repeating: String(number), count: messageSize))
        }

        let names = try manager.contentsOfDirectory(atPath: dataDirectory.appendingPathComponent("logs").path)
        XCTAssertEqual(Set(names), Set(["monkeyspaw.log"] + (1..<Limits.logFileKeep).map { "monkeyspaw.log.\($0)" }))
        for archive in 0..<Limits.logFileKeep {
            let url = file(archive: archive)
            let expected = String(repeating: String(Limits.logFileKeep + 1 - archive), count: messageSize)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(timestamp) warning: \(expected)\n")
            XCTAssertEqual(try size(url), Limits.logFileMaxBytes)
            XCTAssertEqual(try permissions(url), 0o600)
        }
    }

    func testOversizedASCIIRecordIsMarkedAndFitsExactly() throws {
        makeLog().write(.error, String(repeating: "x", count: Limits.logFileMaxBytes + 1))
        let output = try contents()

        XCTAssertTrue(output.hasPrefix("\(timestamp) error: x"))
        XCTAssertTrue(output.hasSuffix(" [truncated]\n"))
        XCTAssertEqual(output.utf8.count, Limits.logFileMaxBytes)
        XCTAssertEqual(output.filter { $0 == "\n" }.count, 1)
    }

    func testOversizedUnicodeRecordEndsAtAScalarBoundaryAndRotatesNormally() throws {
        let sink = makeLog()
        sink.write(.warning, "earlier record")
        let message = String(repeating: "🐒", count: Limits.logFileMaxBytes / 4 + 1)
        sink.write(.warning, message)
        let output = try contents()
        let header = "\(timestamp) warning: "
        let suffix = " [truncated]\n"
        let budget = Limits.logFileMaxBytes - header.utf8.count - suffix.utf8.count

        XCTAssertEqual(output, header + String(repeating: "🐒", count: budget / 4) + suffix)
        XCTAssertLessThanOrEqual(output.utf8.count, Limits.logFileMaxBytes)
        XCTAssertEqual(try String(contentsOf: file(archive: 1), encoding: .utf8), "\(timestamp) warning: earlier record\n")
    }

    func testConcurrentWritersKeepWholeUniqueLinesAcrossRotation() throws {
        let sink = makeLog()
        let count = 1_500
        let padding = String(repeating: "x", count: 1_024)
        DispatchQueue.concurrentPerform(iterations: count) { number in
            sink.write(.warning, "writer \(number): \(padding)")
        }

        let logs = dataDirectory.appendingPathComponent("logs")
        var lines: [String] = []
        for name in try manager.contentsOfDirectory(atPath: logs.path) {
            let url = logs.appendingPathComponent(name)
            XCTAssertLessThanOrEqual(try size(url), Limits.logFileMaxBytes)
            let output = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(output.hasSuffix("\n"))
            lines += output.split(separator: "\n").map(String.init)
        }
        let expected = Set((0..<count).map { "\(timestamp) warning: writer \($0): \(padding)" })
        XCTAssertEqual(lines.count, count)
        XCTAssertEqual(Set(lines), expected)
    }

    func testNewSinkAppendsToExistingFileAndUsesItsSizeForRotation() throws {
        var first: FileLogSink? = makeLog()
        first?.write(.info, "before restart")
        first = nil
        let restarted = makeLog()
        restarted.write(.error, "after restart")
        let previous = try Data(contentsOf: file())
        XCTAssertEqual(String(decoding: previous, as: UTF8.self), "\(timestamp) info: before restart\n\(timestamp) error: after restart\n")

        restarted.write(.error, String(repeating: "x", count: Limits.logFileMaxBytes))
        XCTAssertEqual(try Data(contentsOf: file(archive: 1)), previous)
    }

    func testUnwritableDirectoryReportsOnceAndOtherSinksKeepReceivingRecords() throws {
        let blocked = dataDirectory.appendingPathComponent("private-location", isDirectory: true)
        try manager.createDirectory(at: blocked, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        guard !manager.isWritableFile(atPath: blocked.path) else { throw XCTSkip("Host bypasses write permissions") }

        let pipe = Pipe()
        let recorder = FileFailureLogRecorder()
        let sink = makeLog(directory: blocked, failureLog: StandardErrorLog(output: pipe.fileHandleForWriting))
        let log = CompositeLogSink(sinks: [sink, recorder])
        DispatchQueue.concurrentPerform(iterations: 100) { _ in log.write(.warning, "safe metadata") }
        log.write(.error, "save failed")
        try pipe.fileHandleForWriting.close()

        let notice = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
        XCTAssertEqual(String(decoding: notice, as: UTF8.self), "monkeyspaw warning: File logging unavailable; continuing with other log sinks\n")
        XCTAssertEqual(recorder.messages.count, 101)
        XCTAssertEqual(recorder.messages.last, "save failed")
        XCTAssertFalse(manager.fileExists(atPath: blocked.appendingPathComponent("logs").path))
    }

    func testUnwritableFilePreservesExistingBytesAndReportsOnce() throws {
        let original = Data("previous diagnostics\n".utf8)
        try seed(original)
        try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file().path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file().path) }
        guard !manager.isWritableFile(atPath: file().path) else { throw XCTSkip("Host bypasses write permissions") }
        let pipe = Pipe()
        let sink = makeLog(failureLog: StandardErrorLog(output: pipe.fileHandleForWriting))
        sink.write(.warning, "safe metadata")
        sink.write(.error, "save failed")
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(try Data(contentsOf: file()), original)
        let notice = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
        XCTAssertEqual(String(decoding: notice, as: UTF8.self), "monkeyspaw warning: File logging unavailable; continuing with other log sinks\n")
    }

    func testDirectoryCreationFailureDisablesFileSinkEvenIfPathLaterBecomesWritable() throws {
        let blocked = dataDirectory.appendingPathComponent("private-location")
        try Data("not a directory".utf8).write(to: blocked)
        let pipe = Pipe()
        let sink = makeLog(directory: blocked, failureLog: StandardErrorLog(output: pipe.fileHandleForWriting))
        sink.write(.warning, "safe metadata")
        try manager.removeItem(at: blocked)
        sink.write(.error, "save failed")
        try pipe.fileHandleForWriting.close()

        XCTAssertFalse(manager.fileExists(atPath: blocked.path))
        let notice = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
        XCTAssertEqual(String(decoding: notice, as: UTF8.self), "monkeyspaw warning: File logging unavailable; continuing with other log sinks\n")
    }

    private func makeLog(directory: URL? = nil, failureLog: StandardErrorLog = StandardErrorLog()) -> FileLogSink {
        FileLogSink(dataDirectory: directory ?? dataDirectory, now: { Date(timeIntervalSince1970: 0) }, failureLog: failureLog)
    }

    private func file(archive: Int = 0) -> URL {
        let name = archive == 0 ? "monkeyspaw.log" : "monkeyspaw.log.\(archive)"
        return dataDirectory.appendingPathComponent("logs").appendingPathComponent(name)
    }

    private func seed(_ bytes: Data) throws {
        try manager.createDirectory(at: dataDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(manager.createFile(atPath: file().path, contents: bytes, attributes: [.posixPermissions: 0o600]))
    }

    private func contents() throws -> String {
        try String(contentsOf: file(), encoding: .utf8)
    }

    private func size(_ url: URL) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}

private final class FileFailureLogRecorder: LogSink {
    private let lock = NSLock()
    private var recorded: [String] = []
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func write(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(message)
    }
}
