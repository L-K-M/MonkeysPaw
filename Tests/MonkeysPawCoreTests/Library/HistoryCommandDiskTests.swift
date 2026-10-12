import Foundation
import XCTest
@testable import MonkeysPawCore

final class HistoryCommandDiskTests: XCTestCase {
    private var root: URL!
    private var files: HistoryTestDiskStore!
    private var data: HistoryTestDiskStore!
    private var clock: LibraryClock!
    private var values: ValuesStore!
    private var usage: UsageStore!
    private var library: LibraryService!
    private var editing: PromptEditingService!
    private var index: PromptIndex!
    private var model: EditorModel!
    private var marker: EditingThreadMarker!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-history-\(UUID())")
        marker = EditingThreadMarker()
        files = try HistoryTestDiskStore(root: root.appendingPathComponent("library"), marker: marker)
        data = try HistoryTestDiskStore(root: root.appendingPathComponent("data"), marker: marker)
        clock = LibraryClock()
        values = ValuesStore(files: data)
        usage = UsageStore(files: data, clock: clock)
        library = LibraryService(library: files, data: data, clock: clock,
            entropy: LibraryEntropy(), keyedStores: [values, usage])
        index = PromptIndex(service: library, usage: usage, clock: clock)
        let main = EditingMainThread(marker)
        editing = PromptEditingService(library: library, index: index, work: InlineBackgroundWork(marker), main: main)
        model = EditorModel(editing: editing, clock: clock, timeZone: { .gmt }, main: main)
    }

    override func tearDownWithError() throws {
        model.deactivate()
        editing.deactivate()
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testDiskFixtureEnumeratesFilesThroughATemporaryDirectoryAlias() throws {
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let store = try HistoryTestDiskStore(root: alias, marker: marker)
        try store.write(Data("Original".utf8), at: "nested/a.md")
        XCTAssertEqual(try store.listFiles().map(\.relativePath), ["nested/a.md"])
    }

    func testCreateEditRenameMoveRestoreRoundTripsOnDiskWithIdentityAndHistory() throws {
        let body = "  Original {{field}}\r\n\r\n"
        let created = try library.create(PromptCodec.parse("---\ntitle: Keep title\n---\n" + body,
            filename: "a.md"), at: "a.md")
        try values.record(identity: created.identity, values: ["field": "remembered"])
        try usage.recordUse(identity: created.identity)
        try index.rebuild()
        let selection = LibraryPromptSelection(identity: created.identity, relativePath: RelativePath("a.md"))
        marker.ui { model.open(selection); model.edit(created.document.source + "Edited\r\n"); model.save() }
        let editedSource = try XCTUnwrap(model.state.source)
        marker.ui { model.rename(to: "renamed.md"); model.move(to: "new/deep"); model.loadHistory() }
        let destination = "new/deep/renamed.md"
        XCTAssertNil(try files.stamp(at: "a.md"))
        XCTAssertEqual(try files.read(at: destination), Data(editedSource.utf8))
        XCTAssertEqual(model.state.history.revisions.count, 1)
        let revision = try XCTUnwrap(model.state.history.revisions.first?.revision)
        XCTAssertEqual(model.state.history.revisions.first?.source, created.document.source)
        var restored: PromptCommandOutcome?
        marker.ui { model.restore(revision) { restored = $0 } }
        let entry = try XCTUnwrap(restored?.committedEntry)
        XCTAssertEqual(entry.identity, created.identity)
        XCTAssertEqual(entry.document.frontMatter.title, "Keep title")
        XCTAssertEqual(Array(entry.document.body.utf8), Array(body.utf8))
        XCTAssertEqual(try files.read(at: destination), Data(created.document.source.utf8))
        XCTAssertEqual(model.state.history.revisions.map(\.source), [editedSource, created.document.source])
        XCTAssertEqual(try values.rememberedValues(for: created.identity), ["field": "remembered"])
        XCTAssertEqual(try usage.useEvents(for: created.identity), [clock.date])

        // Reopen the data stores and library: this proves persistence, not just
        // the editor/index caches. The test roots contain real regular files.
        let reopened = LibraryService(library: files, data: data, clock: clock, entropy: LibraryEntropy())
        XCTAssertEqual(try reopened.load(at: destination).identity, created.identity)
        XCTAssertEqual(try reopened.history(for: created.identity).count, 2)
        XCTAssertEqual(try ValuesStore(files: data).rememberedValues(for: created.identity), ["field": "remembered"])
        XCTAssertEqual(try UsageStore(files: data, clock: clock).useEvents(for: created.identity), [clock.date])
        marker.ui { model.delete() }
        XCTAssertNil(model.state.prompt)
        XCTAssertNil(try files.stamp(at: destination))
        XCTAssertEqual(try reopened.history(for: created.identity).count, 2)
        let session = editing.beginSession(at: destination)
        var missing: PromptCommandOutcome?
        marker.ui { editing.restore(revision, session: session, expectedStamp: entry.stamp) { missing = $0 } }
        guard case .missing = missing else { return XCTFail("Deleted-prompt restore must remain deferred.") }
        XCTAssertNil(try files.stamp(at: destination))
    }

    func testLocalMoveThenFirstSaveMigratesValuesUsageAndHistoryOnDisk() throws {
        try files.write(Data("Before id\r\n".utf8), at: "a.md")
        let local = try library.load(at: "a.md")
        let revision = try HistoryStore(files: data).snapshot(Data("Older\r\n".utf8), for: local.identity, at: clock.date)
        try values.record(identity: local.identity, values: ["field": "kept"])
        try usage.recordUse(identity: local.identity)
        try index.rebuild()
        let browser = LibraryBrowserModel(index: index, usage: usage, favorites: library,
            main: EditingMainThread(marker), editor: model)
        let selection = LibraryPromptSelection(identity: local.identity, relativePath: RelativePath("a.md"))
        marker.ui { browser.selectPrompt(selection); model.open(selection); model.rename(to: "renamed.md") }
        let moved = try library.load(at: "renamed.md")
        XCTAssertEqual(moved.identity, PromptIdentity(path: "renamed.md", id: nil))
        XCTAssertEqual(browser.selection, model.state.prompt)
        XCTAssertEqual(browser.rows.first?.lastUsedAt, clock.date)
        XCTAssertEqual(try values.rememberedValues(for: moved.identity), ["field": "kept"])
        XCTAssertEqual(try usage.useEvents(for: moved.identity), [clock.date])
        XCTAssertEqual(try library.history(for: moved.identity).first?.filename, revision.filename)
        XCTAssertTrue(try library.history(for: local.identity).isEmpty)

        marker.ui { model.edit("After id\r\n"); model.save(); model.loadHistory() }
        let assigned = try XCTUnwrap(model.state.prompt?.identity)
        guard case .assigned = assigned else { return XCTFail("First save must assign a ULID.") }
        XCTAssertEqual(browser.selection, model.state.prompt)
        XCTAssertEqual(try values.rememberedValues(for: assigned), ["field": "kept"])
        XCTAssertEqual(try usage.useEvents(for: assigned), [clock.date])
        XCTAssertEqual(try library.history(for: assigned).count, 2)
        XCTAssertTrue(try library.history(for: moved.identity).isEmpty)
        let old = try XCTUnwrap(model.state.history.revisions.last?.revision)
        marker.ui { model.restore(old) }
        XCTAssertEqual(try library.load(at: "renamed.md").document.body, "Older\r\n")
        XCTAssertEqual(try library.load(at: "renamed.md").identity, assigned)
        XCTAssertEqual(try library.history(for: assigned).count, 3)
    }
}

/// Foundation-only regular-file fixture, private to these controlled temporary
/// roots. Platform drivers own production symlink/race hardening; deterministic
/// race tests use MemoryFileStore's operation hooks instead.
private final class HistoryTestDiskStore: FileStore {
    private let root: URL
    private let marker: EditingThreadMarker

    init(root: URL, marker: EditingThreadMarker) throws {
        self.marker = marker
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Darwin enumeration may resolve /var to /private/var. Use the same
        // canonical prefix when deriving relative paths from enumerated URLs.
        self.root = root.resolvingSymlinksInPath()
    }

    private func url(_ path: String) throws -> URL {
        XCTAssertFalse(marker.isUI, "Disk access ran on the UI thread.")
        try FileStorePath.validate(path)
        return root.appendingPathComponent(path)
    }

    func listFiles() throws -> [StoredFile] {
        XCTAssertFalse(marker.isUI)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw FileStoreError.ioFailure
        }
        return try enumerator.compactMap { object in
            guard let file = object as? URL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let path = String(file.path.dropFirst(root.path.count + 1))
            guard let stamp = try stamp(at: path) else { throw FileStoreError.notFound }
            return StoredFile(relativePath: path, stamp: stamp)
        }
    }

    func stamp(at path: String) throws -> FileStamp? {
        let file = try url(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FileStoreError.notRegularFile }
        let number = try XCTUnwrap(attributes[.systemFileNumber])
        let size = try XCTUnwrap(attributes[.size])
        let modified = try XCTUnwrap(attributes[.modificationDate])
        return FileStamp("\(number)|\(size)|\(modified)")
    }

    func read(at path: String) throws -> Data {
        guard try stamp(at: path) != nil else { throw FileStoreError.notFound }
        return try Data(contentsOf: url(path))
    }

    func write(_ data: Data, at path: String) throws {
        let file = try url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func create(_ data: Data, at path: String) throws {
        let file = try url(path)
        guard !FileManager.default.fileExists(atPath: file.path) else { throw FileStoreError.alreadyExists }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .withoutOverwriting)
    }

    func writePrivate(_ data: Data, at path: String) throws {
        try write(data, at: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(path).path)
    }

    func delete(at path: String) throws {
        guard try stamp(at: path) != nil else { throw FileStoreError.notFound }
        try FileManager.default.removeItem(at: url(path))
    }

    func move(from source: String, to destination: String) throws {
        guard try stamp(at: source) != nil else { throw FileStoreError.notFound }
        guard try stamp(at: destination) == nil else { throw FileStoreError.alreadyExists }
        let target = try url(destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(source), to: target)
    }
}
