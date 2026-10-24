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
        guard request.dialog.accepts(response) else {
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

    func testFormPropertiesAndSourceUseOneUnsavedDraft() throws {
        let source = "---\ntitle: Old\nname: custom-name\nfields:\n  topic: {default: Earth, hint: keep}\n---\nHello {{topic}}"
        let presentation = try open(source)
        XCTAssertEqual(presentation.editorMode, .edit)
        XCTAssertEqual(presentation.editorState.form?.title, "Old")
        XCTAssertEqual(presentation.editorState.form?.body, "Hello {{topic}}")
        presentation.edit(.title("New title"))
        presentation.edit(.description("A summary"))
        presentation.edit(.tags(["code, review", "writing"]))
        presentation.edit(.isPrivate(true))
        presentation.edit(.body("  Draft {{topic}}\r\n"))
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertTrue(presentation.editorState.isPrivate)
        XCTAssertEqual(try files.read(at: "one.md"), Data(source.utf8))
        let draft = presentation.editorState.source
        presentation.editorMode = .source
        presentation.editorMode = .preview
        presentation.editorMode = .edit
        XCTAssertEqual(presentation.editorState.source, draft, "Mode changes do not serialize or save")
        presentation.save()
        work.drain()
        let saved = PromptCodec.parseFile(try files.read(at: "one.md"), filename: "one.md")
        XCTAssertEqual(saved.frontMatter.title, "New title")
        XCTAssertEqual(saved.frontMatter.description, "A summary")
        XCTAssertEqual(saved.frontMatter.tags, ["code, review", "writing"])
        XCTAssertTrue(saved.frontMatter.isPrivate)
        XCTAssertEqual(Data(saved.body.utf8), Data("  Draft {{topic}}\r\n".utf8))
        XCTAssertTrue(saved.source.contains("name: custom-name"))
        XCTAssertTrue(saved.source.contains("hint: keep"))
        XCTAssertFalse(presentation.editorState.isDirty)
        presentation.edit("---\ntitle: From source\n---\nBody from source")
        XCTAssertEqual(presentation.editorState.form?.title, "From source")
        XCTAssertEqual(presentation.editorState.form?.body, "Body from source")
    }

    func testRenderedEditorShowsBodyByDefaultAndSourceOnRequest() throws {
        let source = "---\ntitle: Title\n---\nBody {{topic}}"
        let presentation = try open(source)
        let native = try window()
        let body = try waitForNativeEditor("library-body", in: native)
        let raw = try waitForNativeEditor("library-source", in: native)
        XCTAssertEqual(body.string, "Body {{topic}}")
        XCTAssertFalse(body.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(raw.isHiddenOrHasHiddenAncestor)
        presentation.toggleDetails()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let title = try nativeProperty("library-prompt-title", in: native)
        let description = try nativeProperty("library-prompt-description", in: native)
        XCTAssertEqual(title.stringValue, "Title")
        for (field, value) in [(title, "GUI title"), (description, "GUI summary")] {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        XCTAssertEqual(presentation.editorState.form?.title, "GUI title")
        XCTAssertEqual(presentation.editorState.form?.description, "GUI summary")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(try files.read(at: "one.md"), Data(source.utf8))
        let draft = try XCTUnwrap(presentation.editorState.source)
        XCTAssertTrue(native.makeFirstResponder(body))
        presentation.editorMode = .source
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(body.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(raw.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(raw.string, draft)
        XCTAssertFalse(native.firstResponder === body, "A hidden editor must release keyboard ownership")
        XCTAssertTrue(presentation.editorState.isDirty)
        presentation.edit("---\ntitle: [broken\n---\nExact invalid draft")
        presentation.editorMode = .edit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNil(presentation.editorState.form)
        XCTAssertFalse(raw.isHiddenOrHasHiddenAncestor, "Invalid properties retain the editable source fallback")
        XCTAssertEqual(raw.string, "---\ntitle: [broken\n---\nExact invalid draft")
    }

    private func waitForNativeEditor(_ identifier: String, in window: NSWindow) throws -> LibrarySourceTextView {
        func find(_ view: NSView) -> LibrarySourceTextView? {
            if let text = view as? LibrarySourceTextView, text.accessibilityIdentifier() == identifier { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if let root = window.contentView, let text = find(root) { return text }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return try XCTUnwrap(window.contentView.flatMap(find), "Missing native editor: " + identifier)
    }

    private func nativeProperty(_ identifier: String, in window: NSWindow) throws -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == identifier { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.contentView.flatMap(find), "Missing property control: " + identifier)
    }

    func testSearchReturnFocusesTheFirstResultAfterItsAsynchronousLoad() throws {
        try put("---\ntitle: Alpha\n---\nBody")
        start()
        delegate.showLibrary()
        let controller = try XCTUnwrap(delegate.libraryWindow)
        let input = try LibrarySearchTestSupport.type("Alpha", in: controller)
        XCTAssertNil(controller.presentation.editorState.prompt)
        XCTAssertTrue(controller.control(input.field, textView: input.editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(controller.presentation.editorState.status, .loading)
        work.drain()
        let native = try window()
        let text = try waitForNativeEditor("library-body", in: native)
        let deadline = Date(timeIntervalSinceNow: 2)
        while native.firstResponder !== text, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(native.firstResponder === text, "One Return must focus the loaded result")
        XCTAssertEqual(controller.presentation.editorState.form?.body, "Body")
    }

    func testAsynchronousLoadEstablishesBothNativeUndoBaselines() throws {
        let source = "---\ntitle: Note\n---\nBody"
        try put(source)
        start()
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.selectPath("one.md")
        let native = try window()
        let raw = try waitForNativeEditor("library-source", in: native)
        let body = try waitForNativeEditor("library-body", in: native)
        XCTAssertEqual(raw.string, "")
        XCTAssertFalse(raw.isEditable)
        work.drain()
        let deadline = Date(timeIntervalSinceNow: 2)
        while (raw.string != source || body.string != "Body"), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(raw.string, source)
        XCTAssertEqual(body.string, "Body")
        XCTAssertFalse(raw.undoManager?.canUndo ?? true, "Loading a file is not a source edit")
        XCTAssertFalse(body.undoManager?.canUndo ?? true, "Loading a file is not a body edit")
        XCTAssertFalse(presentation.editorState.isDirty)
    }

    func testSearchReturnWaitsForTheSaveBeforeOpeningAndFocusingItsResult() throws {
        try put("---\ntitle: Beta\n---\nSecond", at: "two.md")
        let presentation = try open("---\ntitle: Alpha\n---\nOriginal")
        presentation.edit("Saved before navigation")
        presentation.save()
        XCTAssertEqual(presentation.editorState.status, .saving)
        let controller = try XCTUnwrap(delegate.libraryWindow)
        let input = try LibrarySearchTestSupport.type("Beta", in: controller)
        XCTAssertEqual(presentation.snapshot.rows.map(\.relativePath), ["two.md"])
        XCTAssertTrue(controller.control(input.field, textView: input.editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertTrue(try window().firstResponder === input.editor)
        work.drain()
        let native = try window()
        let text = try waitForNativeEditor("library-body", in: native)
        let deadline = Date(timeIntervalSinceNow: 2)
        while (native.firstResponder !== text || text.string != "Second"), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(try body(), "Saved before navigation")
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "two.md")
        XCTAssertEqual(text.string, "Second")
        XCTAssertTrue(native.firstResponder === text, "One Return must survive the in-flight save")
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
        let search = try LibrarySearchTestSupport.type("Kept", in: XCTUnwrap(delegate.libraryWindow))
        try window().close()
        XCTAssertEqual(presentation.snapshot.filter, "Kept", "Closing retains the browser query")
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertNil(presentation.editorState.lastCopy, "Core currently clears lastCopy on close")
        delegate.showLibrary()
        XCTAssertEqual(presentation.snapshot.filter, "Kept", "Showing retains the browser query")
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt, copy)
        XCTAssertEqual(presentation.snapshot.filter, "Kept")
        XCTAssertEqual(presentation.snapshot.selectedSection, .favourites)
        XCTAssertEqual(search.field.stringValue, "Kept")
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
        guard case .decision(let decision, _, _, _) = try dialog().dialog else { return XCTFail("Expected restored decision") }
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
        let search = try LibrarySearchTestSupport.type("no such row", in: XCTUnwrap(delegate.libraryWindow))
        presentation.selectSection(.favourites)
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.editSelected()
        work.drain()
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(search.field.stringValue, "")
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

    func testLibraryNewPromptInFolderOpensSelectedEditAndKeepsWindowFocus() throws {
        try put("Original", at: "Folder/one.md")
        start()
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.selectPath("Folder/one.md")
        work.drain()
        presentation.selectSection(.folder("Folder"))
        let search = try LibrarySearchTestSupport.type("no matching prompt", in: XCTUnwrap(delegate.libraryWindow))
        presentation.editorMode = .preview
        let native = try window()
        let focusRevision = presentation.focusRevision
        let editorFocus = presentation.editorFocusRevision
        XCTAssertTrue(presentation.canCreatePrompt)
        presentation.requestNewPrompt()
        guard case .newPrompt(let request) = try dialog().dialog else { return XCTFail("Expected title sheet") }
        XCTAssertEqual(request.folder, "Folder")
        XCTAssertEqual(try dialog().dialog.message, "Creates the prompt in Folder.")
        XCTAssertFalse(presentation.canCreatePrompt)
        try respond(.createPrompt("Title"))
        work.drain()
        let document = PromptCodec.parseFile(try files.read(at: "Folder/Title.md"), filename: "Title.md")
        XCTAssertEqual(document.frontMatter.title, "Title")
        XCTAssertEqual(document.body, Strings.newPromptBody)
        XCTAssertNotNil(document.frontMatter.id)
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "Folder/Title.md")
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertTrue(presentation.snapshot.rows.contains { $0.relativePath == "Folder/Title.md" })
        XCTAssertEqual(presentation.snapshot.selectedSection, .folder("Folder"))
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(search.field.stringValue, "")
        XCTAssertEqual(presentation.editorMode, .edit)
        XCTAssertEqual(presentation.focusRevision, focusRevision, "Creation never moves focus to Search")
        XCTAssertGreaterThan(presentation.editorFocusRevision, editorFocus, "The new prompt's editor takes focus")
        XCTAssertTrue(try window() === native)
        XCTAssertTrue(native.isVisible)
        XCTAssertTrue(launched.isEmpty)
    }

    func testLibraryNewPromptTitleCancelDoesNotAskGuardOrWrite() throws {
        let presentation = try open()
        presentation.edit("Draft")
        let paths = try files.listFiles().map(\.relativePath).sorted()
        presentation.requestNewPrompt()
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertEqual(try dialog().dialog.message, "Creates the prompt in the library root.")
        try respond(.cancelFileCommand)
        work.drain()
        XCTAssertNil(presentation.newPromptRequest)
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.source, "Draft")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(try files.listFiles().map(\.relativePath).sorted(), paths)
    }

    func testLibraryNewPromptGuardCancelPreservesDirtyDraftAndWritesNothing() throws {
        let presentation = try open()
        presentation.edit("Draft")
        presentation.requestNewPrompt()
        XCTAssertNil(presentation.editorState.pendingDecision)
        try respond(.createPrompt("Cancelled"))
        XCTAssertEqual(presentation.editorState.pendingDecision?.action, .create)
        XCTAssertFalse(presentation.canCreatePrompt)
        XCTAssertNil(try files.stamp(at: "Cancelled.md"))
        try respond(.decision(.cancel))
        work.drain()
        XCTAssertNil(try files.stamp(at: "Cancelled.md"))
        XCTAssertEqual(try body(), "Original")
        XCTAssertEqual(presentation.editorState.source, "Draft")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
    }

    func testLibraryNewPromptSaveAndDiscardCompleteBeforeCreation() throws {
        let presentation = try open()
        for choice in [EditorDecision.save, .discard] {
            let oldPath = try XCTUnwrap(presentation.editorState.prompt?.relativePath.string)
            let before = try files.read(at: oldPath)
            presentation.edit("Draft")
            presentation.requestNewPrompt()
            let title = choice == .save ? "After save" : "After discard"
            try respond(.createPrompt(title))
            XCTAssertEqual(presentation.editorState.pendingDecision?.action, .create)
            try respond(.decision(choice))
            work.drain()
            if choice == .save { XCTAssertEqual(try body(at: oldPath), "Draft") }
            else { XCTAssertEqual(try files.read(at: oldPath), before) }
            XCTAssertEqual(presentation.editorState.prompt?.relativePath.string, title + ".md")
            XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
            XCTAssertEqual(presentation.editorMode, .edit)
            XCTAssertFalse(presentation.editorState.isDirty)
        }
    }

    func testLibraryNewPromptDefaultsCollisionExactTitleAndHiddenSectionReveal() throws {
        let presentation = try open()
        for (index, input) in ["", " \t\n", "  Exact/title  "].enumerated() {
            presentation.selectSection(.favourites)
            presentation.setFilter("hidden")
            presentation.requestNewPrompt()
            try respond(.createPrompt(input))
            work.drain()
            let path = ["New prompt.md", "New prompt 2.md", "Exact title.md"][index]
            let document = PromptCodec.parseFile(try files.read(at: path), filename: path)
            XCTAssertEqual(document.frontMatter.title, index < 2 ? LibraryStrings.newPromptDefaultTitle : input)
            XCTAssertEqual(document.body, Strings.newPromptBody)
            XCTAssertNotNil(document.frontMatter.id)
            XCTAssertEqual(presentation.editorState.prompt?.relativePath.string, path)
            XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
            XCTAssertEqual(presentation.snapshot.selectedSection, .all)
            XCTAssertEqual(presentation.snapshot.filter, "")
        }
    }

    func testLibraryNewPromptDisabledDuringSaveLoadCommandAndUnavailableLibrary() throws {
        let presentation = try open()
        presentation.edit("Saved")
        presentation.save()
        XCTAssertEqual(presentation.editorState.status, .saving)
        XCTAssertFalse(presentation.canCreatePrompt)
        presentation.requestNewPrompt()
        XCTAssertNil(presentation.newPromptRequest)
        work.drain()
        presentation.revert()
        XCTAssertEqual(presentation.editorState.status, .loading)
        XCTAssertFalse(presentation.canCreatePrompt)
        work.drain()
        presentation.requestFileCommand(.rename)
        XCTAssertFalse(presentation.canCreatePrompt)
        let form = try XCTUnwrap(presentation.fileCommandRequest)
        presentation.resolveFileCommand(.rename("renamed.md"), id: form.id)
        XCTAssertEqual(presentation.editorState.status, .commandRunning)
        XCTAssertFalse(presentation.canCreatePrompt)
        work.drain()
        XCTAssertTrue(presentation.canCreatePrompt)
        presentation.setLibraryAvailable(false)
        XCTAssertFalse(presentation.canCreatePrompt)
        presentation.requestNewPrompt()
        XCTAssertNil(presentation.newPromptRequest)
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

    func testFieldSettingsApplyPatchesOnlyChangedPropertiesAndStaysADraft() throws {
        let source = "---\nfields:\n  tone: {default: brief, hint: keep}\n---\nHello {{tone}} {{implicit}} {{date}}"
        let presentation = try open(source)
        let settings = try XCTUnwrap(presentation.editorState.form?.fieldSettings)
        XCTAssertEqual(settings.map(\.name), ["tone", "implicit"], "Builtin {{date}} never gets a row")
        let field = try XCTUnwrap(settings.first { $0.name == "tone" })
        XCTAssertTrue(presentation.canEditFieldSettings)
        presentation.requestFieldSettings(field)
        let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
        XCTAssertEqual(draft.fieldName, "tone")
        XCTAssertEqual(draft.staged.label, "tone")
        XCTAssertTrue(draft.hasDefault)
        draft.settings.label = "Tone"
        draft.descriptionText = "How to speak"
        draft.defaultText = "warm"
        draft.settings.optional = true
        draft.settings.remember = false
        presentation.applyFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(try files.read(at: "one.md"), Data(source.utf8), "Apply edits the draft, not the file")
        presentation.save()
        work.drain()
        let saved = PromptCodec.parseFile(try files.read(at: "one.md"), filename: "one.md")
        let tone = try XCTUnwrap(saved.frontMatter.fields.first { $0.name == "tone" })
        XCTAssertEqual(tone.label, "Tone")
        XCTAssertEqual(tone.description, "How to speak")
        XCTAssertEqual(tone.defaultValue, "warm")
        XCTAssertTrue(tone.optional)
        XCTAssertFalse(tone.remember)
        XCTAssertTrue(saved.source.contains("hint: keep"), "Unknown declaration keys survive")
        XCTAssertFalse(saved.source.contains("implicit:"), "An untouched implicit field stays undeclared")
        XCTAssertFalse(saved.source.contains("remember: true"), "Unchanged settings are not written")
    }

    func testFieldSettingsDescriptionKeepsEditedUnicodeBytes() throws {
        let presentation = try open("---\nfields:\n  topic: {description: é}\n---\n{{topic}}")
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first)
        presentation.requestFieldSettings(field)
        let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
        draft.descriptionText = "e\u{301}"
        XCTAssertEqual(Data(try XCTUnwrap(draft.staged.description).utf8), Data("e\u{301}".utf8))
        presentation.applyFieldSettings()
        XCTAssertEqual(Data(try XCTUnwrap(presentation.editorState.fields.first?.description).utf8), Data("e\u{301}".utf8))
    }

    func testChoiceBindingsKeepTheirOptionAfterAnEarlierRowIsRemoved() throws {
        let presentation = try open("---\nfields:\n  tone: {type: choice, options: [A, B, C]}\n---\n{{tone}}")
        presentation.requestFieldSettings(try XCTUnwrap(presentation.editorState.form?.fieldSettings.first))
        let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
        let sheet = LibraryFieldSettingsSheet(draft: draft, onCancel: {}, onApply: {})
        let originalIDs = draft.optionIDs
        let bindingB = sheet.choiceBinding(1, \.label)
        let removedBinding = sheet.choiceBinding(0, \.label)
        draft.removeOption(at: 0)
        XCTAssertEqual(draft.optionIDs, Array(originalIDs.dropFirst()))
        bindingB.wrappedValue = "Edited B"
        XCTAssertEqual(draft.staged.options.map(\.label), ["Edited B", "C"])
        XCTAssertEqual(draft.staged.options.map(\.value), ["B", "C"])
        removedBinding.wrappedValue = "Late edit to removed A"
        XCTAssertEqual(draft.staged.options.map(\.label), ["Edited B", "C"])
        draft.addOption()
        XCTAssertFalse(originalIDs.contains(try XCTUnwrap(draft.optionIDs.last)))
        removedBinding.wrappedValue = "Late edit after adding a choice"
        XCTAssertEqual(draft.staged.options.map(\.label), ["Edited B", "C", ""])
    }

    func testFieldSettingsCancelAndUnchangedApplyWriteNothing() throws {
        let source = "---\nfields:\n  tone: {default: brief}\n---\n{{tone}} {{implicit}}"
        let presentation = try open(source)
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "tone" })
        presentation.requestFieldSettings(field)
        let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
        draft.settings.label = "Cancelled"
        presentation.cancelFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertEqual(presentation.editorState.source, source)
        XCTAssertFalse(presentation.editorState.isDirty)
        presentation.requestFieldSettings(field)
        presentation.applyFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertEqual(presentation.editorState.source, source)
        XCTAssertFalse(presentation.editorState.isDirty, "An unchanged Apply does not dirty the draft")
        let implicit = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "implicit" })
        presentation.requestFieldSettings(implicit)
        presentation.applyFieldSettings()
        XCTAssertFalse(presentation.editorState.isDirty)
        presentation.requestFieldSettings(implicit)
        try XCTUnwrap(presentation.fieldSettingsDraft).settings.optional = true
        presentation.applyFieldSettings()
        XCTAssertTrue(presentation.editorState.isDirty)
        let applied = try XCTUnwrap(presentation.editorState.source)
        XCTAssertTrue(applied.contains("implicit:"), "A changed implicit field becomes declared")
        XCTAssertTrue(applied.contains("optional: true"))
        XCTAssertFalse(applied.contains("label: implicit"), "Unchanged settings are not declared")
        XCTAssertFalse(applied.contains("remember: true"), "Unchanged settings are not declared")
    }

    func testFieldSettingsChoiceValidationBlocksInvalidApplyAndEmptyDefaultApplies() throws {
        let source = "---\nfields:\n  color: {type: choice, options: [red, green], default: red}\n---\n{{color}}"
        let presentation = try open(source)
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "color" })
        presentation.requestFieldSettings(field)
        let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
        draft.settings.options = []
        XCTAssertEqual(draft.issue, .missingOptions)
        XCTAssertEqual(draft.issueMessage, LibraryFieldStrings.missingChoices)
        presentation.applyFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertEqual(presentation.editorState.source, source)
        XCTAssertFalse(presentation.editorState.isDirty, "An invalid Apply writes nothing")
        presentation.requestFieldSettings(field)
        try XCTUnwrap(presentation.fieldSettingsDraft).defaultText = "blue"
        XCTAssertEqual(presentation.fieldSettingsDraft?.issue, .invalidDefault)
        XCTAssertEqual(presentation.fieldSettingsDraft?.issueMessage, LibraryFieldStrings.invalidDefault)
        presentation.applyFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertFalse(presentation.editorState.isDirty)
        presentation.requestFieldSettings(field)
        let valid = try XCTUnwrap(presentation.fieldSettingsDraft)
        valid.settings.options.append(PromptFieldOptionSettings(label: "None", value: ""))
        valid.defaultText = ""
        XCTAssertNil(valid.issue, "An empty literal default matches an empty choice value")
        presentation.applyFieldSettings()
        XCTAssertTrue(presentation.editorState.isDirty)
        let applied = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "color" })
        XCTAssertEqual(applied.defaultValue, "", "An enabled empty default is present, not nil")
        XCTAssertEqual(applied.options.map(\.value), ["red", "green", ""])
    }

    func testFieldSettingsSheetRetiresOnConflictAndPendingDecision() throws {
        try put("Second {{other}}", at: "two.md")
        let presentation = try open("Original {{field}}")
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "field" })
        presentation.edit("Mine {{field}}")
        presentation.requestFieldSettings(field)
        XCTAssertNotNil(presentation.fieldSettingsDraft)
        try put("Theirs")
        try XCTUnwrap(watchers.first).emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        work.drain()
        XCTAssertNotNil(presentation.editorState.conflict)
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertFalse(presentation.canEditFieldSettings)
        presentation.requestFieldSettings(field)
        XCTAssertNil(presentation.fieldSettingsDraft, "A live conflict refuses a new sheet")
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertNil(presentation.editorState.conflict)
        XCTAssertEqual(try body(), "Mine {{field}}")
        XCTAssertTrue(presentation.canEditFieldSettings)
        presentation.edit("Unsaved {{field}}")
        presentation.requestFieldSettings(field)
        XCTAssertNotNil(presentation.fieldSettingsDraft)
        presentation.selectPath("two.md")
        XCTAssertNotNil(presentation.editorState.pendingDecision)
        XCTAssertNil(presentation.fieldSettingsDraft)
        presentation.requestFieldSettings(field)
        XCTAssertNil(presentation.fieldSettingsDraft, "A pending decision refuses a new sheet")
        try respond(.decision(.cancel))
        XCTAssertTrue(presentation.canEditFieldSettings)
    }

    func testFieldSettingsSheetRetiresWhenPromptOrSourceChanges() throws {
        try put("Second {{other}}", at: "two.md")
        let presentation = try open("Original {{field}}")
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "field" })
        presentation.requestFieldSettings(field)
        XCTAssertNotNil(presentation.fieldSettingsDraft)
        presentation.selectPath("two.md")
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "two.md")
        XCTAssertNil(presentation.fieldSettingsDraft)
        let other = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "other" })
        presentation.requestFieldSettings(other)
        XCTAssertNotNil(presentation.fieldSettingsDraft)
        presentation.edit("Replaced")
        XCTAssertNil(presentation.fieldSettingsDraft, "A new source retires the staged sheet")
    }

    func testFieldSettingsQueuedApplyAgainstChangedPromptOrSourceWritesNothing() throws {
        let presentation = try open("Original {{field}}")
        let field = try XCTUnwrap(presentation.editorState.form?.fieldSettings.first { $0.name == "field" })
        let prompt = presentation.editorState.prompt
        let source = presentation.editorState.source
        let staleTokens: [(LibraryPromptSelection?, String?, UInt64)] = [
            (nil, source, presentation.sourceRevision),
            (prompt, "A different source", presentation.sourceRevision),
            (prompt, source, presentation.sourceRevision &+ 1),
        ]
        for (prompt, source, revision) in staleTokens {
            let stale = LibraryFieldSettingsDraft(field: field, prompt: prompt,
                source: source, sourceRevision: revision)
            stale.settings.label = "Stale"
            presentation.fieldSettingsDraft = stale
            presentation.applyFieldSettings()
            XCTAssertNil(presentation.fieldSettingsDraft)
            XCTAssertFalse(presentation.editorState.isDirty)
            XCTAssertEqual(presentation.editorState.source, "Original {{field}}")
        }
        // A draft that fails validation writes nothing even with a fresh token.
        let invalid = LibraryFieldSettingsDraft(field: field,
            prompt: presentation.editorState.prompt, source: presentation.editorState.source,
            sourceRevision: presentation.sourceRevision)
        invalid.settings.kind = .choice
        presentation.fieldSettingsDraft = invalid
        presentation.applyFieldSettings()
        XCTAssertNil(presentation.fieldSettingsDraft)
        XCTAssertFalse(presentation.editorState.isDirty)
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
