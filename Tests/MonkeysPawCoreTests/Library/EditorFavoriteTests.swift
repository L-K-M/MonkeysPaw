import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorFavoriteTests: XCTestCase {
    func testBrowserFavoriteOnDirtyOpenPromptEditsBufferAndNeverWrites() throws {
        let e = EditorHarness()
        let source = "---\nmodel: {name: custom}\nfields:\n  a:\n    default: Swift\n---\n  Body {{a}} {{clipboard}}\r\n"
        let selection = try e.open(source)
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: e.h.library, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(selection); e.model.edit(source + "Edited\r\n") }
        let accesses = e.h.files.accessCount
        var result: PromptFavoriteOutcome?
        e.ui { result = browser.toggleFavorite() }
        guard case .editedBuffer = result else { return XCTFail("Expected a buffer hand-off.") }
        XCTAssertEqual(e.h.files.accessCount, accesses)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), source)
        XCTAssertTrue(e.model.state.isDirty)
        let draft = PromptCodec.parse(e.model.state.source!, filename: "a.md")
        XCTAssertTrue(draft.frontMatter.favorite)
        XCTAssertEqual(draft.body, "  Body {{a}} {{clipboard}}\r\nEdited\r\n")
        XCTAssertTrue(draft.source.contains("model:"))
        XCTAssertFalse(browser.rows[0].favorite, "A draft must not optimistically change the committed index.")
        e.ui { result = browser.toggleFavorite() }
        XCTAssertFalse(PromptCodec.parse(e.model.state.source!, filename: "a.md").frontMatter.favorite)
        e.ui { _ = browser.toggleFavorite(); e.model.save() }
        XCTAssertTrue(browser.rows[0].favorite)
        XCTAssertEqual(browser.selection, e.model.state.prompt)
        XCTAssertEqual(browser.selectedEntry?.stamp, e.model.state.stamp)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertEqual(e.clipboard.readCount, 0)
    }

    func testCleanOpenFavoriteUsesAsyncEditorSaveAndRefreshesOwnStamp() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let selection = try e.open()
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: e.h.library, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(selection) }
        e.settle()
        var result: PromptFavoriteOutcome?
        e.ui { result = browser.toggleFavorite() }
        guard case .savePending = result else { return XCTFail("The open session must own the async save.") }
        XCTAssertEqual(e.model.state.status, .saving)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
        e.h.held.releaseAll()
        e.ui { e.model.edit(e.model.state.source! + " Later edit") }
        e.settle()
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertTrue(browser.selectedEntry?.document.frontMatter.favorite == true)
        e.ui { e.model.save() }
        e.settle()
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
    }

    func testFavoriteDuringSaveStaysInNewerBuffer() throws {
        let e = EditorHarness(heldWork: true)
        let selection = try e.open()
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: e.h.library, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(selection); e.model.edit("Mine"); e.model.save() }
        var result: PromptFavoriteOutcome?
        e.ui { result = browser.toggleFavorite() }
        guard case .editedBuffer = result else { return XCTFail("Save-in-flight toggle wrote a second file.") }
        e.settle()
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertTrue(PromptCodec.parse(e.model.state.source!, filename: "a.md").frontMatter.favorite)
        XCTAssertFalse(PromptCodec.parse(try e.h.files.text(at: "a.md"), filename: "a.md").frontMatter.favorite)
        e.ui { e.model.save() }
        e.settle()
        XCTAssertTrue(browser.rows[0].favorite)
        XCTAssertNil(e.model.state.conflict)
    }

    func testUnrelatedBrowserFavoriteUsesExistingPortAndEditorStaysUntouched() throws {
        let e = EditorHarness()
        try e.open()
        let other = try e.put("Other", at: "b.md")
        // C1's unrelated favourite fallback remains synchronous. Use the same
        // backing stores without C2's worker-only assertion for this port.
        let favorites = LibraryService(library: e.h.files, data: e.h.data, clock: e.h.clock,
                                       entropy: e.h.entropy, keyedStores: [e.h.keyed])
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: favorites, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(other); e.model.edit("Mine") }
        let before = e.model.state
        var result: PromptFavoriteOutcome?
        e.ui { result = browser.toggleFavorite() }
        guard case .saved = result else { return XCTFail("Unrelated favourite lost the existing port.") }
        XCTAssertEqual(e.model.state, before)
        XCTAssertTrue(try e.h.files.text(at: "b.md").contains("favorite: true"))
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
    }

    func testInvalidAndReadOnlyBufferFavoriteFailWithoutTouchingDisk() throws {
        for source in ["Original", "---\nformat: 2\n---\nFuture"] {
            let e = EditorHarness()
            let selection = try e.open(source)
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(selection) }
            if !source.contains("format") { e.ui { e.model.edit("---\ntitle: [broken\n---\nMine") } }
            let before = e.model.state
            let accesses = e.h.files.accessCount
            var result: PromptFavoriteOutcome?
            e.ui { result = browser.toggleFavorite() }
            guard case .writeFailure = result else { return XCTFail("Protected buffer was written.") }
            XCTAssertEqual(e.model.state, before)
            XCTAssertEqual(e.h.files.accessCount, accesses)
            XCTAssertEqual(try e.h.files.text(at: "a.md"), source)
        }
    }

    func testBrowserDoesNotRetainEditor() throws {
        let e = EditorHarness()
        let selection = try e.put("Original")
        var editor: EditorModel? = EditorModel(editing: e.h.editor, clock: e.h.clock,
            timeZone: { TimeZone(secondsFromGMT: 0)! }, main: e.h.main)
        let favorites = LibraryService(library: e.h.files, data: e.h.data, clock: e.h.clock,
                                       entropy: e.h.entropy, keyedStores: [e.h.keyed])
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: favorites, main: e.h.main, editor: editor)
        e.ui { browser.selectPrompt(selection); editor?.open(selection) }
        weak var released = editor
        editor = nil
        XCTAssertNil(released)
        var result: PromptFavoriteOutcome?
        e.ui { result = browser.toggleFavorite() }
        guard case .saved = result else { return XCTFail("Released editor blocked the fallback port.") }
    }

    func testAsyncIdentityMigrationDoesNotOverrideNewerBrowserSelection() throws {
        for clearSelection in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            let original = try e.open()
            let other = try e.put("Other", at: "b.md")
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(original) }
            e.settle()
            e.ui { _ = browser.toggleFavorite() }
            e.h.held.releaseAll()
            e.ui { browser.selectPrompt(clearSelection ? nil : other) }
            e.settle()
            XCTAssertEqual(browser.selection, clearSelection ? nil : other)
            XCTAssertNil(e.model.state.conflict)
        }
    }

    func testFailedCleanFavoriteSaveKeepsDirtyDraftAndBrowserCommittedState() throws {
        let e = EditorHarness(heldWork: true)
        let selection = try e.open()
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: e.h.library, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(selection) }
        e.h.files.failNextWrite = true
        e.ui { _ = browser.toggleFavorite() }
        e.settle()
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(browser.selection, selection)
        XCTAssertFalse(browser.rows[0].favorite)
        e.ui { _ = browser.toggleFavorite() }
        XCTAssertFalse(PromptCodec.parse(e.model.state.source!, filename: "a.md").frontMatter.favorite)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
    }
}
