import Foundation
import XCTest
@testable import MonkeysPawCore

extension HistoryTestCommand {
    func run(_ model: EditorModel, revision: HistoryRevision, completion: @escaping (PromptCommandOutcome) -> Void) {
        switch self {
        case .rename: model.rename(to: "renamed.md", completion: completion)
        case .move: model.move(to: "one/two", completion: completion)
        case .delete: model.delete(completion: completion)
        case .restore: model.restore(revision, completion: completion)
        }
    }
}

final class EditorFileCommandTests: XCTestCase {
    func testEveryCommandUsesSaveDiscardCancelGuardWithBothMainModes() throws {
        for queuedMain in [false, true] {
            for command in HistoryTestCommand.allCases {
                for decision in [EditorDecision.save, .discard, .cancel] {
                    let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                    let selection = try e.open(historyCommandSource)
                    let revision = try historySnapshot(e.h, identity: selection.identity)
                    var result: PromptCommandOutcome?
                    e.ui { e.model.edit(historyCommandSource + "Mine"); command.run(e.model, revision: revision) {
                        result = $0
                        XCTAssertTrue(e.h.marker.isUI)
                    } }
                    e.h.main.releaseAll()
                    XCTAssertEqual(e.model.state.pendingDecision?.action, command.action)
                    XCTAssertNil(result)
                    XCTAssertEqual(try e.h.files.text(at: "a.md"), historyCommandSource)
                    try e.decide(decision)
                    e.settle()
                    if decision == .cancel {
                        guard case .cancelled = result else { return XCTFail("Expected cancelled command.") }
                        XCTAssertEqual(e.model.state.source, historyCommandSource + "Mine")
                        XCTAssertEqual(e.model.state.prompt, selection)
                        XCTAssertEqual(try e.h.files.text(at: "a.md"), historyCommandSource)
                    } else if command == .delete {
                        guard case .deleted = result else { return XCTFail("Expected guarded deletion.") }
                        XCTAssertNil(e.model.state.prompt)
                        XCTAssertNil(try e.h.files.stamp(at: "a.md"))
                    } else {
                        let entry = try XCTUnwrap(result?.committedEntry)
                        XCTAssertEqual(entry.relativePath, command.destination)
                        XCTAssertEqual(entry.identity, selection.identity)
                        if command == .restore { XCTAssertEqual(entry.document.body, "Previous\r\n") }
                        else { XCTAssertEqual(entry.document.body, decision == .save ? "Original\r\nMine" : "Original\r\n") }
                        XCTAssertFalse(e.model.state.isDirty)
                        XCTAssertNil(e.model.state.pendingDecision)
                    }
                }
            }
        }
    }

    func testEveryCommandWaitsForSaveInFlightAndUsesItsNewStamp() throws {
        for queuedMain in [false, true] {
            for command in HistoryTestCommand.allCases {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let selection = try e.open(historyCommandSource)
                let revision = try historySnapshot(e.h, identity: selection.identity)
                var result: PromptCommandOutcome?
                e.ui { e.model.edit(historyCommandSource + "Mine"); e.model.save()
                    command.run(e.model, revision: revision) { result = $0 } }
                e.h.main.releaseAll()
                XCTAssertEqual(e.model.state.queuedActions, [command.action])
                XCTAssertNil(e.model.state.pendingDecision)
                XCTAssertNil(result)
                XCTAssertEqual(e.h.held.pending.count, 1, "The command cannot race its preceding save.")
                e.settle()
                XCTAssertNotNil(result)
                XCTAssertNil(e.model.state.conflict)
                if command != .delete {
                    XCTAssertNotNil(result?.committedEntry)
                    XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: command.destination))
                }
            }
        }
    }

    func testFailedSaveAndNewerDraftKeepCommandPending() throws {
        for failedSave in [false, true] {
            for command in HistoryTestCommand.allCases {
                let e = EditorHarness(heldWork: true)
                let selection = try e.open(historyCommandSource)
                let revision = try historySnapshot(e.h, identity: selection.identity)
                if failedSave { e.h.files.failNextWrite = true }
                var result: PromptCommandOutcome?
                e.ui { e.model.edit(historyCommandSource + "Mine"); e.model.save()
                    command.run(e.model, revision: revision) { result = $0 }
                    if !failedSave { e.model.edit(historyCommandSource + "Newer") }
                }
                e.settle()
                XCTAssertNil(result)
                XCTAssertEqual(e.model.state.pendingDecision?.action, command.action)
                XCTAssertTrue(e.model.state.isDirty)
                XCTAssertNotNil(try e.h.files.stamp(at: "a.md"))
                try e.decide(.cancel)
                guard case .cancelled = result else { return XCTFail("Expected pending command cancellation.") }
            }
        }
    }

    func testSaveStartedAfterDiscardWaitsBeforeQueuedGuardApproval() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        try e.open(historyCommandSource)
        var result: PromptCommandOutcome?
        e.ui { e.model.edit(historyCommandSource + "Mine"); e.model.rename(to: "renamed.md") { result = $0 } }
        e.h.main.releaseAll()
        try e.decide(.discard)
        // Approval is queued, but a new explicit save can begin inline before
        // that hop. The file command must use the stamp from this save's reply.
        e.ui { e.model.save() }
        e.h.main.releaseAll()
        XCTAssertEqual(e.model.state.status, .saving)
        XCTAssertEqual(e.h.held.pending.count, 1)
        e.settle()
        XCTAssertNotNil(result?.committedEntry)
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("renamed.md"))
        XCTAssertNil(e.model.state.conflict)
    }

    func testRenameAndMoveFollowAssignedAndLocalIdentityWithoutChangingFileBytes() throws {
        for assigned in [false, true] {
            for queuedMain in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let source = assigned ? historyCommandSource : "---\ntitle: Keep title\n---\nOriginal\r\n"
                let original = try e.open(source)
                let revision = try historySnapshot(e.h, identity: original.identity)
                let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                    favorites: e.h.library, main: e.h.main, editor: e.model)
                e.ui { browser.selectPrompt(original); e.model.loadHistory() }
                e.settle()
                for command in [HistoryTestCommand.rename, .move] {
                    var result: PromptCommandOutcome?
                    e.ui { command.run(e.model, revision: revision) { result = $0 } }
                    e.settle()
                    let entry = try XCTUnwrap(result?.committedEntry)
                    XCTAssertEqual(browser.selection, e.model.state.prompt)
                    XCTAssertEqual(browser.selectedEntry?.stamp, entry.stamp)
                    XCTAssertEqual(try e.h.files.text(at: entry.relativePath), source)
                    XCTAssertEqual(entry.document.frontMatter.title, assigned ? "Title" : "Keep title")
                    XCTAssertEqual(e.model.state.history.revisions.first?.revision.filename, revision.filename)
                    if assigned { XCTAssertEqual(entry.identity, original.identity) }
                    else { XCTAssertEqual(entry.identity, PromptIdentity(path: entry.relativePath, id: nil)) }
                    XCTAssertNil(e.model.state.conflict)
                }
            }
        }
    }

    func testDeleteClosesEditorClearsBrowserSelectionAndKeepsHistory() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let original = try e.open(historyCommandSource)
            let revision = try historySnapshot(e.h, identity: original.identity)
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(original); e.model.delete() }
            e.settle()
            XCTAssertNil(e.model.state.prompt)
            XCTAssertNil(e.model.state.source)
            XCTAssertNil(browser.selection)
            XCTAssertTrue(browser.rows.isEmpty)
            XCTAssertEqual(try e.h.library.history(for: original.identity), [revision])
        }
    }

    func testCommandCompletionDoesNotOverrideNewerBrowserSelection() throws {
        for command in HistoryTestCommand.allCases {
            for clearsSelection in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: true)
                let original = try e.open(historyCommandSource)
                let revision = try historySnapshot(e.h, identity: original.identity)
                let other = try e.put("Other", at: "b.md")
                let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                    favorites: e.h.library, main: e.h.main, editor: e.model)
                e.ui { browser.selectPrompt(original); command.run(e.model, revision: revision) { _ in } }
                e.h.main.releaseAll()
                e.h.held.releaseNext()
                e.ui { browser.selectPrompt(clearsSelection ? nil : other) }
                e.settle()
                XCTAssertEqual(browser.selection, clearsSelection ? nil : other)
            }
        }
    }

    func testStaleMissingAndReadOnlyCommandsExposeTypedResultsAndConflicts() throws {
        for command in [HistoryTestCommand.rename, .move, .delete] {
            for missing in [false, true] {
                let e = EditorHarness()
                let original = try e.open(historyCommandSource)
                let revision = try historySnapshot(e.h, identity: original.identity)
                if missing { try e.h.files.delete(at: "a.md") }
                else { try e.h.files.put(historyCommandSource + "Theirs", at: "a.md") }
                var result: PromptCommandOutcome?
                e.ui { command.run(e.model, revision: revision) { result = $0 } }
                if missing {
                    guard case .missing = result else { return XCTFail("Expected missing command result.") }
                    XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
                } else {
                    guard case .conflict(let stamp) = result else { return XCTFail("Expected stale command conflict.") }
                    XCTAssertEqual(e.model.state.conflict?.stamp, stamp)
                    XCTAssertEqual(e.model.state.conflict?.theirsSource, historyCommandSource + "Theirs")
                }
                XCTAssertEqual(e.model.state.source, historyCommandSource)
                XCTAssertEqual(try e.h.library.history(for: original.identity), [revision])
            }
            let e = EditorHarness()
            let original = try e.open("---\nformat: 2\n---\nFuture")
            let revision = try historySnapshot(e.h, identity: original.identity)
            var result: PromptCommandOutcome?
            e.ui { command.run(e.model, revision: revision) { result = $0 } }
            guard case .readOnly = result else { return XCTFail("Expected protected format.") }
            XCTAssertEqual(e.model.state.prompt, original)
        }
    }

    func testOccupiedResultKeepsEditorAndBrowserAtOriginalSelection() throws {
        for command in [HistoryTestCommand.rename, .move] {
            let e = EditorHarness()
            let original = try e.open(historyCommandSource)
            let revision = try historySnapshot(e.h, identity: original.identity)
            try e.put("Occupied", at: command.destination)
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(original) }
            var result: PromptCommandOutcome?
            e.ui { command.run(e.model, revision: revision) { result = $0 } }
            guard case .destinationOccupied = result else { return XCTFail("Expected occupied result.") }
            XCTAssertEqual(e.model.state.prompt, original)
            XCTAssertEqual(browser.selection, original)
            XCTAssertEqual(e.model.state.source, historyCommandSource)
        }
    }

    func testNavigationAndEditsWaitWhileCommandWorkIsHeld() throws {
        let e = EditorHarness(heldWork: true)
        try e.open(historyCommandSource)
        var events: [String] = []
        e.ui { e.model.rename(to: "renamed.md") { _ in events.append("renamed") }
            e.model.edit("Would lose draft")
            e.model.save()
            e.model.request(.close) { _ in events.append("closed") }
        }
        XCTAssertEqual(e.model.state.status, .commandRunning)
        XCTAssertFalse(e.model.state.canEdit)
        XCTAssertEqual(e.model.state.source, historyCommandSource)
        XCTAssertEqual(e.model.state.queuedActions, [.close])
        XCTAssertTrue(events.isEmpty)
        e.settle()
        XCTAssertEqual(events, ["renamed", "closed"])
        XCTAssertNil(e.model.state.prompt)
        XCTAssertEqual(try e.h.files.text(at: "renamed.md"), historyCommandSource)
    }

    func testQueuedCommandCannotActOnPromptOpenedByEarlierRequest() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        try e.open(historyCommandSource)
        let other = try e.put("Other", at: "b.md")
        var result: PromptCommandOutcome?
        e.ui { e.model.open(other); e.model.delete { result = $0 } }
        e.settle()
        guard case .inactive = result else { return XCTFail("Expected superseded command.") }
        XCTAssertEqual(try e.h.files.text(at: "a.md"), historyCommandSource)
        XCTAssertEqual(try e.h.files.text(at: "b.md"), "Other")
        XCTAssertEqual(e.model.state.prompt, other)
    }

    func testNoSelectionAndInactiveEditorReturnWithoutFileWork() throws {
        let e = EditorHarness(queuedMain: true)
        var result: PromptCommandOutcome?
        e.ui { e.model.delete { result = $0 } }
        e.settle()
        guard case .noSelection = result else { return XCTFail("Expected no selection.") }
        e.ui { e.model.deactivate(); e.model.rename(to: "a.md") { result = $0 } }
        e.settle()
        guard case .inactive = result else { return XCTFail("Expected retired editor.") }
        XCTAssertEqual(e.h.files.accessCount, 0)
    }

    func testUnrelatedIndexPublicationDoesNotHideCommittedMove() throws {
        let e = EditorHarness()
        let original = try e.open(historyCommandSource)
        try e.put("Other", at: "b.md")
        let other = try e.h.library.load(at: "b.md")
        let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
            favorites: e.h.library, main: e.h.main, editor: e.model)
        e.ui { browser.selectPrompt(original) }
        e.h.files.onMove = { _, _ in
            let newer = LibraryEntry(path: "b.md", document: other.document, stamp: FileStamp("published-other"))
            e.h.index.acceptSaved(newer, replacing: other)
        }
        e.ui { e.model.rename(to: "renamed.md") }
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("renamed.md"))
        XCTAssertEqual(browser.selection, e.model.state.prompt)
        XCTAssertEqual(browser.selectedEntry?.relativePath, "renamed.md")
    }

    func testDestinationPublicationDuringMoveCannotKeepGhostSourceRow() throws {
        for deletion in [false, true] {
            let e = EditorHarness()
            let original = try e.open(historyCommandSource)
            let before = try e.h.library.load(at: "a.md")
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(original) }
            e.h.files.onRead = { path in
                guard path == "renamed.md" else { return }
                e.h.files.onRead = nil
                if deletion {
                    // Delete just after the final destination stamp probe. The
                    // checked move result predates this newer cache publication.
                    e.h.files.onStamp = { path, _ in
                        e.h.files.onStamp = nil
                        try e.h.files.delete(at: path)
                        let version = e.h.index.editingSnapshot(at: path).version
                        e.h.index.acceptCommand(nil, at: path, expectedVersion: version)
                    }
                } else {
                    let entry = LibraryEntry(path: path, document: before.document,
                        stamp: try XCTUnwrap(e.h.files.stamp(at: path)))
                    let version = e.h.index.editingSnapshot(at: path).version
                    e.h.index.acceptCommand(entry, at: path, expectedVersion: version)
                }
            }
            e.ui { e.model.rename(to: "renamed.md") }
            e.settle()
            XCTAssertFalse(browser.rows.contains { $0.relativePath == RelativePath("a.md") })
            XCTAssertEqual(browser.rows.map(\.relativePath), deletion ? [] : [RelativePath("renamed.md")])
            if deletion { XCTAssertNil(browser.selection) }
            else { XCTAssertEqual(browser.selection, e.model.state.prompt) }
        }
    }

    func testWatcherMovePublicationBeforeRebindCannotCloseMovedEditor() throws {
        for queuedMain in [false, true] {
            for command in [HistoryTestCommand.rename, .move] {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let original = try e.open(historyCommandSource)
                let before = try e.h.library.load(at: "a.md")
                let revision = try historySnapshot(e.h, identity: original.identity)
                let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                    favorites: e.h.library, main: e.h.main, editor: e.model)
                e.ui { browser.selectPrompt(original) }
                e.h.main.releaseAll()
                e.h.files.onRead = { path in
                    guard path == command.destination else { return }
                    e.h.files.onRead = nil
                    let entry = LibraryEntry(path: path, document: before.document,
                        stamp: try XCTUnwrap(e.h.files.stamp(at: path)))
                    let version = e.h.index.editingSnapshot(at: "a.md").version
                    e.h.index.acceptCommand(entry, at: "a.md", expectedVersion: version)
                    // Model the main loop draining the watcher's move while
                    // the worker is still checking the destination bytes.
                    e.h.main.releaseAll()
                }
                var result: PromptCommandOutcome?
                e.ui { command.run(e.model, revision: revision) { result = $0 } }
                e.settle()
                XCTAssertNotNil(result?.committedEntry)
                XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath(command.destination))
                XCTAssertEqual(e.model.state.source, historyCommandSource)
                XCTAssertEqual(browser.selection, e.model.state.prompt)
                XCTAssertNil(e.model.state.conflict)
            }
        }
    }

    func testPostMoveExternalReplacementConflictChoicesUseDestinationWithoutDuplicateID() throws {
        for command in [HistoryTestCommand.rename, .move] {
            for choice in [EditorConflictChoice.keepMine, .takeTheirs] {
                let e = EditorHarness()
                let original = try e.open(historyCommandSource)
                let revision = try historySnapshot(e.h, identity: original.identity)
                let external = historyCommandSource.replacingOccurrences(of: "Original", with: "External")
                e.h.files.onRead = { path in
                    guard path == command.destination else { return }
                    e.h.files.onRead = nil
                    try e.h.files.put(external, at: path)
                }
                e.ui { command.run(e.model, revision: revision) { _ in } }
                e.settle()
                XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath(command.destination))
                XCTAssertEqual(e.model.state.conflict?.kind, .modified)
                XCTAssertEqual(e.model.state.conflict?.theirsSource, external)
                e.ui { e.model.resolveConflict(choice) }
                e.settle()
                XCTAssertNil(try e.h.files.stamp(at: "a.md"))
                XCTAssertEqual(try e.h.files.text(at: command.destination), choice == .keepMine ? historyCommandSource : external)
                let entries = try e.h.library.entries()
                XCTAssertEqual(entries.count, 1)
                XCTAssertEqual(entries.first?.identity, original.identity)
                XCTAssertNil(e.model.state.conflict)
            }
        }
    }

    func testPostMoveDeletionKeepMineRecreatesOnlyDestination() throws {
        for command in [HistoryTestCommand.rename, .move] {
            let e = EditorHarness()
            let original = try e.open(historyCommandSource)
            let revision = try historySnapshot(e.h, identity: original.identity)
            e.h.files.onRead = { path in
                guard path == command.destination else { return }
                e.h.files.onRead = nil
                try e.h.files.delete(at: path)
            }
            e.ui { command.run(e.model, revision: revision) { _ in } }
            e.settle()
            XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath(command.destination))
            XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
            e.ui { e.model.resolveConflict(.keepMine) }
            e.settle()
            XCTAssertNil(try e.h.files.stamp(at: "a.md"))
            XCTAssertEqual(try e.h.files.text(at: command.destination), historyCommandSource)
            XCTAssertEqual(try e.h.library.load(at: command.destination).identity, original.identity)
        }
    }

    func testMoveRemovesStaleSourcePublicationButKeepsRecreatedSource() throws {
        for recreated in [false, true] {
            let e = EditorHarness()
            let original = try e.open(historyCommandSource)
            let before = try e.h.library.load(at: "a.md")
            let browser = LibraryBrowserModel(index: e.h.index, usage: e.h.usage,
                favorites: e.h.library, main: e.h.main, editor: e.model)
            e.ui { browser.selectPrompt(original) }
            e.h.files.onRead = { path in
                guard path == "renamed.md" else { return }
                e.h.files.onRead = nil
                let source: LibraryEntry
                if recreated {
                    try e.h.files.put("Recreated", at: "a.md")
                    source = LibraryEntry(path: "a.md", document: PromptCodec.parse("Recreated", filename: "a.md"),
                        stamp: try XCTUnwrap(e.h.files.stamp(at: "a.md")))
                } else { source = before }
                let version = e.h.index.editingSnapshot(at: "a.md").version
                e.h.index.acceptCommand(source, at: "a.md", expectedVersion: version)
            }
            e.ui { e.model.rename(to: "renamed.md") }
            e.settle()
            XCTAssertEqual(browser.rows.contains { $0.relativePath == RelativePath("a.md") }, recreated)
            XCTAssertEqual(browser.selection, e.model.state.prompt)
            XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("renamed.md"))
            XCTAssertNil(e.model.state.conflict)
        }
    }
}
