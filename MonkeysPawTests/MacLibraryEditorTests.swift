import AppKit
import Carbon.HIToolbox
import Combine
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Release worker jobs explicitly and answer recorded sheets. No regular
/// window has to become key, and no SwiftUI accessibility tree is inspected.
final class MacLibraryEditorTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var delegate: AppDelegate!
    private let work = EditorTestWork()
    private let clipboard = EditorCountingClipboard()
    private var watchers: [EditorTestWatcher] = []
    private var dialogs: [EditorTestDialog] = []
    private var terminationReplies: [Bool] = []
    private var launched: [URL] = []
    private var immediateResponse: LibraryEditorResponse?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        work.drain()
        delegate = nil
        dialogs = []
        watchers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(editorDialog: LibraryWindowController.DialogPresenter? = nil) {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            launchURI: { [weak self] in self?.launched.append($0) }, backgroundWork: work,
            clipboard: clipboard, editorDialog: editorDialog ?? { [weak self] _, dialog, respond in
                let request = EditorTestDialog(dialog: dialog, respond: respond)
                self?.dialogs.append(request)
                if let response = self?.immediateResponse {
                    self?.immediateResponse = nil
                    request.cancelled = true
                    respond(response)
                }
                return { request.cancelled = true }
            }, replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: EditorInlineScheduler(), makeFileWatcher: { [weak self] _, _ in
                let watcher = EditorTestWatcher()
                self?.watchers.append(watcher)
                return watcher
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func put(_ source: String, at path: String = "one.md") throws { try files.write(Data(source.utf8), at: path) }
    private func body(at path: String = "one.md") throws -> String {
        PromptCodec.parseFile(try files.read(at: path), filename: path).body
    }

    private func open(_ source: String = "Original",
                      editorDialog: LibraryWindowController.DialogPresenter? = nil) throws -> LibraryViewState {
        try put(source)
        start(editorDialog: editorDialog)
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.selectPath("one.md")
        XCTAssertEqual(presentation.editorState.status, .loading)
        work.drain()
        XCTAssertEqual(presentation.editorState.source, source)
        return presentation
    }

    private func window() throws -> NSWindow { try XCTUnwrap(delegate.libraryWindow?.window) }
    private func dialog() throws -> EditorTestDialog {
        try XCTUnwrap(dialogs.last { !$0.cancelled })
    }

    private func respond(_ response: LibraryEditorResponse) throws {
        let request = try dialog()
        guard request.dialog.responses.contains(response) else {
            XCTFail("Dialog offered \(request.dialog.responses), expected \(response)")
            return
        }
        request.cancelled = true
        request.respond(response)
    }

    private func externalConflict(_ kind: EditorConflict.Kind, source: String = "Original") throws -> LibraryViewState {
        let presentation = try open(source)
        presentation.edit("Mine")
        if kind == .deleted {
            try files.delete(at: "one.md")
            try XCTUnwrap(watchers.first, "No file watcher was registered")
                .emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
        } else {
            try put("Theirs")
            try XCTUnwrap(watchers.first, "No file watcher was registered")
                .emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        }
        work.drain()
        XCTAssertEqual(presentation.editorState.conflict?.kind, kind)
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { throw EditorTestError.noConflict }
        XCTAssertEqual(conflict.kind, kind)
        return presentation
    }

    func testEditTabsSaveExactCommittedBytesValidationAndClipboardFreePreview() throws {
        let source = "---\nfields:\n  tone: {default: brief}\n---\n{{tone}} {{implicit}} {{date}} {{time}} {{clipboard}}"
        let presentation = try open(source)
        XCTAssertEqual(presentation.editorMode, .edit)
        XCTAssertEqual(presentation.editorState.fields.map(\.name), ["tone", "implicit"])
        XCTAssertTrue(presentation.editorState.preview.contains("brief {implicit}"))
        XCTAssertTrue(presentation.editorState.preview.hasSuffix("{clipboard}"))
        XCTAssertFalse(presentation.editorState.preview.contains("{{date}}"))
        presentation.editorMode = .preview
        presentation.showInspector(.fields)
        presentation.edit("---\ntitle: [broken\n---\nDraft")
        XCTAssertTrue(presentation.editorState.issues.contains { $0.code == .invalidYAML })
        presentation.save()
        work.drain()
        guard case .failed(.invalid) = presentation.editorState.status else { return XCTFail("Expected validation failure") }
        XCTAssertEqual(try body(), "{{tone}} {{implicit}} {{date}} {{time}} {{clipboard}}")
        presentation.edit(source + "\nSaved text")
        presentation.save()
        XCTAssertEqual(presentation.editorState.status, .saving)
        work.drain()
        XCTAssertEqual(presentation.editorState.status, .saved)
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertEqual(try files.read(at: "one.md"), Data(try XCTUnwrap(presentation.editorState.source).utf8))
        XCTAssertEqual(presentation.preview, .rendered(presentation.editorState.preview))
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertEqual(clipboard.writes, 0)
    }

    func testCommandSSavesAndFavouriteChangesTheOpenDraft() throws {
        let presentation = try open()
        presentation.edit("Draft")
        presentation.toggleFavorite()
        guard case .editedBuffer? = presentation.favoriteOutcome else { return XCTFail("Expected a draft favourite") }
        XCTAssertEqual(try body(), "Original")
        XCTAssertTrue(try XCTUnwrap(presentation.editorState.source).contains("favorite: true"))
        try XCTUnwrap(delegate.libraryWindow).saveDocument(nil)
        work.drain()
        XCTAssertEqual(try body(), "Draft")
        XCTAssertTrue(presentation.snapshot.selectedPrompt?.favorite == true)
        XCTAssertNil(presentation.editorState.conflict)
        XCTAssertEqual(clipboard.reads, 0)
    }

    func testEditorIgnoresShortcutsForOtherWindows() throws {
        let presentation = try open()
        presentation.edit("Mine")
        delegate.showSettings()
        let settings = try XCTUnwrap(delegate.settingsWindow?.window)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close(); settings.close() }
        panel.orderFrontRegardless()
        let controller = try XCTUnwrap(delegate.libraryWindow)
        for otherWindow in [settings, panel] {
            for action in [#selector(LibraryWindowController.saveDocument(_:)), #selector(NSWindow.performClose(_:))] {
                let item = NSMenuItem(title: "Library command", action: action, keyEquivalent: "")
                XCTAssertFalse(controller.validateLibraryMenuItem(item, in: otherWindow))
            }
        }
        work.drain()
        XCTAssertEqual(try body(), "Original")
        XCTAssertEqual(presentation.editorState.source, "Mine")
        XCTAssertTrue(try window().isVisible)
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertFalse(dialogs.contains { !$0.cancelled })
    }

    func testLoadingSourceCannotBeEditedOrSaved() throws {
        try put("Original")
        start()
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.selectPath("one.md")
        XCTAssertNotNil(presentation.editorState.prompt)
        XCTAssertNil(presentation.editorState.source)
        XCTAssertFalse(presentation.editorState.canEdit)
        XCTAssertFalse(presentation.canSave)
        presentation.edit("Premature draft")
        presentation.save()
        work.drain()
        XCTAssertEqual(presentation.editorState.source, "Original")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertEqual(try body(), "Original")
    }

    func testCancelledTableSelectionReturnsHighlightToTheOpenPrompt() throws {
        try put("Second", at: "two.md")
        let presentation = try open()
        let list = try XCTUnwrap(delegate.libraryWindow?.promptList)
        let originalIndex = try XCTUnwrap(presentation.snapshot.rows.firstIndex { $0.relativePath == "one.md" })
        let otherIndex = try XCTUnwrap(presentation.snapshot.rows.firstIndex { $0.relativePath == "two.md" })
        presentation.edit("Mine")
        list.tableView.selectRowIndexes(IndexSet(integer: otherIndex), byExtendingSelection: false)
        XCTAssertNotNil(presentation.editorState.pendingDecision)
        try respond(.decision(.cancel))
        XCTAssertEqual(list.tableView.selectedRow, originalIndex)
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertEqual(presentation.editorState.source, "Mine")
    }

    func testPendingDecisionDisablesToolbarFileActions() throws {
        let presentation = try open()
        presentation.edit("Mine")
        try window().close()
        let decision = try XCTUnwrap(presentation.editorState.pendingDecision)
        XCTAssertFalse(presentation.canSave)
        XCTAssertFalse(presentation.canRevert)
        presentation.save()
        presentation.saveAsCopy()
        presentation.revert()
        work.drain()
        XCTAssertEqual(presentation.editorState.pendingDecision, decision)
        XCTAssertTrue(presentation.editorState.queuedActions.isEmpty)
        XCTAssertEqual(try body(), "Original")
        XCTAssertNil(presentation.editorState.lastCopy)
        try respond(.decision(.cancel))
    }

    func testConflictSaveReopensChoicesWithoutWritingAndOtherFileActionsAreDisabled() throws {
        let presentation = try externalConflict(.modified)
        XCTAssertFalse(presentation.canSave)
        XCTAssertFalse(presentation.canRevert)
        presentation.saveAsCopy()
        presentation.revert()
        presentation.save()
        work.drain()
        XCTAssertEqual(try body(), "Theirs")
        XCTAssertNil(presentation.editorState.lastCopy)
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.status, .idle)
        try respond(.dismissConflict)
        presentation.edit("Repaired mine")
        XCTAssertFalse(dialogs.contains { !$0.cancelled })
        presentation.save()
        XCTAssertEqual(presentation.editorState.status, .idle, "Reopening choices must not start a write")
        guard case .conflict = try dialog().dialog else { return XCTFail("Expected conflict choices") }
        XCTAssertEqual(try body(), "Theirs")
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertEqual(try body(), "Repaired mine")
    }

    func testNewExternalChangeRePresentsAnIdenticalDismissedDeletionConflict() throws {
        let presentation = try externalConflict(.deleted)
        let dismissed = try XCTUnwrap(presentation.editorState.conflict)
        try respond(.dismissConflict)
        presentation.edit("Mine plus")
        XCTAssertFalse(dialogs.contains { !$0.cancelled }, "Ordinary typing must preserve the dismissal")
        let count = dialogs.count
        let watcher = try XCTUnwrap(watchers.first)
        // Recreate then delete before the conflict reread finishes. The newly
        // detected deletion has exactly the same value as the dismissed one.
        try put("Recreated")
        watcher.emit(.file(FileStoreEvent(relativePath: "one.md", kind: .created)))
        try files.delete(at: "one.md")
        watcher.emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
        work.drain()
        XCTAssertEqual(presentation.editorState.conflict, dismissed)
        XCTAssertEqual(dialogs.count, count + 1)
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { return XCTFail("Expected new conflict") }
        XCTAssertEqual(conflict, dismissed)
        XCTAssertEqual(presentation.editorState.source, "Mine plus")
    }

    func testDecisionSaveUsesReturnAndCancelUsesEscape() throws {
        let presentation = try open()
        presentation.edit("Mine")
        try window().close()
        let decision = try XCTUnwrap(presentation.editorState.pendingDecision)
        let alert = LibraryWindowController.makeEditorAlert(for: .decision(decision, status: .idle))
        XCTAssertEqual(alert.buttons.map(\.title), [EditorStrings.save, "Cancel", "Don't Save"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}", "d"])
        XCTAssertEqual(alert.buttons[2].keyEquivalentModifierMask, .command)
    }

    func testNativeSaveAndRevertAlertsNameThePromptAndUseMacButtonOrder() throws {
        let presentation = try open("---\ntitle: Visible Title\n---\nOriginal")
        presentation.edit("Draft")
        try window().close()
        let saveDialog = try dialog().dialog
        let save = LibraryWindowController.makeEditorAlert(for: saveDialog)
        XCTAssertEqual(save.messageText, "Do you want to save the changes you made to “Visible Title”?")
        XCTAssertEqual(save.informativeText, "Your changes will be lost if you don't save them.")
        XCTAssertEqual(save.buttons.map(\.title), ["Save", "Cancel", "Don't Save"])
        XCTAssertEqual(save.buttons.map(\.keyEquivalent), ["\r", "\u{1b}", "d"])
        XCTAssertEqual(save.buttons[2].keyEquivalentModifierMask, .command)
        try respond(.decision(.cancel))
        presentation.revert()
        let revertDialog = try dialog().dialog
        let revert = LibraryWindowController.makeEditorAlert(for: revertDialog)
        XCTAssertEqual(revert.messageText, "Revert to the saved version of “Visible Title”?")
        XCTAssertEqual(revert.informativeText, "Your current changes will be lost.")
        XCTAssertEqual(revert.buttons.map(\.title), [EditorStrings.revert, "Cancel"])
        XCTAssertEqual(revert.buttons.map(\.keyEquivalent), ["", "\u{1b}"])
        XCTAssertNil(revert.window.defaultButtonCell)
        XCTAssertFalse(revertDialog.accepts(.decision(.save)))
        try respond(.decision(.cancel))
    }

    func testConflictOverwriteNeverUsesReturn() throws {
        let presentation = try externalConflict(.deleted)
        let conflict = try XCTUnwrap(presentation.editorState.conflict)
        let alert = LibraryWindowController.makeEditorAlert(for: .conflict(conflict, status: .idle, title: presentation.displayTitle))
        XCTAssertEqual(alert.messageText, "“" + presentation.displayTitle + "” was deleted on disk")
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["", "", "", "\u{1b}"])
        XCTAssertNil(alert.window.defaultButtonCell)
    }

    func testNativeDecisionCancelKeepsDraftAndCompletesRequest() throws {
        try assertNativeSheetDismissal(.cancel)
    }

    func testNativeDecisionStopKeepsDraftAndCompletesRequest() throws {
        try assertNativeSheetDismissal(.stop)
    }

    func testNativeConflictCancelKeepsDraftAndCompletesRequest() throws {
        try assertNativeSheetDismissal(.cancel, conflict: .deleted)
    }

    func testNativeConflictStopKeepsDraftAndCompletesRequest() throws {
        try assertNativeSheetDismissal(.stop, conflict: .deleted)
    }

    private func assertNativeSheetDismissal(_ returnCode: NSApplication.ModalResponse,
                                           conflict: EditorConflict.Kind? = nil) throws {
        XCTAssertEqual(NSApplication.ModalResponse.cancel.rawValue, 0)
        XCTAssertEqual(NSApplication.ModalResponse.alertSecondButtonReturn.rawValue, 1001)
        let presentation = try open(editorDialog: LibraryWindowController.presentEditorDialog)
        presentation.edit("Mine")
        if conflict == .deleted {
            try files.delete(at: "one.md")
            try XCTUnwrap(watchers.first).emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
            work.drain()
        }
        let completed = expectation(description: "Dismissal cancels the editor request")
        completed.assertForOverFulfill = true
        var results: [EditorGuardResult] = []
        presentation.editor.request(.rename) { result in
            results.append(result)
            completed.fulfill()
        }
        let window = try window()
        let alertWindow = try XCTUnwrap(window.attachedSheet)
        window.endSheet(alertWindow, returnCode: returnCode)
        wait(for: [completed], timeout: 2)
        work.drain()
        XCTAssertEqual(results, [.cancelled])
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.source, "Mine")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(window.isVisible)
        if let conflict {
            XCTAssertEqual(presentation.editorState.conflict?.kind, conflict)
            XCTAssertNil(try files.stamp(at: "one.md"))
        } else {
            XCTAssertNil(presentation.editorState.conflict)
            XCTAssertEqual(try body(), "Original")
        }
    }

    func testModifiedConflictKeepMine() throws {
        let presentation = try externalConflict(.modified)
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertEqual(try body(), "Mine")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertNil(presentation.editorState.conflict)
    }

    func testModifiedConflictTakeTheirs() throws {
        let presentation = try externalConflict(.modified)
        try respond(.conflict(.takeTheirs))
        work.drain()
        XCTAssertEqual(presentation.editorState.source, "Theirs")
        XCTAssertEqual(try body(), "Theirs")
        XCTAssertFalse(presentation.editorState.isDirty)
    }

    func testModifiedConflictSaveMineAsCopy() throws {
        let presentation = try externalConflict(.modified)
        try respond(.conflict(.saveAsCopy))
        work.drain()
        let copy = try XCTUnwrap(presentation.editorState.lastCopy)
        XCTAssertNotEqual(copy.relativePath, "one.md")
        XCTAssertEqual(try body(at: copy.relativePath.string), "Mine")
        XCTAssertEqual(try body(), "Theirs")
        try XCTUnwrap(watchers.first, "No file watcher was registered")
            .emit(.file(FileStoreEvent(relativePath: copy.relativePath.string, kind: .created)))
        work.drain()
        XCTAssertEqual(presentation.snapshot.selection, copy)
        XCTAssertEqual(presentation.editorState.prompt, copy)
    }

    func testReopeningSavedCopyPreservesFilterAndSection() throws {
        let source = "---\ntitle: Kept title\nfavorite: true\n---\nOriginal"
        let presentation = try open(source)
        presentation.edit(source + " plus")
        presentation.saveAsCopy()
        work.drain()
        let copy = try XCTUnwrap(presentation.editorState.lastCopy)
        try XCTUnwrap(watchers.first, "No file watcher was registered")
            .emit(.file(FileStoreEvent(relativePath: copy.relativePath.string, kind: .created)))
        work.drain()
        XCTAssertEqual(presentation.snapshot.selection, copy)
        presentation.selectSection(.favourites)
        presentation.setFilter("Kept")
        try window().close()
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertNil(presentation.editorState.lastCopy, "Core currently clears lastCopy on close")
        delegate.showLibrary()
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt, copy)
        XCTAssertEqual(presentation.snapshot.filter, "Kept")
        XCTAssertEqual(presentation.snapshot.selectedSection, .favourites)
    }

    func testDeletionConflictKeepMineRecreates() throws {
        let presentation = try externalConflict(.deleted)
        XCTAssertEqual(try dialog().dialog.responses,
            [.conflict(.keepMine), .conflict(.saveAsCopy), .conflict(.discard), .dismissConflict])
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertEqual(try body(), "Mine")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertNil(presentation.editorState.conflict)
    }

    func testDeletionConflictSaveAsCopy() throws {
        let presentation = try externalConflict(.deleted,
            source: "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal")
        let original = try XCTUnwrap(presentation.editorState.prompt)
        XCTAssertNil(try files.stamp(at: "one.md"))
        try respond(.conflict(.saveAsCopy))
        work.drain()
        let copy = try XCTUnwrap(presentation.editorState.lastCopy)
        // A copy takes an alternate name and never recreates the deleted original.
        XCTAssertNotEqual(copy.identity, original.identity)
        XCTAssertNotEqual(copy.relativePath, original.relativePath)
        XCTAssertNil(try files.stamp(at: "one.md"))
        XCTAssertEqual(try body(at: copy.relativePath.string), "Mine")
        XCTAssertEqual(try files.stamp(at: copy.relativePath.string), presentation.editorState.stamp)
        XCTAssertEqual(presentation.editorState.prompt, copy)
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertNil(presentation.editorState.conflict)
    }

    func testDeletionConflictDiscardClosesDraft() throws {
        let presentation = try externalConflict(.deleted)
        XCTAssertNil(presentation.snapshot.selection)
        XCTAssertEqual(presentation.editorState.source, "Mine", "A deleted row must not hide the draft")
        try respond(.conflict(.discard))
        work.drain()
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertNil(try files.stamp(at: "one.md"))
    }

    func testSelectionCancelThenSaveKeepsRowAndCommitsBeforeOpeningNextPrompt() throws {
        try put("Second", at: "two.md")
        let presentation = try open()
        presentation.edit("Mine")
        presentation.selectPath("two.md")
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md")
        try respond(.decision(.cancel))
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md")
        XCTAssertEqual(presentation.editorState.source, "Mine")
        presentation.selectPath("two.md")
        try respond(.decision(.save))
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md")
        work.drain()
        XCTAssertEqual(try body(), "Mine")
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "two.md")
        XCTAssertEqual(presentation.editorState.source, "Second")
    }

    func testNativeCloseCancelAndDiscardAndCloseDuringSave() throws {
        let presentation = try open()
        let window = try window()
        presentation.edit("Mine")
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        try respond(.decision(.cancel))
        XCTAssertTrue(window.isVisible)
        window.close() // Programmatic close uses the same guard as the close button.
        try respond(.decision(.discard))
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md", "Reopening retains the browser's selection")
        XCTAssertEqual(try body(), "Original")
        delegate.showLibrary()
        presentation.selectPath("one.md")
        work.drain()
        presentation.edit("Saved before close")
        presentation.save()
        window.close()
        XCTAssertTrue(window.isVisible)
        work.drain()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(try body(), "Saved before close")
    }

    func testUnavailableLibraryDoesNotAutoOpenOrSelectCachedRows() throws {
        try put("Second", at: "two.md")
        let presentation = try open()
        let target = try XCTUnwrap(presentation.snapshot.rows.first { $0.relativePath == "two.md" }?.selection)
        try window().close()
        presentation.setLibraryAvailable(false)
        presentation.didShow()
        presentation.selectPath("two.md")
        presentation.moveSelection(.down)
        presentation.openPrompt(target)
        presentation.setFilter("one")
        work.drain()
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertEqual(presentation.editorState.status, .idle)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md")
        presentation.setLibraryAvailable(true)
        presentation.didShow()
        work.drain()
        XCTAssertEqual(presentation.editorState.source, "Original")
    }

    func testDeletedPromptDoesNotAutoReopenFromStaleBrowserUpdates() throws {
        let presentation = try open()
        // A reread can discover deletion before the watcher updates the index.
        try files.delete(at: "one.md")
        presentation.revert()
        work.drain()
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "one.md")
        presentation.setFilter("one")
        XCTAssertNil(presentation.editorState.prompt, "A browser publication must not reopen the deleted prompt")
        presentation.editor.request(.rename)
        XCTAssertNil(presentation.editorState.prompt, "An editor publication must not reopen the deleted prompt")
        work.drain()
        XCTAssertEqual(presentation.editorState.status, .idle)
        try put("Restored")
        delegate.showLibrary()
        work.drain()
        XCTAssertEqual(presentation.editorState.source, "Restored", "A fresh presentation can retry the retained selection")
    }

    func testRevertDiscardAndFailedDecisionSavePreserveTheGuard() throws {
        let presentation = try open()
        presentation.edit("Mine")
        presentation.revert()
        try respond(.decision(.discard))
        work.drain()
        XCTAssertEqual(presentation.editorState.source, "Original")
        presentation.edit("---\ntitle: [broken\n---\nMine")
        try window().close()
        try respond(.decision(.save))
        work.drain()
        XCTAssertTrue(try window().isVisible)
        guard case .failed(.invalid) = presentation.editorState.status else { return XCTFail("Expected failed save") }
        XCTAssertNotNil(presentation.editorState.pendingDecision)
        try respond(.decision(.cancel))
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertTrue(presentation.editorState.isDirty)
    }

    func testVisibilityRestorationShowsAnAlreadyPublishedConflict() throws {
        let presentation = try open()
        presentation.edit("Mine")
        let window = try window()
        window.orderOut(nil) // Simulate hidden/minimized visibility without key-window waits.
        try put("Theirs")
        try XCTUnwrap(watchers.first, "No file watcher was registered")
            .emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        work.drain()
        XCTAssertEqual(presentation.editorState.conflict?.kind, .modified)
        XCTAssertFalse(dialogs.contains { !$0.cancelled })
        window.orderFrontRegardless()
        try XCTUnwrap(delegate.libraryWindow).windowDidDeminiaturize(
            Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { return XCTFail("Expected restored sheet") }
        XCTAssertEqual(conflict.kind, .modified)
    }

    func testAppUnhideRetriesAnAlreadyPendingCloseDecision() throws {
        let presentation = try open()
        presentation.edit("Mine")
        let window = try window()
        window.orderOut(nil)
        try XCTUnwrap(delegate.libraryWindow).requestClose()
        XCTAssertNotNil(presentation.editorState.pendingDecision)
        XCTAssertFalse(dialogs.contains { !$0.cancelled })
        window.orderFrontRegardless()
        delegate.applicationDidUnhide(Notification(name: NSApplication.didUnhideNotification))
        guard case .decision(let decision, _, _) = try dialog().dialog else { return XCTFail("Expected restored decision") }
        XCTAssertEqual(decision.action, .close)
        try respond(.decision(.cancel))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(presentation.editorState.isDirty)
    }

    func testPickerRevealUpgradesAnIdenticalPendingOpenWithoutDuplicatingTheDecision() throws {
        try put("Second", at: "two.md")
        let presentation = try open()
        let target = try XCTUnwrap(presentation.snapshot.rows.first { $0.relativePath == "two.md" }?.selection)
        presentation.edit("Mine")
        presentation.selectPath("two.md")
        let token = presentation.editorState.pendingDecision?.id
        presentation.setFilter("one")
        presentation.openPrompt(target)
        XCTAssertEqual(presentation.editorState.pendingDecision?.id, token)
        XCTAssertTrue(presentation.editorState.queuedActions.isEmpty)
        try respond(.decision(.discard))
        work.drain()
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(presentation.snapshot.selectedSection, .all)
        XCTAssertEqual(presentation.snapshot.selection, target)
        XCTAssertEqual(presentation.editorState.source, "Second")
    }

    func testFailedConflictSaveCanBeCancelledToRepairTheDraft() throws {
        let presentation = try open()
        presentation.edit("---\ntitle: [broken\n---\nMine")
        try put("Theirs")
        try XCTUnwrap(watchers.first, "No file watcher was registered")
            .emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        work.drain()
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertTrue(try dialog().dialog.message.contains("Fix the validation errors"))
        try respond(.dismissConflict)
        XCTAssertNotNil(presentation.editorState.conflict)
        XCTAssertTrue(presentation.editorState.isDirty)
        presentation.edit("Fixed mine")
        XCTAssertFalse(dialogs.contains { !$0.cancelled }, "Repairing the source must not reopen a modal on each keystroke")
        presentation.save()
        work.drain()
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertEqual(try body(), "Fixed mine")
        XCTAssertNil(presentation.editorState.conflict)
    }

    func testCommandWUsesTheCloseGuardAndReopeningRetiresNativeInputAtTheSamePath() throws {
        let presentation = try open()
        presentation.edit("Mine")
        let beforeClose = presentation.sourceRevision
        try XCTUnwrap(delegate.libraryWindow).requestClose()
        try respond(.decision(.discard))
        XCTAssertGreaterThan(presentation.sourceRevision, beforeClose)
        delegate.showLibrary()
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertGreaterThan(presentation.sourceRevision, beforeClose)
        XCTAssertEqual(presentation.editorState.source, "Original")
    }

    func testModelDrivenSaveRewriteRetainsNativeUndoHistory() throws {
        XCTAssertTrue(Thread.isMainThread)
        let presentation = try open()
        let coordinator = LibrarySourceEditor.Coordinator(onEdit: presentation.edit)
        let scroll = LibrarySourceEditor.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LibrarySourceTextView)
        scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        try window().contentView?.addSubview(scroll)
        defer { scroll.removeFromSuperview(); coordinator.deactivate() }
        coordinator.update(text, source: "Original", path: "one.md", revision: presentation.sourceRevision,
            isEditable: true, onEdit: presentation.edit)
        XCTAssertTrue(try window().makeFirstResponder(text))
        let undo = try XCTUnwrap(text.undoManager)
        // Separate the two native events explicitly; hosted tests do not need
        // a run-loop/key-window wait merely to close automatic undo groups.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" plus", replacementRange: NSRange(location: 8, length: 0))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(text.string, "Original plus")
        // Replacing an explicit range does not establish the body caret for this test.
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        presentation.save()
        work.drain()
        let saved = try XCTUnwrap(presentation.editorState.source)
        undo.beginUndoGrouping()
        coordinator.update(text, source: saved, path: "one.md", revision: presentation.sourceRevision,
            isEditable: true, onEdit: presentation.edit)
        undo.endUndoGrouping()
        XCTAssertEqual(text.string, saved)
        XCTAssertEqual(presentation.editorState.source, saved)
        XCTAssertFalse(presentation.editorState.isDirty, "A model-driven rewrite must not republish a draft")
        XCTAssertEqual(text.selectedRange(), NSRange(location: (saved as NSString).length, length: 0),
            "The injected header must not move the body caret into YAML")
        XCTAssertTrue(undo.canUndo)
        // UndoManager publishes didUndo/didRedo synchronously, so the native
        // text, model source and dirty state must agree before the call returns.
        undo.undo()
        XCTAssertEqual(text.string, "Original plus", "Undo first removes the model-driven normalization")
        XCTAssertEqual(presentation.editorState.source, "Original plus")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canUndo, "The earlier native typing action remains undoable")
        undo.undo()
        XCTAssertEqual(text.string, "Original")
        XCTAssertEqual(presentation.editorState.source, "Original")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(text.string, "Original plus")
        XCTAssertEqual(presentation.editorState.source, "Original plus")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(text.string, saved)
        XCTAssertEqual(presentation.editorState.source, saved)
        XCTAssertFalse(presentation.editorState.isDirty)
    }

    func testQuitWithOnlyQueuedActionsRepliesAfterTheyDrain() throws {
        let presentation = try open()
        let editor = try XCTUnwrap(delegate.editorModel)
        presentation.edit("Mine")
        presentation.save()
        var completed: [EditorDiscardAction] = []
        editor.request(.rename) { result in
            XCTAssertEqual(result, .allowed)
            completed.append(.rename)
            // At this point queuedActions alone must defer termination.
            XCTAssertFalse(editor.state.isDirty)
            XCTAssertEqual(editor.state.status, .saved)
            XCTAssertNil(editor.state.pendingDecision)
            XCTAssertEqual(editor.state.queuedActions, [.move])
            XCTAssertEqual(self.delegate.applicationShouldTerminate(NSApp), .terminateLater)
            XCTAssertTrue(self.terminationReplies.isEmpty)
        }
        editor.request(.move) { result in
            XCTAssertEqual(result, .allowed)
            completed.append(.move)
        }
        XCTAssertEqual(editor.state.queuedActions, [.rename, .move])
        work.drain()
        XCTAssertEqual(completed, [.rename, .move])
        XCTAssertTrue(editor.state.queuedActions.isEmpty)
        XCTAssertTrue(terminationReplies.isEmpty)
        drainTerminationReply()
        XCTAssertEqual(terminationReplies, [true])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testQuitCancelThenSaveUsesTerminateLaterAndRepliesAfterSave() throws {
        let presentation = try open()
        presentation.edit("Mine")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertEqual(presentation.editorState.pendingDecision?.action, .quit)
        try respond(.decision(.cancel))
        drainTerminationReply()
        XCTAssertEqual(terminationReplies, [false])
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        try respond(.decision(.save))
        XCTAssertEqual(terminationReplies, [false])
        work.drain()
        drainTerminationReply()
        XCTAssertEqual(terminationReplies, [false, true])
        XCTAssertEqual(try body(), "Mine")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testQuitDiscardDoesNotWriteAndInlineDialogResponseDefersTheReply() throws {
        let presentation = try open()
        presentation.edit("Mine")
        immediateResponse = .decision(.discard)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertTrue(terminationReplies.isEmpty, "Even an inline sheet answer must wait until terminateLater is returned")
        drainTerminationReply()
        XCTAssertEqual(terminationReplies, [true])
        XCTAssertEqual(try body(), "Original")
    }

    func testExternalRenameKeepsTheSelectedIdentityAndOpensItsNewPath() throws {
        let source = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: One\n---\nOriginal"
        let presentation = try open(source)
        let identity = presentation.snapshot.selection?.identity
        try files.move(from: "one.md", to: "renamed.md")
        let watcher = try XCTUnwrap(watchers.first, "No file watcher was registered")
        watcher.emit(.file(FileStoreEvent(relativePath: "renamed.md", kind: .created)))
        watcher.emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
        work.drain()
        XCTAssertEqual(presentation.snapshot.selection?.identity, identity)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.editorState.source, source)
    }

    private func drainTerminationReply() {
        let drained = expectation(description: "AppKit deferred termination reply")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testSettingsRefusesDirtyAndSavingLibrarySwitchesAndRetiresPendingOldLoads() throws {
        let presentation = try open()
        let other = directory.appendingPathComponent("other", isDirectory: true)
        let otherFiles = try RootedFileStore(root: other)
        try otherFiles.write(Data("Other".utf8), at: "other.md")
        presentation.edit("Mine")
        try XCTUnwrap(delegate.generalSettingsModel).chooseFolder(other.path)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsWindow?.presentation).generalMessages.contains(EditorStrings.librarySwitchRefused))
        XCTAssertEqual(delegate.switchLibrary(to: other), .editorBusy)
        presentation.save()
        XCTAssertEqual(delegate.switchLibrary(to: other), .editorBusy)
        work.drain()
        let staleEditor = try XCTUnwrap(delegate.editorModel)
        presentation.revert() // Queue a read against the old graph.
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        work.drain()
        XCTAssertEqual(presentation.activeLibraryPath, other.path)
        XCTAssertNil(presentation.editorState.prompt)
        staleEditor.edit("Late")
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertEqual(try body(), "Mine")
    }

    func testSettingsRefusalMessageClearsAndPublishesAfterSavingTheDraft() throws {
        let presentation = try open()
        defer { delegate.settingsWindow?.window?.close() }
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try RootedFileStore(root: other).write(Data("Other".utf8), at: "other.md")
        presentation.edit("Mine")
        try XCTUnwrap(delegate.generalSettingsModel).chooseFolder(other.path)
        let settings = try XCTUnwrap(delegate.settingsWindow?.presentation)
        XCTAssertEqual(settings.generalMessages, [EditorStrings.librarySwitchRefused])
        var publications = 0
        let subscription = settings.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        presentation.save()
        let whileSaving = publications
        work.drain()
        XCTAssertGreaterThan(publications, whileSaving, "An already-open Settings view must refresh on resolution")
        XCTAssertNil(settings.librarySwitchMessage?())
        XCTAssertTrue(settings.generalMessages.isEmpty, "A resolved editor refusal must not become a delivery warning")
        delegate.showSettings()
        XCTAssertTrue(settings.generalMessages.isEmpty)
        XCTAssertEqual(delegate.libraryDirectory, root)
    }

    func testPickerEditAndNoMatchCreateRevealEditorEvenWithAHiddenRow() throws {
        let presentation = try open()
        presentation.setFilter("no such row")
        presentation.selectSection(.favourites)
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.editSelected()
        work.drain()
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(presentation.snapshot.selectedSection, .all)
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertEqual(picker.state, .closed)
        picker.open()
        picker.setQuery("Brand new prompt")
        try XCTUnwrap(delegate.pickerPresentation).createNoMatch()
        work.drain()
        let path = try XCTUnwrap(presentation.editorState.prompt?.relativePath.string)
        XCTAssertNotEqual(path, "one.md")
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: path), filename: path).frontMatter.title, "Brand new prompt")
        XCTAssertEqual(presentation.editorMode, .edit)
        XCTAssertTrue(try window().isVisible)
        XCTAssertTrue(launched.isEmpty)
    }

    func testReadOnlySourcesCannotBeEditedOrSaved() throws {
        try files.write(Data([0xff]), at: "encoding.md")
        try files.write(Data(repeating: 65, count: Limits.maxPromptBytes + 1), at: "large.md")
        try put("---\nformat: 2\n---\nFuture", at: "future.md")
        start()
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        for path in ["encoding.md", "large.md", "future.md"] {
            presentation.selectPath(RelativePath(path))
            work.drain()
            let bytes = try files.read(at: path)
            let paths = try files.listFiles().map(\.relativePath).sorted()
            let source = presentation.editorState.source
            let reason = try XCTUnwrap(presentation.editorState.readOnlyReason)
            XCTAssertFalse(EditorStrings.readOnly(reason).isEmpty)
            XCTAssertFalse(presentation.editorState.canEdit)
            XCTAssertFalse(presentation.canSave)
            presentation.edit("Overwrite")
            presentation.save()
            presentation.saveAsCopy()
            work.drain()
            XCTAssertEqual(presentation.editorState.source, source)
            XCTAssertEqual(try files.read(at: path), bytes)
            XCTAssertEqual(presentation.editorState.prompt?.relativePath, RelativePath(path))
            XCTAssertNil(presentation.editorState.lastCopy)
            XCTAssertEqual(try files.listFiles().map(\.relativePath).sorted(), paths)
        }
        XCTAssertEqual(clipboard.reads, 0)
    }

    func testRetiredDialogAndQueuedPublicationsCannotChangeTheNewGraph() throws {
        let presentation = try open()
        presentation.edit("Mine")
        try window().close()
        let stale = try dialog()
        try respond(.decision(.cancel))
        presentation.edit("Original")
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try RootedFileStore(root: other).write(Data("Other".utf8), at: "other.md")
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        stale.respond(.decision(.discard))
        XCTAssertTrue(try window().isVisible)
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertEqual(presentation.activeLibraryPath, other.path)
    }

    func testNativeSourceEditorUndoAndMarkedTextSurviveStateRefreshes() throws {
        XCTAssertTrue(Thread.isMainThread)
        let presentation = try open()
        let coordinator = LibrarySourceEditor.Coordinator(onEdit: presentation.edit)
        let scroll = LibrarySourceEditor.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LibrarySourceTextView)
        scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        try window().contentView?.addSubview(scroll)
        defer { text.unmarkText(); scroll.removeFromSuperview(); coordinator.deactivate() }
        coordinator.update(text, source: "Original", path: "one.md", isEditable: true, onEdit: presentation.edit)
        XCTAssertTrue(text.allowsUndo)
        XCTAssertFalse(text.isRichText)
        XCTAssertFalse(text.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertTrue(try window().makeFirstResponder(text))
        let undo = try XCTUnwrap(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" plus", replacementRange: NSRange(location: 8, length: 0))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(presentation.editorState.source, "Original plus")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(text.string, "Original")
        XCTAssertEqual(presentation.editorState.source, "Original")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(text.string, "Original plus")
        XCTAssertEqual(presentation.editorState.source, "Original plus")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(text.string, "Original")
        XCTAssertEqual(presentation.editorState.source, "Original")
        XCTAssertFalse(presentation.editorState.isDirty)
        undo.groupsByEvent = true
        text.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 8, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        let marked = text.string
        XCTAssertEqual(presentation.editorState.source, marked, "The dirty guard sees composition before it is committed")
        XCTAssertTrue(presentation.editorState.isDirty)
        coordinator.update(text, source: "A stale publication", path: "one.md", isEditable: true, onEdit: presentation.edit)
        XCTAssertEqual(text.string, marked)
        XCTAssertTrue(text.hasMarkedText())
        text.unmarkText()
        XCTAssertEqual(presentation.editorState.source, marked)
        XCTAssertTrue(presentation.editorState.isDirty)
        // Rebinding a library may keep the same relative path. It still retires
        // the input session, and must never send its old composition to the new one.
        text.setMarkedText("旧", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: (marked as NSString).length, length: 0))
        var replacementEdits: [String] = []
        coordinator.update(text, source: "New library", path: "one.md", revision: 1,
            isEditable: true, onEdit: { replacementEdits.append($0) })
        XCTAssertFalse(text.hasMarkedText())
        XCTAssertEqual(text.string, "New library")
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        XCTAssertTrue(replacementEdits.isEmpty)
        coordinator.deactivate()
        text.insertText(" retired", replacementRange: NSRange(location: 11, length: 0))
        XCTAssertTrue(replacementEdits.isEmpty)
    }
}

private enum EditorTestError: Error { case noConflict }

private final class EditorTestDialog {
    let dialog: LibraryEditorDialog
    let respond: (LibraryEditorResponse) -> Void
    var cancelled = false
    init(dialog: LibraryEditorDialog, respond: @escaping (LibraryEditorResponse) -> Void) {
        self.dialog = dialog
        self.respond = respond
    }
}

private final class EditorTestWork: BackgroundWork {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        for _ in 0..<100 {
            guard !pending.isEmpty else { return }
            pending.removeFirst()()
        }
        XCTFail("Editor worker did not settle in 100 jobs")
    }
}

private struct EditorInlineScheduler: MonkeysPawCore.Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) { work() }
}

private final class EditorTestWatcher: FileStoreWatcher {
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { self.onEvent = onEvent }
    func stop() {} // Keep late callbacks to exercise graph retirement.
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}

private final class EditorCountingClipboard: Clipboard {
    private(set) var reads = 0
    private(set) var writes = 0
    func writeText(_ text: String) { writes += 1 }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { reads += 1; completion(nil) }
}
