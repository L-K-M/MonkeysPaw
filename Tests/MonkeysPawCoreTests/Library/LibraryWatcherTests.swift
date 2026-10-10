import XCTest
@testable import MonkeysPawCore

final class LibraryWatcherTests: XCTestCase {
    private let raw = FakeFileStoreWatcher()
    private let scheduler = WatchScheduler()
    private var changes = [LibraryChangeSet]()

    private func start() throws -> LibraryWatcher {
        let service = LibraryWatcher(watcher: raw, scheduler: scheduler)
        try service.start { [weak self] in self?.changes.append($0) }
        return service
    }

    func testLabelsDeduplicateAndSeparateWindows() throws {
        let service = try start()
        defer { service.stop() }
        raw.send("a.md", .created)
        raw.send("a.md", .created)
        raw.send("a.md", .modified)
        raw.send("b.md", .modified)
        raw.send("b.md", .modified)
        raw.send("c.md", .deleted)
        raw.send("c.md", .deleted)
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["a.md"], modified: ["b.md"], deleted: ["c.md"])])

        raw.send("a.md", .deleted)
        scheduler.fireAll()
        XCTAssertEqual(changes.last, LibraryChangeSet(deleted: ["a.md"]))
        XCTAssertEqual(changes.count, 2)
    }

    func testEditorSavesAndTransientFiles() throws {
        let service = try start()
        defer { service.stop() }
        let cases: [(String, [FileStoreEvent.Kind])] = [
            ("save.md", [.deleted, .created, .modified]),
            ("transient.md", [.created, .modified, .deleted]),
            ("gone.md", [.deleted, .created, .deleted]),
            ("new.md", [.created, .deleted, .created]),
            ("edited-gone.md", [.modified, .deleted]),
            ("new-gone.md", [.created, .deleted, .created, .deleted]),
        ]
        for (path, events) in cases { for kind in events { raw.send(path, kind) } }
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["new.md"], modified: ["save.md"],
                                                 deleted: ["gone.md", "edited-gone.md"])])
    }

    func testEveryEventRestartsDebounceAndStaleCallbacksNoOp() throws {
        let service = try start()
        defer { service.stop() }
        raw.send("a.md", .created)
        raw.send("b.md", .created)
        XCTAssertEqual(scheduler.delays, [Limits.watchDebounce, Limits.watchDebounce])
        scheduler.fire(0)
        XCTAssertTrue(changes.isEmpty)
        raw.send("a.md", .modified)
        XCTAssertEqual(scheduler.delays, Array(repeating: Limits.watchDebounce, count: 3))
        scheduler.fire(1)
        XCTAssertTrue(changes.isEmpty)
        // Ignored-path churn must not postpone the pending prompt window.
        for index in 0..<32 { raw.send("notes-\(index).txt", .modified) }
        XCTAssertEqual(scheduler.delays, Array(repeating: Limits.watchDebounce, count: 3))
        scheduler.fire(2)
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["a.md", "b.md"])])
    }

    func testPromptPathPolicyAndInvalidRawPaths() throws {
        let service = try start()
        defer { service.stop() }
        let eligible = [".draft.md", "folder/.draft.md", "folder/README.md", "folder/prompt.md"]
        let ignored = ["README.md", "_private.md", "folder/_private.md", "_draft/a.md", ".git/a.md",
                       "folder/.cache/a.md", "notes.txt", "UPPER.MD", "../escape.md", "/outside.md",
                       "a//b.md", "a/./b.md", "a\\b.md", "a\0.md"]
        for path in ignored { raw.send(path, .created) }
        XCTAssertTrue(scheduler.delays.isEmpty)
        scheduler.fireAll()
        XCTAssertTrue(changes.isEmpty)

        for path in eligible + ignored { raw.send(path, .created) }
        XCTAssertEqual(scheduler.delays, Array(repeating: Limits.watchDebounce, count: eligible.count))
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: Set(eligible))])
        for path in ignored { raw.send(path, .deleted) }
        XCTAssertEqual(scheduler.delays, Array(repeating: Limits.watchDebounce, count: eligible.count))
        scheduler.fireAll()
        XCTAssertEqual(changes.count, 1)
    }

    func testStartStopAreIdempotentAndOldRunsCannotEmit() throws {
        let service = try start()
        try service.start { _ in XCTFail("Second start must not replace the consumer.") }
        XCTAssertEqual(raw.starts, 1)
        raw.send("old.md", .created)
        let oldCallback = raw.callback
        service.stop()
        service.stop()
        XCTAssertEqual(raw.stops, 1)
        try service.start { [weak self] in self?.changes.append($0) }
        oldCallback?(FileStoreEvent(relativePath: "stale.md", kind: .created))
        raw.send("new.md", .created)
        scheduler.fire(0)
        XCTAssertTrue(changes.isEmpty)
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["new.md"])])
        service.stop()
    }

    func testFailedStartCanBeRetriedAndDeinitStopsDriver() throws {
        let service = LibraryWatcher(watcher: raw, scheduler: scheduler)
        raw.failure = FileStoreError.ioFailure
        XCTAssertThrowsError(try service.start { _ in XCTFail() })
        raw.failure = nil
        try service.start { [weak self] in self?.changes.append($0) }
        raw.send("late-root.md", .created)
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["late-root.md"])])
        service.stop()

        var temporary: LibraryWatcher? = try start()
        raw.send("discard.md", .created)
        weak var weakService = temporary
        temporary = nil
        XCTAssertNil(weakService)
        scheduler.fireAll()
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(raw.callback)
    }

    func testConsumerCanStopAndRestartDuringEmission() throws {
        let service = LibraryWatcher(watcher: raw, scheduler: scheduler)
        try service.start { [weak self, weak service] change in
            self?.changes.append(change)
            service?.stop()
            try? service?.start { [weak self] in self?.changes.append($0) }
        }
        raw.send("a.md", .created)
        scheduler.fireAll()
        raw.send("b.md", .created)
        scheduler.fireAll()
        XCTAssertEqual(changes, [LibraryChangeSet(created: ["a.md"]), LibraryChangeSet(created: ["b.md"])])
        service.stop()
    }
}

private final class FakeFileStoreWatcher: FileStoreWatcher {
    var callback: ((FileStoreEvent) -> Void)?
    var failure: FileStoreError?
    var starts = 0
    var stops = 0

    func start(_ onEvent: @escaping (FileStoreEvent) -> Void) throws {
        starts += 1
        if let failure { throw failure }
        callback = onEvent
    }

    func stop() { stops += 1; callback = nil }
    func send(_ path: String, _ kind: FileStoreEvent.Kind) {
        callback?(FileStoreEvent(relativePath: path, kind: kind))
    }
}

private final class WatchScheduler: Scheduler {
    var delays = [Duration]()
    private var callbacks = [(() -> Void)?]()

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        callbacks.append(work)
    }

    func fire(_ index: Int) {
        let callback = callbacks[index]
        callbacks[index] = nil
        callback?()
    }

    func fireAll() { for index in callbacks.indices { fire(index) } }
}
