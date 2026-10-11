#if os(Linux)
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryStartupTests: XCTestCase {
    private var directory: URL!
    private var files: RootedFileStore!
    private var index: PromptIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp-startup-\(UUID())")
        files = try RootedFileStore(root: directory.appendingPathComponent("library"))
        let data = try RootedFileStore(root: directory.appendingPathComponent("data"))
        let clock = SystemClock()
        let library = LibraryService(library: files, data: data, clock: clock, entropy: SystemEntropy())
        index = PromptIndex(service: library, usage: UsageStore(files: data, clock: clock), clock: clock)
    }

    override func tearDown() {
        index = nil
        files = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testWatcherStartsBeforeRebuildSoAnInterveningSaveIsIndexed() throws {
        try files.write(Data("First".utf8), at: "a.md")
        let raw = StartupWatcher {
            // Represents a save after monitoring starts and before rebuild.
            // Baselines do not emit events, so startup must load this itself.
            try self.files.write(Data("Second".utf8), at: "b.md")
        }
        let watcher = LibraryWatcher(watcher: raw, scheduler: GLibScheduler())
        defer { watcher.stop() }
        try LinuxEnvironment.startLibrary(index: index, watcher: watcher) { _ in }
        XCTAssertEqual(index.search("").map(\.relativePath), ["a.md", "b.md"])
    }

    func testWatcherStartFailureKeepsCachedIndexWithoutRebuilding() throws {
        try assertFailedStartupKeepsCache(watcher: LibraryWatcher(
            watcher: StartupWatcher { throw FileStoreError.ioFailure }, scheduler: GLibScheduler()))
    }

    func testMissingWatcherKeepsCachedIndexWithoutRebuilding() throws {
        try assertFailedStartupKeepsCache(watcher: nil)
    }

    func testRebuildFailureKeepsCachedIndexAndPropagatesToComposition() throws {
        try files.write(Data("Cached".utf8), at: "a.md")
        try index.rebuild()
        let raw = StartupWatcher {
            try FileManager.default.removeItem(at: self.directory.appendingPathComponent("library"))
            try Data("Not a directory".utf8).write(to: self.directory.appendingPathComponent("library"))
        }
        let watcher = LibraryWatcher(watcher: raw, scheduler: GLibScheduler())
        defer { watcher.stop() }
        XCTAssertThrowsError(try LinuxEnvironment.startLibrary(index: index, watcher: watcher) { _ in })
        XCTAssertEqual(index.search("").map(\.entry.document.body), ["Cached"])
    }

    private func assertFailedStartupKeepsCache(watcher: LibraryWatcher?) throws {
        defer { watcher?.stop() }
        try files.write(Data("Cached".utf8), at: "a.md")
        try index.rebuild()
        try files.write(Data("New bytes".utf8), at: "a.md")
        XCTAssertThrowsError(try LinuxEnvironment.startLibrary(index: index, watcher: watcher) { _ in })
        XCTAssertEqual(index.search("").map(\.entry.document.body), ["Cached"])
    }
}

private final class StartupWatcher: FileStoreWatcher {
    private let onStart: () throws -> Void

    init(_ onStart: @escaping () throws -> Void) { self.onStart = onStart }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { try onStart() }
    func stop() {}
}
#endif
