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

    private func start() {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            launchURI: { [weak self] in self?.launched.append($0) }, backgroundWork: work,
            clipboard: clipboard, editorDialog: { [weak self] _, dialog, respond in
                let request = EditorTestDialog(dialog: dialog, respond: respond)
                self?.dialogs.append(request)
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

    private func open(_ source: String = "Original") throws -> LibraryViewState {
        try put(source)
        start()
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
        XCTAssertTrue(request.dialog.responses.contains(response))
        request.cancelled = true
        request.respond(response)
    }

    private func externalConflict(_ kind: EditorConflict.Kind) throws -> LibraryViewState {
        let presentation = try open()
        presentation.edit("Mine")
        if kind == .deleted {
            try files.delete(at: "one.md")
            watchers[0].emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
        } else {
            try put("Theirs")
            watchers[0].emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        }
        work.drain()
        XCTAssertEqual(presentation.editorState.conflict?.kind, kind)
        guard case .conflict(let conflict) = try dialog().dialog else { throw EditorTestError.noConflict }
        XCTAssertEqual(conflict.kind, kind)
        return presentation
    }

    func testEditTabsSaveExactCommittedBytesValidationAndClipboardFreePreview() throws {
        let source = "---\nfields:\n  tone: {default: brief}\n---\n{{tone}} {{implicit}} {{date}} {{time}} {{clipboard}}"
        let presentation = try open(source)
        XCTAssertEqual(presentation.editorTab, .edit)
        XCTAssertEqual(presentation.editorState.fields.map(\.name), ["tone", "implicit"])
        XCTAssertTrue(presentation.editorState.preview.contains("brief {implicit}"))
        XCTAssertTrue(presentation.editorState.preview.hasSuffix("{clipboard}"))
        XCTAssertFalse(presentation.editorState.preview.contains("{{date}}"))
        presentation.editorTab = .preview
        presentation.editorTab = .fields
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
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: try window().windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: UInt16(kVK_ANSI_S)))
        XCTAssertTrue(try XCTUnwrap(delegate.libraryWindow).handleKeyEvent(event))
        work.drain()
        XCTAssertEqual(try body(), "Draft")
        XCTAssertTrue(presentation.snapshot.selectedPrompt?.favorite == true)
        XCTAssertNil(presentation.editorState.conflict)
        XCTAssertEqual(clipboard.reads, 0)
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
        watchers[0].emit(.file(FileStoreEvent(relativePath: copy.relativePath.string, kind: .created)))
        work.drain()
        XCTAssertEqual(presentation.snapshot.selection, copy)
        XCTAssertEqual(presentation.editorState.prompt, copy)
    }

    func testDeletionConflictKeepMineRecreates() throws {
        let presentation = try externalConflict(.deleted)
        XCTAssertEqual(try dialog().dialog.responses, [.conflict(.keepMine), .conflict(.saveAsCopy), .conflict(.discard)])
        try respond(.conflict(.keepMine))
        work.drain()
        XCTAssertEqual(try body(), "Mine")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertNil(presentation.editorState.conflict)
    }

    func testDeletionConflictSaveAsCopy() throws {
        let presentation = try externalConflict(.deleted)
        try respond(.conflict(.saveAsCopy))
        work.drain()
        let copy = try XCTUnwrap(presentation.editorState.lastCopy)
        XCTAssertEqual(try body(at: copy.relativePath.string), "Mine")
        XCTAssertNil(try files.stamp(at: "one.md"))
        XCTAssertEqual(presentation.editorState.prompt, copy)
    }

    func testDeletionConflictDiscardClosesDraft() throws {
        let presentation = try externalConflict(.deleted)
        XCTAssertNil(presentation.snapshot.selection)
        XCTAssertEqual(presentation.editorState.source, "Mine", "A deleted row must not hide the draft")
        try respond(.conflict(.discard))
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
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        try respond(.decision(.discard))
        drainTerminationReply()
        XCTAssertEqual(terminationReplies, [true])
        XCTAssertEqual(try body(), "Original")
    }

    func testExternalRenameKeepsTheSelectedIdentityAndOpensItsNewPath() throws {
        let source = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: One\n---\nOriginal"
        let presentation = try open(source)
        let identity = presentation.snapshot.selection?.identity
        try files.move(from: "one.md", to: "renamed.md")
        watchers[0].emit(.file(FileStoreEvent(relativePath: "renamed.md", kind: .created)))
        watchers[0].emit(.file(FileStoreEvent(relativePath: "one.md", kind: .deleted)))
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
        XCTAssertEqual(presentation.editorTab, .edit)
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
        text.insertText(" plus", replacementRange: NSRange(location: 8, length: 0))
        XCTAssertEqual(presentation.editorState.source, "Original plus")
        text.undoManager?.undo()
        XCTAssertEqual(text.string, "Original")
        XCTAssertEqual(presentation.editorState.source, "Original")
        text.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 8, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        let marked = text.string
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
