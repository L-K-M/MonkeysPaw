#if os(Linux)
import Glibc
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

/// Real filesystem events pass through the production driver and scheduler.
/// Tests pump the native loop; Core debounce itself is proved without clocks.
final class RootedFileWatcherTests: XCTestCase {
    private let manager = FileManager.default
    private var directory: URL!
    private var root: URL!
    private var outside: URL!
    private var store: RootedFileStore!
    private var service: LibraryWatcher?
    private var changes = [LibraryChangeSet]()
    private var consumed = 0
    private var quietWindow: TimeInterval { Limits.watchDebounce.timeInterval + 0.3 }
    private var subWindow: TimeInterval { min(Limits.watchDebounce.timeInterval / 5, 0.1) }
    private var eventTimeout: TimeInterval { max(5, quietWindow * 3) }

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        outside = directory.appendingPathComponent("outside")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        store = try RootedFileStore(root: root)
    }

    override func tearDown() {
        service?.stop()
        service = nil
        try? manager.removeItem(at: directory)
    }

    private func start(at url: URL? = nil) throws {
        let watcher = try RootedFileWatcher(root: url ?? root, log: StandardErrorLog())
        let service = LibraryWatcher(watcher: watcher, scheduler: GLibScheduler())
        self.service = service
        try service.start { [weak self] in self?.changes.append($0) }
    }

    func testExistingRecursiveTreeCreateModifyRenameAndDelete() throws {
        try store.write(Data("Original".utf8), at: "existing/deep/a.md")
        try start()
        // In-place writes must notify, even without a directory vnode change.
        try Data("Edited".utf8).write(to: root.appendingPathComponent("existing/deep/a.md"))
        expect(LibraryChangeSet(modified: ["existing/deep/a.md"]))
        try store.write(Data("New".utf8), at: "existing/deep/b.md")
        expect(LibraryChangeSet(created: ["existing/deep/b.md"]))
        try store.move(from: "existing/deep/b.md", to: "renamed.md")
        expect(LibraryChangeSet(created: ["renamed.md"], deleted: ["existing/deep/b.md"]))
        try store.delete(at: "renamed.md")
        expect(LibraryChangeSet(deleted: ["renamed.md"]))
    }

    func testNewDirectoriesAndPopulatedDirectoryRenameRemainMonitored() throws {
        try start()
        // Create all directories and the file before the native loop runs.
        try store.write(Data("A".utf8), at: "new/deep/a.md")
        expect(LibraryChangeSet(created: ["new/deep/a.md"]))
        try Data("B".utf8).write(to: root.appendingPathComponent("new/deep/a.md"))
        expect(LibraryChangeSet(modified: ["new/deep/a.md"]))
        try manager.moveItem(at: root.appendingPathComponent("new"), to: root.appendingPathComponent("moved"))
        expect(LibraryChangeSet(created: ["moved/deep/a.md"], deleted: ["new/deep/a.md"]))
        try Data("C".utf8).write(to: root.appendingPathComponent("moved/deep/a.md"))
        expect(LibraryChangeSet(modified: ["moved/deep/a.md"]))
        try manager.removeItem(at: root.appendingPathComponent("moved"))
        expect(LibraryChangeSet(deleted: ["moved/deep/a.md"]))
    }

    func testMovesIntoAndOutOfRootIncludeDescendantsAndNotSiblingPaths() throws {
        let incoming = outside.appendingPathComponent("incoming")
        try manager.createDirectory(at: incoming.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: incoming.appendingPathComponent("deep/a.md"))
        try start()
        try manager.moveItem(at: incoming, to: root.appendingPathComponent("incoming"))
        expect(LibraryChangeSet(created: ["incoming/deep/a.md"]))
        try Data("B".utf8).write(to: root.appendingPathComponent("incoming/deep/a.md"))
        expect(LibraryChangeSet(modified: ["incoming/deep/a.md"]))
        try manager.moveItem(at: root.appendingPathComponent("incoming"), to: outside.appendingPathComponent("returned"))
        expect(LibraryChangeSet(deleted: ["incoming/deep/a.md"]))
        let sibling = directory.appendingPathComponent("library-other")
        try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("Outside".utf8).write(to: sibling.appendingPathComponent("a.md"))
        expectQuiet()
    }

    func testMissingRootAttachesAfterSuccessiveParentsAndFirstLazyWrite() throws {
        let missing = root.appendingPathComponent("missing/deep/library")
        let lazyStore = try RootedFileStore(root: missing)
        try start(at: missing)
        expectQuiet()
        XCTAssertFalse(manager.fileExists(atPath: missing.path))
        try manager.createDirectory(at: root.appendingPathComponent("missing"), withIntermediateDirectories: false)
        pump(for: subWindow)
        XCTAssertTrue(changes.isEmpty)
        try lazyStore.write(Data("First".utf8), at: "nested/a.md")
        expect(LibraryChangeSet(created: ["nested/a.md"]))
        try Data("Edited".utf8).write(to: missing.appendingPathComponent("nested/a.md"))
        expect(LibraryChangeSet(modified: ["nested/a.md"]))
        try lazyStore.delete(at: "nested/a.md")
        expect(LibraryChangeSet(deleted: ["nested/a.md"]))
    }

    func testMissingRootPopulatedOnArrivalAndRootReplacement() throws {
        try manager.removeItem(at: root)
        try start()
        XCTAssertFalse(manager.fileExists(atPath: root.path))
        let populated = outside.appendingPathComponent("populated")
        try manager.createDirectory(at: populated.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: populated.appendingPathComponent("deep/a.md"))
        try manager.moveItem(at: populated, to: root)
        expect(LibraryChangeSet(created: ["deep/a.md"]))
        try manager.removeItem(at: root)
        expect(LibraryChangeSet(deleted: ["deep/a.md"]))
        try store.write(Data("Recreated".utf8), at: "again.md")
        expect(LibraryChangeSet(created: ["again.md"]))
    }

    func testAtomicSavesAndDeleteCreateCoalesceAsModified() throws {
        try store.write(Data("Original".utf8), at: "a.md")
        try start()
        try store.write(Data("Atomic replacement".utf8), at: "a.md")
        expect(LibraryChangeSet(modified: ["a.md"]))
        try store.delete(at: "a.md")
        pump(for: subWindow)
        try store.write(Data("Editor replacement".utf8), at: "a.md")
        expectAggregate(LibraryChangeSet(modified: ["a.md"]), paths: ["a.md"], originallyPresent: ["a.md"])

        try store.write(Data(), at: "transient.md")
        pump(for: subWindow)
        try store.delete(at: "transient.md")
        expectAggregate(LibraryChangeSet(), paths: ["transient.md"])

        try store.delete(at: "a.md")
        pump(for: subWindow)
        try store.write(Data(), at: "a.md")
        pump(for: subWindow)
        try store.delete(at: "a.md")
        expectAggregate(LibraryChangeSet(deleted: ["a.md"]), paths: ["a.md"], originallyPresent: ["a.md"])
    }

    func testFiltersPromptPathsAndIgnoresAllSymlinksAndSpecialFiles() throws {
        try start()
        let eligible = [".draft.md", "folder/.draft.md", "folder/README.md", "folder.md/a.md"]
        let ignored = ["README.md", "_private.md", "_dir/a.md", ".hidden/a.md", "folder/_x.md", "notes.txt", "UPPER.MD"]
        for path in eligible + ignored { try store.write(Data(), at: path) }
        expect(LibraryChangeSet(created: Set(eligible)))

        let secret = outside.appendingPathComponent("secret.md")
        try Data("Outside".utf8).write(to: secret)
        try manager.createSymbolicLink(at: root.appendingPathComponent("alias.md"), withDestinationURL: secret)
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("internal"),
                                      withDestinationURL: root.appendingPathComponent("folder"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe.md").path, 0o600), 0)
        try Data("Changed".utf8).write(to: secret)
        expectQuiet()
        try manager.removeItem(at: root.appendingPathComponent("alias.md"))
        try manager.removeItem(at: root.appendingPathComponent("escape"))
        try manager.removeItem(at: root.appendingPathComponent("internal"))
        expectQuiet()
    }

    func testCanonicalAncestorAliasesAndMissingTailsMatchStore() throws {
        let real = directory.appendingPathComponent("real")
        let inner = directory.appendingPathComponent("inner-link")
        let outer = directory.appendingPathComponent("outer-link")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: inner, withDestinationURL: real)
        try manager.createSymbolicLink(at: outer, withDestinationURL: inner)
        let selected = outer.appendingPathComponent("missing/deep/library")
        let resolved = real.appendingPathComponent("missing/deep/library")
        let linkedStore = try RootedFileStore(root: selected)
        try start(at: selected)
        XCTAssertFalse(manager.fileExists(atPath: resolved.path))
        // Retarget the selected spelling after both drivers chose their root.
        try manager.removeItem(at: inner)
        try manager.createSymbolicLink(at: inner, withDestinationURL: outside)
        try linkedStore.write(Data("Inside".utf8), at: "nested/a.md")
        expect(LibraryChangeSet(created: ["nested/a.md"]))
        XCTAssertEqual(try Data(contentsOf: resolved.appendingPathComponent("nested/a.md")), Data("Inside".utf8))
        try Data("Outside".utf8).write(to: outside.appendingPathComponent("ignored.md"))
        expectQuiet()
        try Data("Updated".utf8).write(to: resolved.appendingPathComponent("nested/a.md"))
        expect(LibraryChangeSet(modified: ["nested/a.md"]))
    }

    func testReplacingCanonicalRootAncestorWithSymlinkNeverFollowsIt() throws {
        let parent = root.appendingPathComponent("parent")
        let nested = parent.appendingPathComponent("library")
        let nestedStore = try RootedFileStore(root: nested)
        try nestedStore.write(Data("Inside".utf8), at: "a.md")
        try Data("Outside".utf8).write(to: outside.appendingPathComponent("a.md"))
        try start(at: nested)
        try manager.removeItem(at: parent)
        try manager.createSymbolicLink(at: parent, withDestinationURL: outside)
        expect(LibraryChangeSet(deleted: ["a.md"]))
        try Data("Changed outside".utf8).write(to: outside.appendingPathComponent("a.md"))
        expectQuiet()
        try manager.removeItem(at: parent)
        try nestedStore.write(Data("Real tree".utf8), at: "b.md")
        expect(LibraryChangeSet(created: ["b.md"]))
    }

    func testStopRestartDiscardsPendingEventsAndTakesNewBaseline() throws {
        try start()
        try XCTUnwrap(service).start { _ in XCTFail("Repeated start replaced the consumer.") }
        try store.write(Data(), at: "discard.md")
        pump(for: subWindow)
        service?.stop()
        service?.stop()
        try store.write(Data(), at: "while-stopped.md")
        try XCTUnwrap(service).start { [weak self] in self?.changes.append($0) }
        expectQuiet()
        try store.write(Data(), at: "new.md")
        expect(LibraryChangeSet(created: ["new.md"]))
    }

    func testRawDriverDoesNotFilterOrDebounceAndReleasesOnStop() throws {
        let events = RawEvents()
        var watcher: RootedFileWatcher? = try RootedFileWatcher(root: root, log: StandardErrorLog())
        try watcher?.start { events.append($0) }
        let repeatedEvents = RawEvents()
        try watcher?.start { repeatedEvents.append($0) }
        try store.write(Data("Raw".utf8), at: "_raw.txt")
        XCTAssertTrue(spin { events.values.contains(FileStoreEvent(relativePath: "_raw.txt", kind: .created)) })
        try Data("Modified".utf8).write(to: root.appendingPathComponent("_raw.txt"))
        XCTAssertTrue(spin { events.values.contains(FileStoreEvent(relativePath: "_raw.txt", kind: .modified)) })
        try store.delete(at: "_raw.txt")
        XCTAssertTrue(spin { events.values.contains(FileStoreEvent(relativePath: "_raw.txt", kind: .deleted)) })
        watcher?.stop()
        watcher?.stop()
        let stoppedCount = events.values.count
        try store.write(Data(), at: "after-stop.md")
        pump(for: quietWindow)
        XCTAssertEqual(events.values.count, stoppedCount)
        XCTAssertTrue(repeatedEvents.values.isEmpty, "Repeated raw start must retain the first consumer.")
        weak var weakWatcher = watcher
        watcher = nil
        XCTAssertNil(weakWatcher, "Native callback contexts must not retain the driver.")
    }

    func testRawDriverCanStopInsideHandlerAndRestartWithNewBaseline() throws {
        let watcher = try RootedFileWatcher(root: root, log: StandardErrorLog())
        defer { watcher.stop() }
        let events = RawEvents()
        let stopped = RawCallbackResult()
        try watcher.start { [weak watcher] event in
            guard let watcher else { return }
            events.append(event)
            watcher.stop()
            stopped.complete()
        }
        try moveRawCallbackFixtureIntoRoot()
        XCTAssertTrue(spin { stopped.isComplete }, "Stop callback did not finish: \(events.values)")
        let firstEvent = FileStoreEvent(relativePath: "incoming/a.md", kind: .created)
        XCTAssertEqual(events.values, [firstEvent], "Stopping must discard the rest of this callback's diff.")
        try store.write(Data(), at: "while-stopped.md")
        pump(for: quietWindow)
        XCTAssertEqual(events.values, [firstEvent])

        let restartedEvents = RawEvents()
        try watcher.start { restartedEvents.append($0) }
        pump(for: quietWindow)
        XCTAssertTrue(restartedEvents.values.isEmpty, "A restart takes its baseline without emitting it.")
        try store.write(Data("Changed".utf8), at: "incoming/b.md")
        let modified = FileStoreEvent(relativePath: "incoming/b.md", kind: .modified)
        XCTAssertTrue(spin { restartedEvents.values.contains(modified) })
        try store.write(Data("Changed while stopped".utf8), at: "while-stopped.md")
        let stoppedFile = FileStoreEvent(relativePath: "while-stopped.md", kind: .modified)
        XCTAssertTrue(spin { restartedEvents.values.contains(stoppedFile) })
        pump(for: quietWindow)
        XCTAssertEqual(restartedEvents.values, [modified, stoppedFile])
        XCTAssertEqual(events.values, [firstEvent])
    }

    func testRawDriverCanStopAndStartInsideHandler() throws {
        let watcher = try RootedFileWatcher(root: root, log: StandardErrorLog())
        defer { watcher.stop() }
        let events = RawEvents()
        let restartedEvents = RawEvents()
        let restarted = RawCallbackResult()
        try watcher.start { [weak watcher] event in
            guard let watcher else { return }
            events.append(event)
            watcher.stop()
            do {
                try watcher.start { restartedEvents.append($0) }
                restarted.complete()
            } catch {
                restarted.complete(error: error)
            }
        }
        try moveRawCallbackFixtureIntoRoot()
        XCTAssertTrue(spin { restarted.isComplete }, "Restart callback did not finish: \(events.values)")
        XCTAssertNil(restarted.error)
        let firstEvent = FileStoreEvent(relativePath: "incoming/a.md", kind: .created)
        XCTAssertEqual(events.values, [firstEvent])
        pump(for: quietWindow)
        XCTAssertTrue(restartedEvents.values.isEmpty, "Old callback events must not enter the restarted run.")
        try store.write(Data("Changed".utf8), at: "incoming/b.md")
        let modified = FileStoreEvent(relativePath: "incoming/b.md", kind: .modified)
        XCTAssertTrue(spin { restartedEvents.values.contains(modified) })
        try store.delete(at: "incoming/a.md")
        let deleted = FileStoreEvent(relativePath: "incoming/a.md", kind: .deleted)
        XCTAssertTrue(spin { restartedEvents.values.contains(deleted) })
        pump(for: quietWindow)
        XCTAssertEqual(restartedEvents.values, [modified, deleted])
        XCTAssertEqual(events.values, [firstEvent])
    }

    func testRescanFailuresLogOncePerStreakAndKeepBaselineAndMonitoring() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory search permissions.") }
        try store.write(Data("Private baseline".utf8), at: "blocked/existing.md")
        let blocked = root.appendingPathComponent("blocked")
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let log = WatcherLog()
        let watcher = try RootedFileWatcher(root: root, log: log)
        defer { watcher.stop() }
        let events = RawEvents()
        try watcher.start { events.append($0) }

        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        try store.write(Data(), at: "first.md")
        XCTAssertTrue(spin { !log.values.isEmpty })
        try store.write(Data(), at: "second.md")
        pump(for: quietWindow)
        let diagnostic = WatcherLog.Entry(level: .error, message: "library rescan failed; keeping last baseline")
        XCTAssertEqual(log.values, [diagnostic])
        XCTAssertTrue(events.values.isEmpty, "Failed scans must not emit partial diffs or invented deletions.")

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        try store.write(Data(), at: "recovered.md")
        XCTAssertTrue(spin { events.values.contains(FileStoreEvent(relativePath: "recovered.md", kind: .created)) })
        pump(for: quietWindow)
        XCTAssertEqual(Set(events.values.map(\.relativePath)), ["first.md", "second.md", "recovered.md"])
        XCTAssertTrue(events.values.allSatisfy { $0.kind == .created })

        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        try store.write(Data(), at: "third.md")
        XCTAssertTrue(spin { log.values.count >= 2 })
        try store.write(Data(), at: "fourth.md")
        pump(for: quietWindow)
        XCTAssertEqual(log.values, [diagnostic, diagnostic], "A successful scan starts a fresh failure streak.")
        XCTAssertEqual(events.values.count, 3)

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        try store.write(Data(), at: "recovered-again.md")
        XCTAssertTrue(spin { events.values.contains(FileStoreEvent(relativePath: "recovered-again.md", kind: .created)) })
        pump(for: quietWindow)
        XCTAssertEqual(Set(events.values.map(\.relativePath)),
                       ["first.md", "second.md", "recovered.md", "third.md", "fourth.md", "recovered-again.md"])
        XCTAssertEqual(events.values.count, 6)
        XCTAssertTrue(events.values.allSatisfy { $0.kind == .created })
        XCTAssertEqual(log.values, [diagnostic, diagnostic])
    }

    private func moveRawCallbackFixtureIntoRoot() throws {
        let incoming = outside.appendingPathComponent("incoming")
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data().write(to: incoming.appendingPathComponent("a.md"))
        try Data().write(to: incoming.appendingPathComponent("b.md"))
        // The move exposes both files atomically, giving one scan a multi-event diff.
        try manager.moveItem(at: incoming, to: root.appendingPathComponent("incoming"))
    }

    func testRejectsInvalidRootsAndSanitizesInitializationFailures() throws {
        for path in ["/", "//", "/..", "/./"] {
            XCTAssertThrowsError(try RootedFileWatcher(root: URL(fileURLWithPath: path), log: StandardErrorLog())) {
                XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
            }
        }
        let link = directory.appendingPathComponent("root-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertThrowsError(try RootedFileWatcher(root: link, log: StandardErrorLog())) {
            XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
        }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try RootedFileWatcher(root: file, log: StandardErrorLog())) {
            XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
            XCTAssertFalse($0.localizedDescription.contains(self.directory.path))
        }
        let dangling = directory.appendingPathComponent("dangling")
        try manager.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("absent"))
        // Canonicalization escapes through a dangling symlink component, yielding outsideRoot.
        XCTAssertThrowsError(try RootedFileWatcher(root: dangling.appendingPathComponent("library"), log: StandardErrorLog())) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
        }
    }

    private func expect(_ expected: LibraryChangeSet, file: StaticString = #filePath, line: UInt = #line) {
        guard spin(until: { self.changes.count > self.consumed }) else {
            XCTFail("No debounced notification for \(expected); received but unconsumed: \(changes.dropFirst(consumed))",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(changes[consumed], expected, file: file, line: line)
        consumed += 1
    }

    /// Real native loops may cross a debounce deadline under load. Check all
    /// labels through the sequence, then compare its net effect to the contract.
    private func expectAggregate(_ expected: LibraryChangeSet, paths: Set<String>,
                                 originallyPresent: Set<String> = [],
                                 file: StaticString = #filePath, line: UInt = #line) {
        pump(for: quietWindow)
        let received = Array(changes.dropFirst(consumed))
        consumed = changes.count
        var present = originallyPresent
        var touched = Set<String>()
        for change in received {
            let labels = change.created.union(change.modified).union(change.deleted)
            XCTAssertTrue(labels.isSubset(of: paths), "Unexpected paths in \(received)", file: file, line: line)
            XCTAssertTrue(change.created.isDisjoint(with: change.modified)
                          && change.created.isDisjoint(with: change.deleted)
                          && change.modified.isDisjoint(with: change.deleted),
                          "Overlapping labels in \(received)", file: file, line: line)
            XCTAssertTrue(change.created.isDisjoint(with: present),
                          "Created an existing path in \(received)", file: file, line: line)
            XCTAssertTrue(change.modified.isSubset(of: present),
                          "Modified an absent path in \(received)", file: file, line: line)
            XCTAssertTrue(change.deleted.isSubset(of: present),
                          "Deleted an absent path in \(received)", file: file, line: line)
            present.subtract(change.deleted)
            present.formUnion(change.created)
            touched.formUnion(labels)
        }
        let aggregate = LibraryChangeSet(created: present.subtracting(originallyPresent),
                                         modified: present.intersection(originallyPresent).intersection(touched),
                                         deleted: originallyPresent.subtracting(present))
        XCTAssertEqual(aggregate, expected, "Received \(received)", file: file, line: line)
    }

    private func expectQuiet(file: StaticString = #filePath, line: UInt = #line) {
        pump(for: quietWindow)
        XCTAssertEqual(changes.count, consumed, file: file, line: line)
    }

    private func pump(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        _ = spin(until: { Date() >= deadline })
    }

    private func spin(until predicate: () -> Bool) -> Bool {
        GTKTestSupport.spin(until: predicate, timeout: .seconds(eventTimeout))
    }
}

/// macOS raw callbacks run on the watcher queue; the hosted test reads them
/// on the main thread. Keeping this helper on Linux mirrors the same checks.
private final class RawEvents {
    private let lock = NSLock()
    private var stored = [FileStoreEvent]()

    var values: [FileStoreEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ event: FileStoreEvent) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(event)
    }
}

/// Completion and thrown errors are read on the test thread after raw callbacks.
private final class RawCallbackResult {
    private let lock = NSLock()
    private var finished = false
    private var caughtError: Error?

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return caughtError
    }

    func complete(error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        caughtError = error
        finished = true
    }
}

private final class WatcherLog: LogSink {
    struct Entry: Equatable {
        let level: LogLevel
        let message: String
    }

    private let lock = NSLock()
    private var stored = [Entry]()

    var values: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func write(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(Entry(level: level, message: message))
    }
}
#endif
