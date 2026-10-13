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

    func testAssistantAcceptPersistsExactPreviewAndProvenanceAcrossReopenMoveAndDelete() throws {
        let provider = ProviderHarness()
        let secret = "key-" + UUID().uuidString
        let notes = "notes-" + UUID().uuidString
        try provider.service.save(ProviderDraft(kind: .openaiCompatible, modelID: "manual-model", key: .replace(SecretValue(secret))))
        let profile = try XCTUnwrap(provider.service.snapshot.settings.profiles.first)
        let id = try ULID.generate(at: clock.date, entropy: Array(repeating: 3, count: Limits.ulidEntropyBytes))
        var firstBytes: Data?
        for improve in [false, true] {
            let artifact = LlmArtifact(title: "Candidate", description: "", tags: [], fields: [],
                body: improve ? "  Changed e\u{301}\r\n\n" : "  Original 文書\r\n\n", notes: notes)
            let snapshot = model.assistantSnapshot
            let merge = improve ? ArtifactMerge.improve(artifact, original: try XCTUnwrap(snapshot).document)
                : ArtifactMerge.write(artifact, id: id)
            guard case .ready(let content) = merge else { return XCTFail("Expected ready bytes.") }
            let candidate = AssistantCandidate(content: content,
                diff: try ArtifactDiff.compare(original: snapshot?.document, candidate: content),
                context: AssistantContext(libraryID: UUID(), profile: profile, editor: snapshot), mutationAccess: .currentScope)
            let acceptance = AssistantAcceptance(id: UUID(), candidate: candidate, usage: nil)
            var outcome: AssistantAcceptanceOutcome?
            marker.ui {
                model.acceptAssistant(acceptance, destination: improve ? .improve : .newPrompt,
                    permit: AssistantSavePermit(), validate: { nil }) { outcome = $0; XCTAssertTrue(self.marker.isUI) }
            }
            let entry = try XCTUnwrap(outcome?.committed?.entry)
            XCTAssertEqual(try files.read(at: entry.relativePath), content.canonicalBytes)
            XCTAssertEqual(model.state.source.map { Data($0.utf8) }, content.canonicalBytes)
            XCTAssertEqual(entry.identity, .assigned(id))
            if improve {
                let revision = try XCTUnwrap(library.history(for: entry.identity).first)
                XCTAssertEqual(try library.provenance(for: revision)?.origin, .llm)
                XCTAssertEqual(try data.read(at: "history/" + id.rawValue + "/" + revision.filename), firstBytes)
            } else { firstBytes = content.canonicalBytes }
        }
        marker.ui { model.rename(to: "renamed.md"); model.move(to: "folder") }
        let reopened = LibraryService(library: files, data: data, clock: clock, entropy: LibraryEntropy())
        XCTAssertEqual(try reopened.provenance(at: "folder/renamed.md")?.providerHost, "api.openai.com")
        let revision = try XCTUnwrap(reopened.history(for: .assigned(id)).first)
        XCTAssertEqual(try reopened.provenance(for: revision)?.model, "manual-model")
        for file in try data.listFiles() {
            let bytes = try data.read(at: file.relativePath)
            for sentinel in [secret, notes] { XCTAssertNil(bytes.range(of: Data(sentinel.utf8))) }
        }
        let before = try data.listFiles()
        marker.ui { model.delete() }
        XCTAssertNil(try files.stamp(at: "folder/renamed.md"))
        XCTAssertEqual(try data.listFiles(), before)
        XCTAssertEqual(try reopened.provenance(for: revision)?.origin, .llm)
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
        self.root = root
    }

    private func url(_ path: String) throws -> URL {
        XCTAssertFalse(marker.isUI, "Disk access ran on the UI thread.")
        try FileStorePath.validate(path)
        return root.appendingPathComponent(path)
    }

    func listFiles() throws -> [StoredFile] {
        XCTAssertFalse(marker.isUI)
        // Enumerate the resolved root: Foundation does not descend a symlinked
        // root. Enumerated URLs may still spell it differently (/var vs
        // /private/var on Darwin), so resolve both sides the same way; Darwin's
        // resolver strips /private from each consistently.
        let resolved = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw FileStoreError.ioFailure
        }
        let base = resolved.pathComponents
        return try enumerator.compactMap { object in
            guard let file = object as? URL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            let components = file.resolvingSymlinksInPath().pathComponents
            guard components.starts(with: base) else { throw FileStoreError.invalidPath }
            let path = components.dropFirst(base.count).joined(separator: "/")
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
