import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Drive the same view state and sheet seam as the window, without waiting
/// for a regular window to become key or traversing SwiftUI accessibility.
final class MacLibraryCommandTests: XCTestCase {
    private let promptID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private var original: String { "---\nid: \(promptID)\ntitle: Kept title\n---\nOriginal" }
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var dataFiles: RootedFileStore!
    private var delegate: AppDelegate!
    private var originalMenu: NSMenu?
    private let work = CommandTestWork()
    private let clipboard = CommandTestClipboard()
    private let watcher = CommandTestWatcher()
    private var dialogs: [CommandTestDialog] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(Thread.isMainThread)
        originalMenu = NSApp.mainMenu
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
        dataFiles = try RootedFileStore(root: data)
        try files.createRoot()
        try dataFiles.createRoot()
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        work.drain()
        delegate = nil
        dialogs = []
        NSApp.mainMenu = originalMenu
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func open(_ bytes: Data? = nil,
                      presenter: LibraryWindowController.DialogPresenter? = nil) throws -> LibraryViewState {
        try files.write(bytes ?? Data(original.utf8), at: "one.md")
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, launchURI: { _ in }, backgroundWork: work,
            clipboard: clipboard, editorDialog: presenter ?? { [weak self] _, dialog, respond in
                let recorded = CommandTestDialog(dialog: dialog, respond: respond)
                self?.dialogs.append(recorded)
                return { recorded.cancelled = true }
            }, setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: CommandTestScheduler(), makeFileWatcher: { [watcher = self.watcher] _, _ in watcher })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        XCTAssertFalse(presentation.canRunFileCommand)
        presentation.selectPath("one.md")
        XCTAssertEqual(presentation.editorState.status, .loading)
        XCTAssertFalse(presentation.canRunFileCommand)
        work.drain()
        return presentation
    }

    private func window() throws -> NSWindow { try XCTUnwrap(delegate.libraryWindow?.window) }

    private func dialog() throws -> CommandTestDialog {
        try XCTUnwrap(dialogs.last { !$0.cancelled }, "Expected a pending editor dialog")
    }

    private func respond(_ response: LibraryEditorResponse) throws {
        let recorded = try dialog()
        guard recorded.dialog.accepts(response) else { return XCTFail("Dialog does not accept \(response)") }
        recorded.cancelled = true
        recorded.respond(response)
    }

    private func command(_ command: LibraryFileCommand, response: LibraryEditorResponse,
                         in presentation: LibraryViewState) throws {
        presentation.requestFileCommand(command)
        guard case .fileCommand(let request) = try dialog().dialog else { return XCTFail("Expected a file form") }
        XCTAssertEqual(request.command, command)
        XCTAssertEqual(request.prompt, presentation.editorState.prompt)
        try respond(response)
    }

    @discardableResult
    private func seedRevision(_ bytes: Data, sequence: Int = 0) throws -> String {
        let name = "20261001T130700.123Z-" + String(format: "%06d", sequence) + ".md"
        try dataFiles.write(bytes, at: "history/\(promptID)/\(name)")
        return name
    }

    private func selectHistory(_ presentation: LibraryViewState, filename: String) {
        presentation.showInspector(.history)
        work.drain()
        presentation.selectRevision(filename)
    }

    private func body(at path: String = "one.md") throws -> String {
        PromptCodec.parseFile(try files.read(at: path), filename: path).body
    }

    func testHistoryOpensNewestFirstWithMetadataAndReadOnlyExactPreview() throws {
        let sources = [Data("Earlier\r\n".utf8), Data("---\ntitle: [broken\n---\nForensic".utf8),
            Data([0xff]), Data("---\nformat: 2\n---\nFuture".utf8),
            Data(repeating: 65, count: Limits.maxPromptBytes + 1)]
        let names = try sources.enumerated().map { try seedRevision($0.element, sequence: $0.offset) }
        let presentation = try open()
        presentation.showInspector(.history)
        XCTAssertTrue(presentation.editorState.history.isLoading)
        XCTAssertFalse(presentation.canRestoreRevision)
        work.drain()
        let revisions = presentation.editorState.history.revisions
        XCTAssertEqual(revisions.map(\.revision.filename), Array(names.reversed()))
        XCTAssertEqual(revisions.map(\.byteCount), sources.reversed().map(\.count))
        XCTAssertEqual(revisions.map(\.isForensic), [true, true, true, true, false])
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T13:07:00Z"))
        XCTAssertEqual(try XCTUnwrap(revisions.first?.revision.timestamp).timeIntervalSince(date), 0.123, accuracy: 0.001)
        for snapshot in revisions {
            presentation.selectRevision(snapshot.revision.filename)
            XCTAssertEqual(presentation.selectedRevision, snapshot)
            XCTAssertEqual(presentation.editorState.history.previewSource, snapshot.source)
            XCTAssertEqual(presentation.editorState.source, original)
            XCTAssertFalse(presentation.editorState.isDirty)
            XCTAssertFalse(LibraryCommandStrings.timestamp(snapshot.revision.timestamp).isEmpty)
            XCTAssertEqual(LibraryCommandStrings.byteSize(snapshot.byteCount),
                ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
        }
        XCTAssertNil(revisions[0].source)
        XCTAssertNil(revisions[2].source)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertEqual(clipboard.writes, 0)
    }

    func testRestoreReloadsEditorAndHistoryAndPreservesIdentityAndBody() throws {
        let name = try seedRevision(Data("  Before id\r\n\r\n".utf8))
        let presentation = try open()
        let selection = presentation.editorState.prompt
        let stamp = presentation.editorState.stamp
        selectHistory(presentation, filename: name)
        XCTAssertTrue(presentation.canRestoreRevision)
        presentation.restoreRevision()
        XCTAssertEqual(presentation.editorState.status, .commandRunning)
        XCTAssertFalse(presentation.canSave)
        XCTAssertFalse(presentation.canRevert)
        XCTAssertFalse(presentation.canRunFileCommand)
        XCTAssertFalse(presentation.canRestoreRevision)
        work.drain()
        XCTAssertEqual(try body(), "  Before id\r\n\r\n")
        XCTAssertEqual(presentation.editorState.prompt, selection)
        XCTAssertEqual(presentation.snapshot.selection, selection)
        XCTAssertNotEqual(presentation.editorState.stamp, stamp)
        XCTAssertEqual(presentation.editorState.stamp, try files.stamp(at: "one.md"))
        XCTAssertEqual(presentation.editorState.history.revisions.count, 2)
        XCTAssertEqual(presentation.editorState.history.revisions.first?.source, original)
        XCTAssertEqual(presentation.editorState.history.selectedRevision?.filename, name)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.restored)
        XCTAssertFalse(presentation.editorState.isDirty)
    }

    func testRestoreUsesRevertGuardCancelKeepsEverythingAndDiscardRestores() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        selectHistory(presentation, filename: name)
        let history = presentation.editorState.history
        let selection = presentation.snapshot.selection
        presentation.edit(original + " draft")
        presentation.restoreRevision()
        XCTAssertEqual(presentation.editorState.pendingDecision?.action, .revert)
        XCTAssertFalse(presentation.canRestoreRevision)
        // Restoring is not Revert to Saved: the guard still offers to save the draft first.
        XCTAssertEqual(try dialog().dialog.responses, [.decision(.save), .decision(.cancel), .decision(.discard)])
        try respond(.decision(.cancel))
        work.drain()
        XCTAssertEqual(presentation.editorState.source, original + " draft")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(presentation.snapshot.selection, selection)
        XCTAssertEqual(presentation.editorState.history, history)
        XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
        presentation.restoreRevision()
        try respond(.decision(.discard))
        work.drain()
        XCTAssertEqual(try body(), "Earlier")
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.restored)
    }

    func testHistoryReloadsWhenInspectorIsReopened() throws {
        let first = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        presentation.showInspector(.history)
        work.drain()
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [first])
        presentation.setInspectorVisible(false)
        let second = try seedRevision(Data("Later".utf8), sequence: 1)
        presentation.setInspectorVisible(true)
        XCTAssertTrue(presentation.editorState.history.isLoading)
        work.drain()
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [second, first])
        presentation.showInspector(.fields)
        presentation.showInspector(.history)
        XCTAssertTrue(presentation.editorState.history.isLoading)
        work.drain()
        XCTAssertEqual(presentation.inspectorPane, .history)
        XCTAssertTrue(presentation.isInspectorVisible)
    }

    func testForensicAndFutureRevisionsReturnDistinctTypedRefusalsWithoutWriting() throws {
        let sources = [Data("---\ntitle: [broken\n---\nBroken".utf8), Data([0xff]),
            Data(repeating: 65, count: Limits.maxPromptBytes + 1), Data("---\nformat: 2\n---\nFuture".utf8)]
        let names = try sources.enumerated().map { try seedRevision($0.element, sequence: $0.offset) }
        let presentation = try open()
        presentation.showInspector(.history)
        work.drain()
        for name in names {
            presentation.selectRevision(name)
            let reason = try XCTUnwrap(presentation.selectedRevision?.restoreFailure)
            XCTAssertTrue(presentation.canRestoreRevision, "Allow the model to return its typed refusal")
            presentation.restoreRevision()
            work.drain()
            XCTAssertEqual(presentation.editorState.status, .failed(.editing(.write(reason))))
            XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.restoreRefusal(reason))
            XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
            XCTAssertEqual(presentation.editorState.history.revisions.count, sources.count)
            XCTAssertEqual(presentation.editorState.history.selectedRevision?.filename, name)
        }
        XCTAssertNotEqual(LibraryCommandStrings.restoreRefusal(.invalidPrompt),
            LibraryCommandStrings.restoreRefusal(.unsupportedFormat(try XCTUnwrap(PromptFormatVersion(2)))))
    }

    func testStaleRestoreUsesExistingConflictSheetAndNeverOverwritesExternalBytes() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        selectHistory(presentation, filename: name)
        try files.write(Data((original + " external").utf8), at: "one.md")
        presentation.restoreRevision()
        work.drain()
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { return XCTFail("Expected conflict sheet") }
        XCTAssertEqual(conflict.kind, .modified)
        XCTAssertEqual(conflict.theirsSource, original + " external")
        XCTAssertEqual(presentation.editorState.source, original)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.changed)
        XCTAssertEqual(try body(), "Original external")
        XCTAssertFalse(presentation.canRunFileCommand)
        try respond(.conflict(.takeTheirs))
        work.drain()
        XCTAssertNil(presentation.editorState.conflict)
        XCTAssertNil(presentation.commandMessage)
        XCTAssertEqual(presentation.editorState.source, original + " external")
    }

    func testRenamePreservesTitleExactBytesHistoryAndFollowsSelection() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        selectHistory(presentation, filename: name)
        let identity = presentation.editorState.prompt?.identity
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        work.drain()
        XCTAssertNil(try files.stamp(at: "one.md"))
        XCTAssertEqual(try files.read(at: "renamed.md"), Data(original.utf8))
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.editorState.prompt?.identity, identity)
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.title, "Kept title")
        XCTAssertEqual(presentation.editorState.history.revisions.first?.revision.filename, name)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.renamed)
    }

    func testRenameAlertSelectsBasenameAndDisablesEmptyOrUnchangedInput() throws {
        let presentation = try open()
        presentation.requestFileCommand(.rename)
        let request = try XCTUnwrap(presentation.fileCommandRequest)
        let alert = LibraryWindowController.makeEditorAlert(for: .fileCommand(request))
        XCTAssertEqual(alert.messageText, "Rename “one.md”")
        XCTAssertEqual(alert.informativeText, "Enter a new filename. The prompt's title stays the same.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Rename", "Cancel"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
        let input = try XCTUnwrap(alert.window.initialFirstResponder as? NSTextField)
        XCTAssertFalse(alert.buttons[0].isEnabled)
        input.stringValue = ""
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        XCTAssertFalse(alert.buttons[0].isEnabled)
        input.stringValue = "new.md"
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        XCTAssertTrue(alert.buttons[0].isEnabled)
        input.stringValue = "one.md"
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        XCTAssertFalse(alert.buttons[0].isEnabled)
        alert.layout()
        XCTAssertTrue(alert.window.makeFirstResponder(input))
        XCTAssertEqual((input.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 3))
        alert.window.makeFirstResponder(nil)
        try respond(.cancelFileCommand)
    }

    func testMoveOffersKnownFoldersCreatesNestedDestinationAndEmptyReturnsToRoot() throws {
        try files.write(Data("Other".utf8), at: "known/nested/other.md")
        let presentation = try open()
        presentation.requestFileCommand(.move)
        let request = try XCTUnwrap(presentation.fileCommandRequest)
        XCTAssertEqual(request.folder, "")
        XCTAssertTrue(request.folders.contains("known"))
        XCTAssertTrue(request.folders.contains("known/nested"))
        let alert = LibraryWindowController.makeEditorAlert(for: .fileCommand(request))
        let combo = try XCTUnwrap(alert.accessoryView?.subviews.compactMap { $0 as? NSComboBox }.first)
        XCTAssertEqual(alert.messageText, "Move “one.md”")
        XCTAssertEqual(combo.placeholderString, "Top level of the library")
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
        XCTAssertTrue(combo.isEditable)
        XCTAssertTrue(combo.objectValues.contains { ($0 as? String) == "known/nested" })
        combo.stringValue = "new/deep"
        XCTAssertEqual(LibraryWindowController.fileCommandResponse(.move(""), alert: alert), .move("new/deep"))
        try respond(.move("new/deep"))
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "new/deep/one.md")
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(try files.read(at: "new/deep/one.md"), Data(original.utf8))
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.moved)
        try command(.move, response: .move(""), in: presentation)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
        XCTAssertNil(try files.stamp(at: "new/deep/one.md"))
    }

    func testUnassignedRenameAndMoveFollowMigratedSelection() throws {
        let presentation = try open(Data("Plain".utf8))
        let originalIdentity = presentation.editorState.prompt?.identity
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        work.drain()
        XCTAssertNotEqual(presentation.editorState.prompt?.identity, originalIdentity)
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "renamed.md")
        try command(.move, response: .move("new"), in: presentation)
        work.drain()
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(presentation.snapshot.selection?.relativePath, "new/renamed.md")
        XCTAssertEqual(try files.read(at: "new/renamed.md"), Data("Plain".utf8))
    }

    func testHistoryReloadsForNewSelectionWhileTabRemainsOpen() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        try files.write(Data("Other".utf8), at: "other.md")
        let presentation = try open()
        selectHistory(presentation, filename: name)
        XCTAssertEqual(presentation.editorState.history.revisions.count, 1)
        presentation.selectPath("other.md")
        work.drain()
        XCTAssertEqual(presentation.inspectorPane, .history)
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "other.md")
        XCTAssertTrue(presentation.editorState.history.revisions.isEmpty)
        XCTAssertFalse(presentation.editorState.history.isLoading)
        XCTAssertNil(presentation.selectedRevision)
        XCTAssertFalse(presentation.canRestoreRevision)
    }

    func testHistorySelectedDuringFailedCommandLoadsAfterCompletion() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        try files.write(Data("Occupied".utf8), at: "occupied.md")
        let presentation = try open()
        try command(.rename, response: .rename("occupied.md"), in: presentation)
        XCTAssertEqual(presentation.editorState.status, .commandRunning)
        presentation.showInspector(.history)
        XCTAssertFalse(presentation.canLoadHistory)
        XCTAssertFalse(presentation.editorState.history.isLoading)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [name])
        XCTAssertFalse(presentation.editorState.history.isLoading)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.occupied)
    }

    func testCommandFeedbackKeepsEachOutcomeThroughQueuedEditorUpdates() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        try files.write(Data("Other".utf8), at: "other.md")
        let native = try open()
        let main = CommandTestMainThread()
        let presentation = LibraryViewState(model: native.model, editor: native.editor,
            libraryPath: root.path, available: true, mainThread: main, revealLibrary: {})
        defer { presentation.deactivate() }
        selectHistory(presentation, filename: name)

        func finish(_ message: String) {
            main.queuesWork = true
            work.drain()
            main.drain()
            work.drain()
            main.drain()
            main.queuesWork = false
            XCTAssertEqual(presentation.commandMessage, message)
        }

        presentation.restoreRevision()
        XCTAssertEqual(presentation.editorState.status, .commandRunning)
        finish(LibraryCommandStrings.restored)
        let commands: [(LibraryFileCommand, LibraryEditorResponse, String)] = [
            (.rename, .rename("renamed.md"), LibraryCommandStrings.renamed),
            (.move, .move("new"), LibraryCommandStrings.moved),
            (.delete, .delete, LibraryCommandStrings.deleted)
        ]
        for (command, response, message) in commands {
            presentation.requestFileCommand(command)
            XCTAssertNil(presentation.commandMessage, "A new command clears earlier feedback")
            let request = try XCTUnwrap(presentation.fileCommandRequest)
            presentation.resolveFileCommand(response, id: request.id)
            XCTAssertEqual(presentation.editorState.status, .commandRunning)
            finish(message)
        }
        XCTAssertNil(presentation.editorState.prompt)
        presentation.selectPath("other.md")
        XCTAssertNil(presentation.commandMessage)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "other.md")
    }

    func testCommandFeedbackSurvivesQueuedStartAndCompletionPublications() throws {
        let native = try open()
        let main = CommandTestMainThread()
        let presentation = LibraryViewState(model: native.model, editor: native.editor,
            libraryPath: root.path, available: true, mainThread: main, revealLibrary: {})
        defer { presentation.deactivate() }
        presentation.requestFileCommand(.rename)
        let request = try XCTUnwrap(presentation.fileCommandRequest)
        main.queuesWork = true
        presentation.resolveFileCommand(.rename("renamed.md"), id: request.id)
        work.drain()
        XCTAssertEqual(presentation.editor.state.prompt?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
        main.drain()
        work.drain()
        main.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.renamed)
        presentation.edit(try XCTUnwrap(presentation.editorState.source) + " draft")
        XCTAssertNil(presentation.commandMessage)
    }

    func testHistoryReloadsAfterCommittedSaveWhileTabStaysOpen() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        selectHistory(presentation, filename: name)
        let prompt = presentation.editorState.prompt
        let sourceRevision = presentation.sourceRevision
        presentation.edit(original + " saved")
        XCTAssertTrue(presentation.canSave)
        presentation.save()
        XCTAssertEqual(presentation.editorState.status, .saving)
        work.drain()
        XCTAssertEqual(presentation.editorState.status, .saved)
        XCTAssertEqual(presentation.inspectorPane, .history)
        XCTAssertEqual(presentation.editorState.prompt, prompt)
        XCTAssertEqual(presentation.sourceRevision, sourceRevision)
        XCTAssertEqual(presentation.editorState.history.revisions.count, 2)
        XCTAssertEqual(presentation.editorState.history.revisions.first?.source, original)
        XCTAssertEqual(presentation.editorState.history.selectedRevision?.filename, name)
        XCTAssertEqual(try body(), "Original saved")
    }

    func testHistoryReloadsWhenLibraryReturnsWithoutChangingTabs() throws {
        let first = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        presentation.setLibraryAvailable(false)
        presentation.showInspector(.history)
        XCTAssertFalse(presentation.editorState.history.isLoading)
        XCTAssertTrue(presentation.editorState.history.revisions.isEmpty)
        presentation.setLibraryAvailable(true)
        XCTAssertTrue(presentation.editorState.history.isLoading)
        work.drain()
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [first])
        presentation.selectRevision(first)

        presentation.setLibraryAvailable(false)
        let second = try seedRevision(Data("Later".utf8), sequence: 1)
        presentation.setLibraryAvailable(true)
        XCTAssertTrue(presentation.editorState.history.isLoading)
        work.drain()
        XCTAssertEqual(presentation.inspectorPane, .history)
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [second, first])
        XCTAssertEqual(presentation.editorState.history.selectedRevision?.filename, first)
        presentation.setLibraryAvailable(true)
        XCTAssertFalse(presentation.editorState.history.isLoading, "Unchanged availability does not reload History")
    }

    func testFirstSaveReloadsHistoryAtSamePathWithoutResettingSourceSession() throws {
        let presentation = try open(Data("Plain".utf8))
        let before = try XCTUnwrap(presentation.editorState.prompt)
        let sourceRevision = presentation.sourceRevision
        presentation.showInspector(.history)
        work.drain()
        XCTAssertTrue(presentation.editorState.history.revisions.isEmpty)
        presentation.edit("Plain edited")
        presentation.save()
        work.drain()
        let assigned = try XCTUnwrap(presentation.editorState.prompt)
        guard case .assigned = assigned.identity else { return XCTFail("Expected first-save identity") }
        XCTAssertEqual(assigned.relativePath, before.relativePath)
        XCTAssertNotEqual(assigned.identity, before.identity)
        XCTAssertEqual(presentation.sourceRevision, sourceRevision)
        XCTAssertEqual(presentation.snapshot.selection, assigned)
        let revision = try XCTUnwrap(presentation.editorState.history.revisions.first)
        XCTAssertEqual(revision.revision.identity, assigned.identity)
        XCTAssertEqual(revision.source, "Plain")
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "renamed.md")
        XCTAssertEqual(presentation.editorState.prompt?.identity, assigned.identity)
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        XCTAssertEqual(presentation.editorState.history.revisions.first?.revision, revision.revision)
        XCTAssertEqual(try body(at: "renamed.md"), "Plain edited")
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.renamed)
    }

    func testHistoryReloadsWhenSamePathGainsAssignedIdentity() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open(Data("Plain".utf8))
        let before = try XCTUnwrap(presentation.editorState.prompt)
        let sourceRevision = presentation.sourceRevision
        presentation.showInspector(.history)
        work.drain()
        XCTAssertTrue(presentation.editorState.history.revisions.isEmpty)
        try files.write(Data(original.utf8), at: "one.md")
        watcher.emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        work.drain()
        let assigned = try XCTUnwrap(presentation.editorState.prompt)
        XCTAssertEqual(assigned.relativePath, before.relativePath)
        XCTAssertNotEqual(assigned.identity, before.identity)
        XCTAssertEqual(presentation.sourceRevision, sourceRevision)
        XCTAssertEqual(presentation.editorState.history.revisions.map(\.revision.filename), [name])
        XCTAssertEqual(presentation.editorState.history.revisions.first?.revision.identity, assigned.identity)
    }

    func testFileFormsMatchPathsAndCompareValuesWithDistinctCallbackTokens() throws {
        let local = LibraryPromptSelection(identity: .local(String(repeating: "a", count: 64)), relativePath: "one.md")
        let assigned = LibraryPromptSelection(identity: .assigned(try XCTUnwrap(ULID(promptID))), relativePath: "one.md")
        let request = LibraryFileCommandRequest(command: .rename, prompt: local, folders: ["work"])
        let repeated = LibraryFileCommandRequest(command: .rename, prompt: local, folders: ["work"])
        XCTAssertNotEqual(request.id, repeated.id)
        XCTAssertEqual(request, repeated)
        XCTAssertNotEqual(LibraryEditorDialog.fileCommand(request), .fileCommand(repeated))
        XCTAssertTrue(request.matchesFile(assigned))
        XCTAssertFalse(request.matchesFile(nil))
        XCTAssertFalse(request.matchesFile(LibraryPromptSelection(identity: assigned.identity, relativePath: "renamed.md")))
        XCTAssertNotEqual(request, LibraryFileCommandRequest(command: .move, prompt: local, folders: ["work"]))
        XCTAssertNotEqual(request, LibraryFileCommandRequest(command: .rename, prompt: assigned, folders: ["work"]))
        XCTAssertNotEqual(request, LibraryFileCommandRequest(command: .rename, prompt: local, folders: []))
    }

    func testFileCommandAlertReadsInputReferenceWhenLabelsFollowIt() throws {
        let presentation = try open()
        let prompt = try XCTUnwrap(presentation.editorState.prompt)
        for command in [LibraryFileCommand.rename, .move] {
            let request = LibraryFileCommandRequest(command: command, prompt: prompt, folders: ["work"])
            let alert = LibraryWindowController.makeEditorAlert(for: .fileCommand(request))
            let input = try XCTUnwrap(alert.window.initialFirstResponder as? NSTextField)
            input.stringValue = command == .rename ? "renamed.md" : "new/deep"
            try XCTUnwrap(alert.accessoryView).addSubview(NSTextField(labelWithString: "Extra caption"))
            let response: LibraryEditorResponse = command == .rename ? .rename("") : .move("")
            let expected: LibraryEditorResponse = command == .rename ? .rename("renamed.md") : .move("new/deep")
            XCTAssertEqual(LibraryWindowController.fileCommandResponse(response, alert: alert), expected)
        }
    }

    func testCommandWorkerSettlesAtExactJobLimit() {
        var completed = 0
        for _ in 0..<100 { work.run { completed += 1 } }
        work.drain()
        XCTAssertEqual(completed, 100)
    }

    func testDeleteNamesFileRequiresExplicitChoiceClearsSelectionAndKeepsHistory() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        presentation.requestFileCommand(.delete)
        let request = try XCTUnwrap(presentation.fileCommandRequest)
        let alert = LibraryWindowController.makeEditorAlert(for: .fileCommand(request))
        XCTAssertTrue(alert.messageText.contains("one.md"))
        XCTAssertEqual(alert.informativeText, "The prompt is removed from your library. Its history is kept.")
        XCTAssertEqual(request.responses, [.delete, .cancelFileCommand])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["", "\u{1b}"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertNil(alert.window.defaultButtonCell)
        try respond(.delete)
        work.drain()
        XCTAssertNil(try files.stamp(at: "one.md"))
        XCTAssertNil(presentation.editorState.prompt)
        XCTAssertNil(presentation.snapshot.selection)
        XCTAssertNil(presentation.snapshot.selectedPrompt)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.deleted)
        XCTAssertEqual(try dataFiles.read(at: "history/\(promptID)/\(name)"), Data("Earlier".utf8))
        XCTAssertFalse(presentation.canRunFileCommand)
        XCTAssertFalse(presentation.canRestoreRevision)
        XCTAssertTrue(try window().isVisible)
    }

    func testEveryFileCommandUsesGuardAndCancelKeepsDraftSelectionAndHistory() throws {
        let name = try seedRevision(Data("Earlier".utf8))
        let presentation = try open()
        selectHistory(presentation, filename: name)
        let history = presentation.editorState.history
        let selection = presentation.snapshot.selection
        presentation.edit(original + " draft")
        let commands: [(LibraryFileCommand, LibraryEditorResponse, EditorDiscardAction)] = [
            (.rename, .rename("renamed.md"), .rename), (.move, .move("new"), .move), (.delete, .delete, .delete)
        ]
        for (action, response, guardAction) in commands {
            try command(action, response: response, in: presentation)
            XCTAssertEqual(presentation.editorState.pendingDecision?.action, guardAction)
            XCTAssertFalse(presentation.canRunFileCommand)
            XCTAssertFalse(presentation.canRestoreRevision)
            try respond(.decision(.cancel))
            work.drain()
            XCTAssertEqual(presentation.editorState.source, original + " draft")
            XCTAssertTrue(presentation.editorState.isDirty)
            XCTAssertEqual(presentation.snapshot.selection, selection)
            XCTAssertEqual(presentation.editorState.history, history)
            XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
            XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.cancelled)
        }
    }

    func testGuardSaveCompletesBeforeRenameAndDiscardBeforeMove() throws {
        let presentation = try open()
        presentation.edit(original + " saved draft")
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        try respond(.decision(.save))
        XCTAssertEqual(presentation.editorState.status, .saving)
        XCTAssertFalse(presentation.canRunFileCommand)
        work.drain()
        XCTAssertEqual(try body(at: "renamed.md"), "Original saved draft")
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
        presentation.edit(try XCTUnwrap(presentation.editorState.source) + " discarded")
        try command(.move, response: .move("new"), in: presentation)
        try respond(.decision(.discard))
        work.drain()
        XCTAssertEqual(try body(at: "new/renamed.md"), "Original saved draft")
        XCTAssertFalse(presentation.editorState.isDirty)
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
    }

    func testOccupiedAndInvalidDestinationsReturnTypedFailuresAndNeverReplaceFiles() throws {
        try files.write(Data("Occupied".utf8), at: "occupied.md")
        try files.write(Data("Other".utf8), at: "known/one.md")
        let presentation = try open()
        let selection = presentation.snapshot.selection
        let commands: [(LibraryFileCommand, LibraryEditorResponse, String)] = [
            (.rename, .rename("occupied.md"), LibraryCommandStrings.occupied),
            (.move, .move("known"), LibraryCommandStrings.occupied),
            (.rename, .rename("../invalid.md"), LibraryCommandStrings.invalidDestination),
            (.move, .move("../invalid"), LibraryCommandStrings.invalidDestination)
        ]
        for (action, response, message) in commands {
            try command(action, response: response, in: presentation)
            work.drain()
            XCTAssertEqual(presentation.commandMessage, message)
            guard case .failed = presentation.editorState.status else { return XCTFail("Expected typed failure") }
            XCTAssertEqual(presentation.snapshot.selection, selection)
            XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
            XCTAssertEqual(try files.read(at: "occupied.md"), Data("Occupied".utf8))
            XCTAssertEqual(try files.read(at: "known/one.md"), Data("Other".utf8))
        }
    }

    func testEachStaleFileCommandOpensConflictAndMissingDeleteKeepsLoadedDraft() throws {
        let presentation = try open()
        let commands: [(LibraryFileCommand, LibraryEditorResponse)] = [
            (.rename, .rename("renamed.md")), (.move, .move("new")), (.delete, .delete)
        ]
        for (index, pair) in commands.enumerated() {
            let external = original + " external \(index)"
            try files.write(Data(external.utf8), at: "one.md")
            try command(pair.0, response: pair.1, in: presentation)
            work.drain()
            guard case .conflict = try dialog().dialog else { return XCTFail("Expected stale command conflict") }
            XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.changed)
            XCTAssertEqual(try files.read(at: "one.md"), Data(external.utf8))
            XCTAssertEqual(presentation.editorState.prompt?.relativePath, "one.md")
            try respond(.conflict(.takeTheirs))
            work.drain()
        }
        let loaded = try XCTUnwrap(presentation.editorState.source, "Expected loaded external content before deletion")
        try files.delete(at: "one.md")
        try command(.delete, response: .delete, in: presentation)
        work.drain()
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { return XCTFail("Expected missing-file conflict") }
        XCTAssertEqual(conflict.kind, .deleted)
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.missing)
        XCTAssertEqual(presentation.editorState.source, loaded)
        XCTAssertNotNil(presentation.snapshot.selection)
    }

    func testCancelFormAndLateCallbackNeverChangePromptOrDraft() throws {
        let presentation = try open()
        presentation.edit(original + " draft")
        presentation.requestFileCommand(.rename)
        let stale = try dialog()
        try respond(.cancelFileCommand)
        presentation.requestFileCommand(.rename)
        let replacement = try dialog()
        let replacementID = try XCTUnwrap(presentation.fileCommandRequest?.id)
        stale.respond(.rename("late.md"))
        work.drain()
        XCTAssertEqual(presentation.fileCommandRequest?.id, replacementID)
        XCTAssertFalse(replacement.cancelled)
        try respond(.cancelFileCommand)
        XCTAssertNil(presentation.fileCommandRequest)
        XCTAssertNil(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.source, original + " draft")
        XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
        XCTAssertNil(try files.stamp(at: "late.md"))
        presentation.requestFileCommand(.delete)
        let unavailable = try dialog()
        presentation.setLibraryAvailable(false)
        unavailable.respond(.delete)
        work.drain()
        XCTAssertTrue(unavailable.cancelled)
        XCTAssertNil(presentation.fileCommandRequest)
        XCTAssertFalse(presentation.canRunFileCommand)
        XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
    }

    func testCancelledCommandFeedbackDoesNotMaskLaterOrRetainedConflict() throws {
        let presentation = try open()
        presentation.edit(original + " draft")
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        try respond(.decision(.cancel))
        XCTAssertEqual(presentation.commandMessage, LibraryCommandStrings.cancelled)
        try files.write(Data((original + " external").utf8), at: "one.md")
        watcher.emit(.file(FileStoreEvent(relativePath: "one.md", kind: .modified)))
        work.drain()
        try respond(.dismissConflict)
        XCTAssertNil(presentation.commandMessage)
        XCTAssertNotNil(presentation.editorState.conflict)
        XCTAssertEqual(presentation.editorState.source, original + " draft")
        XCTAssertTrue(presentation.canShowConflict)

        // A command whose guard Save discovers a conflict is cancelled by
        // dismissing that conflict, but the conflict guidance must remain.
        presentation.save()
        try respond(.conflict(.takeTheirs))
        work.drain()
        presentation.edit(original + " draft")
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        try files.write(Data((original + " raced").utf8), at: "one.md")
        try respond(.decision(.save))
        work.drain()
        try respond(.dismissConflict)
        XCTAssertNil(presentation.commandMessage)
        XCTAssertNotNil(presentation.editorState.conflict)
        XCTAssertEqual(presentation.editorState.source, original + " draft")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(try body(), "Original raced")
        XCTAssertNil(try files.stamp(at: "renamed.md"))
    }

    func testReadOnlyAndUnavailablePromptsDisableCommands() throws {
        try files.write(Data([0xff]), at: "encoding.md")
        try files.write(Data(repeating: 65, count: Limits.maxPromptBytes + 1), at: "large.md")
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        let presentation = try open()
        for path in ["encoding.md", "large.md", "future.md"] {
            presentation.selectPath(RelativePath(path))
            work.drain()
            XCTAssertNotNil(presentation.editorState.readOnlyReason)
            XCTAssertFalse(presentation.canRunFileCommand)
            XCTAssertFalse(presentation.canRestoreRevision)
            let bytes = try files.read(at: path)
            for command in [LibraryFileCommand.rename, .move, .delete] { presentation.requestFileCommand(command) }
            XCTAssertNil(presentation.fileCommandRequest)
            XCTAssertEqual(try files.read(at: path), bytes)
        }
        presentation.selectPath("one.md")
        work.drain()
        presentation.setLibraryAvailable(false)
        XCTAssertFalse(presentation.canRunFileCommand)
        XCTAssertFalse(presentation.canLoadHistory)
        XCTAssertFalse(presentation.canRestoreRevision)
        presentation.requestFileCommand(.delete)
        XCTAssertNil(presentation.fileCommandRequest)
    }

    func testLibraryRebindRetiresFormAndLateCallback() throws {
        let presentation = try open()
        presentation.requestFileCommand(.rename)
        let old = try dialog()
        let otherRoot = directory.appendingPathComponent("other", isDirectory: true)
        let otherFiles = try RootedFileStore(root: otherRoot)
        try otherFiles.write(Data("Other".utf8), at: "one.md")
        XCTAssertEqual(delegate.switchLibrary(to: otherRoot), .switched)
        XCTAssertTrue(old.cancelled)
        old.respond(.rename("late.md"))
        work.drain()
        XCTAssertNil(presentation.fileCommandRequest)
        XCTAssertNil(presentation.commandMessage)
        XCTAssertEqual(presentation.activeLibraryPath, otherRoot.path)
        XCTAssertEqual(try otherFiles.read(at: "one.md"), Data("Other".utf8))
        XCTAssertEqual(try files.read(at: "one.md"), Data(original.utf8))
        XCTAssertNil(try otherFiles.stamp(at: "late.md"))
    }

    func testFileMenuUsesSharedGatesAndLeavesOtherWindowTextEditingAlone() throws {
        let presentation = try open()
        delegate.installMainMenu()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let menu = try XCTUnwrap(main.items.first { $0.title == LibraryCommandStrings.fileMenu }?.submenu)
        let actions = [#selector(LibraryWindowController.saveDocument(_:)),
            #selector(LibraryWindowController.duplicateDocument(_:)), #selector(LibraryWindowController.renameDocument(_:)),
            #selector(LibraryWindowController.moveDocument(_:)), #selector(LibraryWindowController.revertDocumentToSaved(_:)),
            #selector(LibraryWindowController.showInFinder(_:)), #selector(LibraryWindowController.deleteLibraryPrompt(_:))]
        let items = actions.compactMap { action in menu.items.first { $0.action == action } }
        XCTAssertEqual(items.count, actions.count)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        for item in items {
            XCTAssertNil(item.target)
            XCTAssertTrue(delegate.validateLibraryFileMenuItem(item, in: try window()))
            XCTAssertFalse(delegate.validateLibraryFileMenuItem(item, in: other))
            XCTAssertFalse(delegate.validateLibraryFileMenuItem(item, in: nil))
        }
        presentation.edit(original + " draft")
        try command(.rename, response: .rename("renamed.md"), in: presentation)
        for item in items { XCTAssertFalse(delegate.validateLibraryFileMenuItem(item, in: try window())) }
        try respond(.decision(.cancel))
        presentation.setLibraryAvailable(false)
        for item in items { XCTAssertFalse(delegate.validateLibraryFileMenuItem(item, in: try window())) }
        let edit = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Edit" })
        for key in ["x", "c", "v"] { XCTAssertNil(edit.items.first { $0.keyEquivalent == key }?.target) }
        let unknown = NSMenuItem(title: "Unknown", action: Selector("unknownLibraryAction:"), keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(unknown))
        XCTAssertFalse(delegate.validateLibraryFileMenuItem(unknown, in: try window()))
        let settings = NSMenuItem(title: "Settings", action: #selector(AppDelegate.showSettings), keyEquivalent: "")
        XCTAssertTrue(delegate.validateMenuItem(settings))
    }

    func testSaveMenuReopensDismissedConflictWithoutWritingDraft() throws {
        let presentation = try open()
        delegate.installMainMenu()
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == LibraryCommandStrings.fileMenu }?.submenu)
        let save = try XCTUnwrap(menu.items.first { $0.action == #selector(LibraryWindowController.saveDocument(_:)) })
        presentation.edit(original + " draft")
        let external = original + " external"
        try files.write(Data(external.utf8), at: "one.md")
        presentation.save()
        work.drain()
        try respond(.dismissConflict)
        XCTAssertFalse(presentation.canSave)
        XCTAssertTrue(presentation.canShowConflict)
        XCTAssertTrue(delegate.validateLibraryFileMenuItem(save, in: try window()))
        for action in [#selector(LibraryWindowController.renameDocument(_:)), #selector(LibraryWindowController.moveDocument(_:)),
                       #selector(LibraryWindowController.deleteLibraryPrompt(_:))] {
            let item = try XCTUnwrap(menu.items.first { $0.action == action })
            XCTAssertFalse(delegate.validateLibraryFileMenuItem(item, in: try window()))
        }
        let dismissed = dialogs.count
        presentation.save()
        XCTAssertEqual(dialogs.count, dismissed + 1)
        guard case .conflict(let conflict, _, _) = try dialog().dialog else { return XCTFail("Expected reopened conflict choices") }
        XCTAssertEqual(conflict.theirsSource, external)
        XCTAssertEqual(presentation.editorState.source, original + " draft")
        XCTAssertTrue(presentation.editorState.isDirty)
        XCTAssertEqual(try files.read(at: "one.md"), Data(external.utf8))
        try respond(.dismissConflict)
    }

    func testNativeRenameUsesEditedTextAndNonButtonDismissalCancelsForms() throws {
        var completed: XCTestExpectation?
        let presentation = try open(presenter: { window, dialog, done in
            LibraryWindowController.presentEditorDialog(in: window, dialog: dialog) { response in
                done(response)
                completed?.fulfill()
            }
        })
        completed = expectation(description: "Rename form completes")
        presentation.requestFileCommand(.rename)
        let sheet = try XCTUnwrap(try window().attachedSheet)
        let input = try XCTUnwrap(sheet.initialFirstResponder as? NSTextField)
        input.stringValue = "native.md"
        if let editor = input.currentEditor() { editor.string = "native.md" }
        try window().endSheet(sheet, returnCode: .alertFirstButtonReturn)
        wait(for: [try XCTUnwrap(completed)], timeout: 2)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "native.md")
        XCTAssertEqual(try files.read(at: "native.md"), Data(original.utf8))
        presentation.edit(original + " draft")
        for returnCode in [NSApplication.ModalResponse.cancel, .stop] {
            completed = expectation(description: "Non-button dismissal cancels the form")
            presentation.requestFileCommand(.delete)
            let sheet = try XCTUnwrap(try window().attachedSheet)
            try window().endSheet(sheet, returnCode: returnCode)
            wait(for: [try XCTUnwrap(completed)], timeout: 2)
            work.drain()
            XCTAssertNil(presentation.fileCommandRequest)
            XCTAssertNil(presentation.editorState.pendingDecision)
            XCTAssertTrue(presentation.editorState.isDirty)
            XCTAssertEqual(presentation.editorState.source, original + " draft")
            XCTAssertEqual(try files.read(at: "native.md"), Data(original.utf8))
        }
    }
}

private final class CommandTestDialog {
    let dialog: LibraryEditorDialog
    let respond: (LibraryEditorResponse) -> Void
    var cancelled = false
    init(dialog: LibraryEditorDialog, respond: @escaping (LibraryEditorResponse) -> Void) {
        self.dialog = dialog
        self.respond = respond
    }
}

private final class CommandTestWork: BackgroundWork {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        for _ in 0..<100 {
            guard !pending.isEmpty else { return }
            pending.removeFirst()()
        }
        if !pending.isEmpty { XCTFail("Command worker did not settle in 100 jobs; \(pending.count) still queued") }
    }
}

private final class CommandTestMainThread: MainThread {
    var queuesWork = false
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) {
        if queuesWork { pending.append(work) }
        else { work() }
    }
    func drain() {
        for _ in 0..<100 {
            guard !pending.isEmpty else { return }
            pending.removeFirst()()
        }
        if !pending.isEmpty { XCTFail("Command main thread did not settle in 100 jobs") }
    }
}

private struct CommandTestScheduler: MonkeysPawCore.Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) { work() }
}

private final class CommandTestWatcher: FileStoreWatcher {
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { self.onEvent = onEvent }
    func stop() { onEvent = nil }
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}

private final class CommandTestClipboard: Clipboard {
    private(set) var reads = 0
    private(set) var writes = 0
    func writeText(_ text: String) { writes += 1 }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { reads += 1; completion(nil) }
}
