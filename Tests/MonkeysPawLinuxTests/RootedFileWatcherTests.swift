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
        let watcher = try RootedFileWatcher(root: url ?? root)
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
        pump(for: 0.15)
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
        pump(for: 0.15)
        try store.write(Data("Editor replacement".utf8), at: "a.md")
        expect(LibraryChangeSet(modified: ["a.md"]))

        try store.write(Data(), at: "transient.md")
        pump(for: 0.15)
        try store.delete(at: "transient.md")
        expectQuiet()

        try store.delete(at: "a.md")
        pump(for: 0.10)
        try store.write(Data(), at: "a.md")
        pump(for: 0.10)
        try store.delete(at: "a.md")
        expect(LibraryChangeSet(deleted: ["a.md"]))
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
        pump(for: 0.15)
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
        var watcher: RootedFileWatcher? = try RootedFileWatcher(root: root)
        try watcher?.start { events.append($0) }
        try watcher?.start { _ in XCTFail("Repeated raw start replaced the consumer.") }
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
        pump(for: 0.8)
        XCTAssertEqual(events.values.count, stoppedCount)
        weak var weakWatcher = watcher
        watcher = nil
        XCTAssertNil(weakWatcher, "Native callback contexts must not retain the driver.")
    }

    func testRejectsInvalidRootsAndSanitizesInitializationFailures() throws {
        for path in ["/", "//", "/..", "/./"] {
            XCTAssertThrowsError(try RootedFileWatcher(root: URL(fileURLWithPath: path))) {
                XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
            }
        }
        let link = directory.appendingPathComponent("root-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertThrowsError(try RootedFileWatcher(root: link)) {
            XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
        }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try RootedFileWatcher(root: file)) {
            XCTAssertEqual($0 as? FileStoreError, .invalidRoot)
            XCTAssertFalse($0.localizedDescription.contains(self.directory.path))
        }
        let dangling = directory.appendingPathComponent("dangling")
        try manager.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertThrowsError(try RootedFileWatcher(root: dangling.appendingPathComponent("library"))) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
        }
    }

    private func expect(_ expected: LibraryChangeSet, file: StaticString = #filePath, line: UInt = #line) {
        guard spin(until: { self.changes.count > self.consumed }) else {
            XCTFail("No debounced notification for \(expected)", file: file, line: line)
            return
        }
        XCTAssertEqual(changes[consumed], expected, file: file, line: line)
        consumed += 1
    }

    private func expectQuiet(file: StaticString = #filePath, line: UInt = #line) {
        pump(for: 0.8)
        XCTAssertEqual(changes.count, consumed, file: file, line: line)
    }

    private func pump(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        _ = spin(until: { Date() >= deadline })
    }

    private func spin(until predicate: () -> Bool) -> Bool {
        GTKTestSupport.spin(until: predicate, timeout: .seconds(5))
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
#endif
