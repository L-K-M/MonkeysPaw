import Foundation
import XCTest
@testable import MonkeysPawCore

final class LibraryFavoriteTests: XCTestCase {
    func testAttachedEditorRoutesAnotherPromptsFavoriteThroughPort() throws {
        for dirty in [false, true] {
            let e = EditorHarness(heldWork: true)
            try e.open()
            let other = try e.put("Other", at: "b.md")
            let favorites = LibraryService(library: e.h.files, data: e.h.data, clock: e.h.clock,
                                           entropy: e.h.entropy, keyedStores: [e.h.keyed])
            let port = FavoritePort(service: favorites)
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: port, main: e.h.main, editor: e.model)
            e.ui {
                browser.selectPrompt(other)
                if dirty { e.model.edit("Mine") }
            }
            let before = e.model.state
            let entry = try XCTUnwrap(browser.selectedEntry)
            var outcome: PromptFavoriteOutcome?
            e.ui { outcome = browser.toggleFavorite() }
            let first = try saved(try XCTUnwrap(outcome))
            XCTAssertTrue(first.document.frontMatter.favorite)
            XCTAssertEqual(port.entries.count, 1)
            XCTAssertEqual(port.entries.first?.identity, entry.identity)
            XCTAssertEqual(port.entries.first?.stamp, entry.stamp)
            XCTAssertEqual(browser.selectedEntry?.stamp, first.stamp)
            XCTAssertEqual(e.model.state, before, "dirty: \(dirty)")
            XCTAssertTrue(e.h.held.pending.isEmpty)
            XCTAssertTrue(try e.h.files.text(at: "b.md").contains("favorite: true"))
            XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")

            e.ui { outcome = browser.toggleFavorite() }
            let second = try saved(try XCTUnwrap(outcome))
            XCTAssertFalse(second.document.frontMatter.favorite)
            XCTAssertEqual(port.entries.count, 2)
            XCTAssertEqual(port.entries.last?.stamp, first.stamp)
            XCTAssertEqual(e.model.state, before)
            XCTAssertTrue(try e.h.files.text(at: "b.md").contains("favorite: false"))
        }
    }

    func testBrowserToggleSavesCanonicalFavoritePreservesBodyUnknownMetadataAndMigratesSelection() throws {
        let h = PromptFlowHarness()
        let body = "  Indented {{topic}}\r\n\nTrailing spaces  \n"
        let original = try h.put("---\ntitle: Example\ntags: [code]\nmodel:\n  name: custom\nfields:\n  topic:\n    default: Swift\n---\n" + body)
        try h.usage.recordUse(identity: original.identity, at: Date(timeIntervalSince1970: 10))
        try h.values.record(identity: original.identity, values: ["topic": "kept"])
        try h.open()
        let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: h.delivery.main)
        model.selectPrompt(model.rows[0].selection)
        var changes = 0
        model.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        let first = try saved(model.toggleFavorite())
        XCTAssertTrue(first.document.frontMatter.favorite)
        XCTAssertEqual(first.document.body, body)
        XCTAssertNotEqual(first.identity, original.identity)
        XCTAssertEqual(model.selection?.identity, first.identity)
        XCTAssertEqual(model.selectedEntry?.stamp, first.stamp)
        XCTAssertTrue(model.rows[0].favorite)
        XCTAssertTrue(h.picker.results[0].favorite)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(try h.usage.useEvents(for: first.identity), [Date(timeIntervalSince1970: 10)])
        XCTAssertEqual(try h.usage.useEvents(for: original.identity), [])
        XCTAssertEqual(model.rows[0].lastUsedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(try h.values.rememberedValues(for: first.identity), ["topic": "kept"])
        let canonical = try h.library.text(at: "a.md")
        XCTAssertTrue(canonical.contains("favorite: true\n"))
        XCTAssertFalse(canonical.contains("favourite:"), "The established §5.2 file key is favorite")
        XCTAssertTrue(canonical.contains("model:\n  name: custom\n"))
        XCTAssertEqual(first.document.frontMatter.fields[0].defaultValue, "Swift")
        let revision = try XCTUnwrap(h.service.history(for: first.identity).first)
        XCTAssertEqual(String(decoding: try HistoryStore(files: h.data).read(revision), as: UTF8.self), original.document.source)
        let second = try saved(model.toggleFavorite())
        XCTAssertFalse(second.document.frontMatter.favorite)
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertEqual(second.document.body, body)
        XCTAssertNotEqual(second.stamp, first.stamp)
        XCTAssertEqual(model.selectedEntry?.stamp, second.stamp)
        XCTAssertEqual(changes, 2)
    }

    func testToggleKeepsAnExistingFavoriteKeyInPlace() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\ntitle: Example\nfavorite: false\nmodel: custom\n---\nBody")
        try h.open()
        let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: h.delivery.main)
        model.selectPrompt(model.rows[0].selection)
        _ = try saved(model.toggleFavorite())
        let text = try h.library.text(at: "a.md")
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { return nil }
            return String(line[..<colon])
        }
        // Toggling rewrites the value only; the key keeps its position.
        XCTAssertEqual(Array(keys.prefix(4)), ["id", "title", "favorite", "model"])
    }

    func testStaleStampDeletionAndTypedWriteFailuresRetainSelectionWithoutOptimisticChanges() throws {
        for failure in [FavoriteFailure.externalWrite, .deletion, .write] {
            let h = PromptFlowHarness()
            _ = try h.put("Original")
            try h.index.rebuild()
            let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: h.delivery.main)
            model.selectPrompt(model.rows[0].selection)
            let before = model.state
            var changes = 0
            model.onChange = { changes += 1 }
            switch failure {
            case .externalWrite: try h.library.put("External", at: "a.md")
            case .deletion: try h.library.delete(at: "a.md")
            case .write: h.library.failNextWrite = true
            }
            switch (failure, model.toggleFavorite()) {
            case (.externalWrite, .libraryFailure(.conflict)), (.deletion, .libraryFailure(.conflict)),
                 (.write, .fileStoreFailure(.ioFailure)): break
            default: XCTFail("Wrong typed favourite failure")
            }
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(changes, 0)
            switch failure {
            case .externalWrite: XCTAssertEqual(try h.library.text(at: "a.md"), "External")
            case .deletion: XCTAssertNil(try h.library.stamp(at: "a.md"))
            case .write: XCTAssertEqual(try h.library.text(at: "a.md"), "Original")
            }
        }
    }

    func testInvalidAndFutureDocumentsRefuseFavoriteWritesAndStayVisible() throws {
        for source in ["---\ntitle: [broken\n---\nBody", "---\nformat: 2\n---\nBody"] {
            let h = PromptFlowHarness()
            let entry = try h.put(source)
            try h.index.rebuild()
            let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: h.delivery.main)
            model.selectPrompt(model.rows[0].selection)
            switch model.toggleFavorite() {
            case .writeFailure(.invalidPrompt): XCTAssertFalse(entry.document.isReadOnly)
            case .writeFailure(.unsupportedFormat(let format)): XCTAssertEqual(format, entry.document.frontMatter.format)
            default: XCTFail("A non-writable document was accepted")
            }
            XCTAssertEqual(model.rows.count, 1)
            XCTAssertEqual(try h.library.text(at: "a.md"), source)
        }
    }

    func testPortReceivesHeldEntryAndLoadStampAndUnknownServiceErrorsAreSanitized() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("Body")
        try h.index.rebuild()
        let port = FavoritePort()
        let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: port, main: h.delivery.main)
        if case .noSelection = model.toggleFavorite() {} else { XCTFail("Missing selection was accepted") }
        XCTAssertTrue(port.entries.isEmpty)
        model.selectPrompt(model.rows[0].selection)
        for outcome in [PromptFavoriteOutcome.fileStoreFailure(.outsideRoot), .libraryFailure(.recoveryRequired),
                        .writeFailure(.serializationFailed)] {
            port.outcome = outcome
            switch (outcome, model.toggleFavorite()) {
            case (.fileStoreFailure(let expected), .fileStoreFailure(let actual)):
                XCTAssertEqual(actual, expected)
            case (.libraryFailure(let expected), .libraryFailure(let actual)):
                XCTAssertEqual(actual, expected)
            case (.writeFailure(let expected), .writeFailure(let actual)):
                XCTAssertEqual(actual, expected)
            default: XCTFail("The favourite port's failure was not returned.")
            }
            XCTAssertFalse(model.rows[0].favorite)
        }
        XCTAssertEqual(port.entries.count, 3)
        XCTAssertTrue(port.entries.allSatisfy { $0.identity == entry.identity && $0.stamp == entry.stamp })
        h.library.onRead = { _ in throw NSError(domain: "private error body", code: 1) }
        if case .libraryFailure(.operationFailed) = h.service.toggleFavorite(of: entry) {} else {
            XCTFail("Unknown error was exposed")
        }
    }

    func testSavedSnapshotDoesNotOverwriteNewerWatcherPublication() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nBefore")
        try h.index.rebuild()
        let savedEntry = try saved(h.service.toggleFavorite(of: entry))
        try h.library.put("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nNewer external", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: ["a.md"]))
        h.index.acceptSaved(savedEntry, replacing: entry)
        XCTAssertEqual(h.index.search("").first?.entry.document.body, "Newer external")
        try h.library.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: ["a.md"]))
        h.index.acceptSaved(savedEntry, replacing: entry)
        XCTAssertTrue(h.index.search("").isEmpty)
    }

    private func saved(_ outcome: PromptFavoriteOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> LibraryEntry {
        guard case .saved(let entry) = outcome else {
            XCTFail("Expected a saved favourite", file: file, line: line)
            throw LibraryError.operationFailed
        }
        return entry
    }
}

private enum FavoriteFailure { case externalWrite, deletion, write }

private final class FavoritePort: PromptFavoriteEditing {
    private let service: PromptFavoriteEditing?
    var entries: [LibraryEntry] = []
    var outcome = PromptFavoriteOutcome.libraryFailure(.operationFailed)
    init(service: PromptFavoriteEditing? = nil) { self.service = service }
    func toggleFavorite(of entry: LibraryEntry) -> PromptFavoriteOutcome {
        entries.append(entry)
        return service?.toggleFavorite(of: entry) ?? outcome
    }
}
