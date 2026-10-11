import Darwin
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class RootedFileWatcherHealthTests: XCTestCase {
    private let manager = FileManager.default
    private var directory: URL!
    private var root: URL!

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func spin(until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return predicate()
    }

    override func tearDown() { try? manager.removeItem(at: directory) }

    func testPopulatedRootRemovedReportsUnavailableWithoutFileDeletions() throws {
        try Data("Cached".utf8).write(to: root.appendingPathComponent("cached.md"))
        try assertUnavailable(.notFound) { try manager.removeItem(at: root) }
    }

    func testEmptyRootRemovedReportsUnavailableOnce() throws {
        try assertUnavailable(.notFound) { try manager.removeItem(at: root) }
    }

    func testRootReplacedByRegularFileReportsUnavailableOnce() throws {
        try assertUnavailable(.invalidRoot) {
            try manager.removeItem(at: root)
            try Data("Replacement".utf8).write(to: root)
        }
    }

    func testUnreadableRootReportsUnavailableOnce() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        try assertUnavailable(.ioFailure) {
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        }
    }

    private func assertUnavailable(_ expected: FileStoreError, loss: () throws -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let observation = RootHealthObservation()
        let watcher = try RootedFileWatcher(root: root, log: StandardErrorLog())
        try watcher.start { observation.record($0) }
        defer { watcher.stop() }
        try loss()
        XCTAssertTrue(spin { !observation.errors.isEmpty }, file: file, line: line)
        // Force another native observation during the same unavailable streak.
        if manager.fileExists(atPath: root.path) {
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        } else {
            let parent = root.deletingLastPathComponent()
            try Data("Nudge".utf8).write(to: parent.appendingPathComponent("health-nudge"))
            // Linux filters sibling paths; notify the ancestor itself too.
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: parent.path)
        }
        let deadline = Date().addingTimeInterval(0.2)
        _ = spin { Date() >= deadline }
        XCTAssertEqual(observation.errors, [expected], file: file, line: line)
        XCTAssertTrue(observation.files.isEmpty, "Root loss must keep the last file baseline", file: file, line: line)
        XCTAssertTrue(observation.onOwnerThread, file: file, line: line)
    }
}

private final class RootHealthObservation: @unchecked Sendable {
    // FSEvents delivers on a serial background queue, never the hosted UI thread.
    private let lock = NSLock()
    private var storedFiles = [FileStoreEvent]()
    private var storedErrors = [FileStoreError]()
    private var ownerThreadOnly = true
    var files: [FileStoreEvent] { lock.lock(); defer { lock.unlock() }; return storedFiles }
    var errors: [FileStoreError] { lock.lock(); defer { lock.unlock() }; return storedErrors }
    var onOwnerThread: Bool { lock.lock(); defer { lock.unlock() }; return ownerThreadOnly }
    func record(_ update: FileStoreWatchEvent) {
        lock.lock()
        defer { lock.unlock() }
        ownerThreadOnly = ownerThreadOnly && !Thread.isMainThread
        switch update {
        case .file(let event): storedFiles.append(event)
        case .rootUnavailable(let error): storedErrors.append(error)
        }
    }
}
