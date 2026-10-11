import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptIndexWatcherTests: XCTestCase {
    func testRawEventsReachIndexOnlyAfterPromptQuietWindow() throws {
        let library = MemoryFileStore()
        let data = MemoryFileStore()
        let clock = LibraryClock()
        let usage = UsageStore(files: data, clock: clock)
        let service = LibraryService(library: library, data: data, clock: clock,
                                     entropy: LibraryEntropy(), keyedStores: [usage])
        let index = PromptIndex(service: service, usage: usage, clock: clock)
        let raw = IndexFileWatcher()
        let scheduler = IndexScheduler()
        let watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        try library.put("Before", at: "a.md")
        try library.put("Delete", at: "b.md")
        try index.rebuild()
        try watcher.start { [index] set in
            do { try index.apply(set) }
            catch { XCTFail("Index application failed with typed error: \(error)") }
        }
        defer { watcher.stop() }

        try library.put("Created", at: "c.md")
        raw.send("c.md", .created)
        scheduler.advance(.milliseconds(300))
        try library.put("After", at: "a.md")
        raw.send("a.md", .modified)
        try library.delete(at: "b.md")
        raw.send("b.md", .deleted)
        scheduler.advance(.milliseconds(499))
        XCTAssertEqual(index.search("").map(\.relativePath), ["a.md", "b.md"])
        XCTAssertEqual(index.search("before").map(\.relativePath), ["a.md"])
        XCTAssertTrue(index.search("created").isEmpty)
        scheduler.advance(.milliseconds(1))
        XCTAssertEqual(index.search("").map(\.relativePath), ["a.md", "c.md"])
        XCTAssertEqual(index.search("after").map(\.relativePath), ["a.md"])
        XCTAssertEqual(index.search("created").map(\.relativePath), ["c.md"])
        XCTAssertTrue(index.search("before").isEmpty)
        XCTAssertEqual(scheduler.delays, Array(repeating: Limits.watchDebounce, count: 3))

        // An editor's delete/create save reloads the final bytes as modified.
        try library.delete(at: "a.md")
        raw.send("a.md", .deleted)
        try library.put("Final", at: "a.md")
        raw.send("a.md", .created)
        try library.delete(at: "c.md")
        raw.send("c.md", .deleted)
        scheduler.advance(.milliseconds(500))
        XCTAssertEqual(index.search("").map(\.relativePath), ["a.md"])
        XCTAssertEqual(index.search("final").map(\.relativePath), ["a.md"])
        XCTAssertTrue(index.search("after").isEmpty)
    }
}

private final class IndexFileWatcher: FileStoreWatcher {
    private var callback: (@Sendable (FileStoreEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreEvent) -> Void) throws { callback = onEvent }
    func stop() { callback = nil }
    func send(_ path: String, _ kind: FileStoreEvent.Kind) {
        callback?(FileStoreEvent(relativePath: path, kind: kind))
    }
}

private final class IndexScheduler: Scheduler {
    private var time: Duration = .zero
    private var pending = [(deadline: Duration, work: () -> Void)]()
    private(set) var delays = [Duration]()

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        pending.append((time + delay, work))
    }

    func advance(_ elapsed: Duration) {
        time += elapsed
        let ready = pending.filter { $0.deadline <= time }
        pending.removeAll { $0.deadline <= time }
        for timer in ready { timer.work() }
    }
}
