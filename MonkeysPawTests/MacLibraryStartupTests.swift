import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacLibraryStartupTests: XCTestCase {
    private var directory: URL!
    private var files: RootedFileStore!
    private var index: PromptIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

    func testWatcherIsArmedBeforeInitialRebuild() throws {
        try files.write(Data("First".utf8), at: "a.md")
        let raw = MacStartupWatcher { try self.files.write(Data("Second".utf8), at: "b.md") }
        let watcher = LibraryWatcher(watcher: raw, scheduler: DispatchScheduler())
        defer { watcher.stop() }
        try AppDelegate.startLibrary(index: index, watcher: watcher) { _ in }
        XCTAssertEqual(index.search("").map(\.relativePath), ["a.md", "b.md"])
    }

    func testWatcherFailureAndMissingWatcherKeepCacheWithoutRebuilding() throws {
        try files.write(Data("Cached".utf8), at: "a.md")
        try index.rebuild()
        try files.write(Data("New".utf8), at: "a.md")
        let failing = LibraryWatcher(watcher: MacStartupWatcher { throw FileStoreError.ioFailure },
                                     scheduler: DispatchScheduler())
        defer { failing.stop() }
        for watcher: LibraryWatcher? in [nil, failing] {
            XCTAssertThrowsError(try AppDelegate.startLibrary(index: index, watcher: watcher) { _ in })
            XCTAssertEqual(index.search("").map(\.entry.document.body), ["Cached"])
        }
    }

    func testRebuildFailureKeepsCacheAndPropagates() throws {
        try files.write(Data("Cached".utf8), at: "a.md")
        try index.rebuild()
        let raw = MacStartupWatcher {
            let root = self.directory.appendingPathComponent("library")
            try FileManager.default.removeItem(at: root)
            try Data("Not a directory".utf8).write(to: root)
        }
        let watcher = LibraryWatcher(watcher: raw, scheduler: DispatchScheduler())
        defer { watcher.stop() }
        XCTAssertThrowsError(try AppDelegate.startLibrary(index: index, watcher: watcher) { _ in })
        XCTAssertEqual(index.search("").map(\.entry.document.body), ["Cached"])
    }
}

private final class MacStartupWatcher: FileStoreWatcher {
    private let onStart: () throws -> Void
    init(_ onStart: @escaping () throws -> Void) { self.onStart = onStart }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { try onStart() }
    func stop() {}
}
