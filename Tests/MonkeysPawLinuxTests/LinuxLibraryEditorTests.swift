#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryEditorTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var clipboard: EditorClipboard!
    private var quitCount = 0
    private var heldWork: EditorHeldWork?

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory
            .appendingPathComponent("MonkeysPaw", isDirectory: true))
        clipboard = EditorClipboard()
        quitCount = 0
        compose()
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        heldWork?.runAll()
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        heldWork = nil
        files = nil
        clipboard = nil
        tools = nil
    }

    func testSourceValidationSavePreviewAndFieldsUseLiveEditorWithoutClipboardReads() throws {
        let source = "---\ntitle: Hello\ncustom: keep\nfields:\n  topic: {default: Earth, description: Pick a topic}\n  choice: {type: choice, options: [a, b]}\n---\nHello {{topic}} {{missing}} {{clipboard}} {{date}} {{time}}"
        try files.write(Data(source.utf8), at: "a.md")
        let window = try open("a.md")
        let text = try widget("library-source", in: window)
        let tabs = try widget("library-editor-tabs", in: window)
        XCTAssertEqual(gtk_notebook_get_n_pages(mp_notebook(tabs)), 3)
        XCTAssertEqual(gtk_text_view_get_monospace(mp_text_view(text)), 1)
        XCTAssertEqual(gtk_text_buffer_get_enable_undo(buffer(text)), 1)
        XCTAssertEqual(contents(text), source)
        XCTAssertTrue(contents(try widget("library-preview", in: window)).hasPrefix("Hello Earth {missing} {clipboard}"))
        XCTAssertTrue(labels(try widget("library-fields", in: window)).contains { $0.contains("Pick a topic") })
        XCTAssertTrue(labels(try widget("library-fields", in: window)).contains("choice"))
        XCTAssertTrue(labels(try widget("library-fields", in: window)).contains("a = a\nb = b"))

        replace(text, with: "---\n[broken\n---\nDraft")
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.editorModel.state.issues.isEmpty })
        drain()
        XCTAssertTrue(label(try widget("library-validation", in: window)).contains("Error"))
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { if case .failed(.invalid) = self.environment.editorModel.state.status { return true }; return false })
        XCTAssertEqual(try files.read(at: "a.md"), Data(source.utf8))
        XCTAssertEqual(contents(text), "---\n[broken\n---\nDraft")
        let valid = source + "\nNew line 👋 e\u{301}"
        replace(text, with: valid)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_s), GDK_CONTROL_MASK), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        let saved = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        XCTAssertNotNil(saved.frontMatter.id)
        XCTAssertEqual(saved.body, PromptCodec.parse(valid, filename: "a.md").body)
        XCTAssertTrue(saved.source.contains("custom: keep"))
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertEqual(contents(text), environment.editorModel.state.source)
        XCTAssertEqual(label(try widget("library-editor-status", in: window)), "Saved")
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertEqual(clipboard.writes, 0)
    }

    func testSaveAsCopyAdoptsNewIdentityAndBrowserSelectionWithoutWritingOriginal() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let original = environment.editorModel.state.prompt
        XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("library-save-copy", in: window)), 0,
            "A clean prompt must still allow Save as Copy")
        replace(try widget("library-source", in: window), with: "My copy")
        try click("library-save-copy", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.lastCopy != nil && self.environment.editorModel.state.status != .loading })
        let copy = try XCTUnwrap(environment.editorModel.state.lastCopy)
        XCTAssertNotEqual(copy.relativePath, original?.relativePath)
        XCTAssertNotEqual(copy.identity, original?.identity)
        XCTAssertEqual(try files.read(at: "a.md"), Data("Original".utf8))
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: copy.relativePath.string), filename: (copy.relativePath.string as NSString).lastPathComponent).body, "My copy")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection == copy })
        XCTAssertEqual(environment.editorModel.state.prompt, copy)
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(try widget("library-source", in: window))), 0)
    }

    func testReadOnlyReasonsDisableNativeEditingAndSave() throws {
        let unsupported = try XCTUnwrap(PromptFormatVersion(2), "Format 2 must be representable as an unsupported format")
        let cases: [(String, Data, PromptReadOnlyReason)] = [
            ("future.md", Data("---\nformat: 2\n---\nFuture".utf8), .unsupportedFormat(unsupported)),
            ("bytes.md", Data([0xff, 0xfe]), .invalidUTF8),
            ("large.md", Data(repeating: 65, count: Limits.maxPromptBytes + 1), .sourceTooLarge)]
        for (path, bytes, reason) in cases { try files.write(bytes, at: path)
            let window = try open(path)
            XCTAssertEqual(environment.editorModel.state.readOnlyReason, reason)
            XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source", in: window))), 0)
            XCTAssertEqual(gtk_widget_get_sensitive(try widget("library-save", in: window)), 0)
            XCTAssertEqual(gtk_widget_get_sensitive(try widget("library-save-copy", in: window)), 0)
            XCTAssertEqual(label(try widget("library-read-only", in: window)), LinuxEditorStrings.readOnly(reason))
            let state = environment.editorModel.state
            environment.editorModel.edit("Replacement")
            XCTAssertEqual(environment.editorModel.state, state)
            XCTAssertEqual(try files.read(at: path), bytes)
        }
    }

    func testFileCommandsFollowSelectionAndDeleteExplicitlyClearsIt() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let editor = environment.editorModel
        let original = try XCTUnwrap(editor.state.prompt)
        editor.rename(to: "renamed.md")
        XCTAssertTrue(GTKTestSupport.spin {
            editor.state.prompt?.relativePath.string == "renamed.md"
                && self.environment.libraryBrowserModel.selection == editor.state.prompt
                && editor.state.status != .commandRunning
        })
        XCTAssertNotEqual(editor.state.prompt?.identity, original.identity, "An unassigned path hash follows the committed rename")
        XCTAssertNil(try files.stamp(at: "a.md"))
        editor.move(to: "nested/folder")
        let path = "nested/folder/renamed.md"
        XCTAssertTrue(GTKTestSupport.spin {
            editor.state.prompt?.relativePath.string == path
                && self.environment.libraryBrowserModel.selection == editor.state.prompt
                && editor.state.status != .commandRunning
        })
        let bytes = try files.read(at: path)
        XCTAssertEqual(bytes, Data("Original".utf8))
        editor.delete()
        XCTAssertTrue(GTKTestSupport.spin {
            editor.state.prompt == nil && self.environment.libraryBrowserModel.selection == nil
                && self.environment.libraryBrowserModel.rows.isEmpty
        })
        drain()
        XCTAssertEqual(contents(try widget("library-source", in: window)), "")
        XCTAssertNil(try files.stamp(at: path))
        try files.write(bytes, at: path)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.count == 1 })
        drain()
        XCTAssertNil(environment.libraryBrowserModel.selection, "Restoration must not undo the editor's explicit Delete signal")
        XCTAssertNil(editor.state.prompt)
    }

    func testDirtyFileCommandDecisionsExplainAndCancelWithoutWriting() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        let editor = environment.editorModel
        let commands: [(EditorDiscardAction, (EditorModel) -> Void)] = [
            (.rename, { $0.rename(to: "renamed.md") }),
            (.move, { $0.move(to: "folder") }),
            (.delete, { $0.delete() })]
        for (action, command) in commands {
            command(editor)
            XCTAssertTrue(GTKTestSupport.spin { editor.state.pendingDecision?.action == action && self.dialog != nil })
            let alert = try XCTUnwrap(dialog)
            XCTAssertEqual(label(try widget("library-dialog-message", in: alert)),
                "Save or discard your edits before continuing. Cancel keeps your draft.")
            try respond(.decision(.cancel))
            XCTAssertNil(editor.state.pendingDecision)
            XCTAssertEqual(editor.state.source, "Draft")
            XCTAssertEqual(environment.libraryBrowserModel.selection, editor.state.prompt)
            XCTAssertEqual(try files.read(at: "a.md"), Data("Original".utf8))
            XCTAssertEqual(try files.listFiles().map(\.relativePath), ["a.md"])
        }
    }

    func testModifiedConflictOffersEveryChoiceAndPreservesOriginalOnCopy() throws {
        for (index, choice) in [EditorConflictChoice.keepMine, .takeTheirs, .saveAsCopy].enumerated() {
            let path = "modified-\(index).md"
            try files.write(Data("Original".utf8), at: path)
            let window = try open(path)
            replace(try widget("library-source", in: window), with: "Mine")
            try files.write(Data("Theirs".utf8), at: path)
            try waitForConflict(.modified)
            try respond(.conflict(choice))
            XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.conflict == nil && !self.environment.editorModel.state.isDirty })
            drain()
            XCTAssertEqual(contents(try widget("library-source", in: window)), environment.editorModel.state.source)
            if choice == .keepMine {
                XCTAssertEqual(PromptCodec.parseFile(try files.read(at: path), filename: path).body, "Mine")
            } else if choice == .takeTheirs {
                XCTAssertEqual(environment.editorModel.state.source, "Theirs")
                XCTAssertEqual(try files.read(at: path), Data("Theirs".utf8))
            } else {
                let copy = try XCTUnwrap(environment.editorModel.state.lastCopy)
                XCTAssertNotEqual(copy.relativePath.string, path)
                XCTAssertEqual(PromptCodec.parseFile(try files.read(at: copy.relativePath.string), filename: (copy.relativePath.string as NSString).lastPathComponent).body, "Mine")
                XCTAssertEqual(try files.read(at: path), Data("Theirs".utf8))
            }
        }
    }

    func testDeletedConflictCancelKeepsDraftAndEachChoiceWorks() throws {
        for (index, choice) in [EditorConflictChoice.keepMine, .saveAsCopy, .discard].enumerated() {
            let path = "deleted-\(index).md"
            try files.write(Data("Original".utf8), at: path)
            let window = try open(path)
            let original = environment.editorModel.state.prompt
            replace(try widget("library-source", in: window), with: "Mine")
            try files.delete(at: path)
            try waitForConflict(.deleted)
            XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection == nil })
            let conflict = environment.editorModel.state.conflict
            try respond(.dismissConflict)
            XCTAssertEqual(environment.editorModel.state.conflict, conflict)
            XCTAssertEqual(environment.editorModel.state.source, "Mine")
            XCTAssertEqual(contents(try widget("library-source", in: window)), "Mine")
            try click("library-save", in: window)
            XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
            try respond(.conflict(choice))
            XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.conflict == nil && !self.environment.editorModel.state.isDirty })
            if choice == .keepMine {
                XCTAssertEqual(PromptCodec.parseFile(try files.read(at: path), filename: path).body, "Mine")
            } else {
                if choice == .saveAsCopy {
                    let copy = try XCTUnwrap(environment.editorModel.state.lastCopy)
                    XCTAssertNotEqual(copy.identity, original?.identity)
                    XCTAssertEqual(PromptCodec.parseFile(try files.read(at: copy.relativePath.string), filename: (copy.relativePath.string as NSString).lastPathComponent).body, "Mine")
                    XCTAssertEqual(copy.relativePath.string, "deleted-\(index) 2.md")
                    XCTAssertNil(try files.stamp(at: path), "Copy must leave the deleted original absent")
                } else {
                    XCTAssertNil(try files.stamp(at: path))
                    XCTAssertNil(environment.editorModel.state.prompt)
                    try files.write(Data("Original".utf8), at: path)
                    XCTAssertTrue(GTKTestSupport.spin {
                        self.environment.libraryBrowserModel.selection == original
                            && self.environment.editorModel.state.prompt == original
                            && self.environment.editorModel.state.source == "Original"
                    }, "External deletion and discard retain the selection key for restoration (§11.7)")
                }
            }
        }
    }

    func testConflictCancelAndFailedKeepMineAllowDraftRepair() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        replace(source, with: "---\n[broken\n---\nMine")
        try files.write(Data("External".utf8), at: "a.md")
        try waitForConflict(.modified)
        try respond(.conflict(.keepMine))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog.map { self.labels($0).contains { $0.contains("Fix the validation errors") } } == true })
        let conflict = environment.editorModel.state.conflict
        let alert = try XCTUnwrap(dialog)
        gtk_window_close(mp_window(alert))
        XCTAssertNil(dialog)
        XCTAssertEqual(environment.editorModel.state.conflict, conflict)
        XCTAssertTrue(environment.editorModel.state.isDirty)
        replace(source, with: "Repaired")
        drain()
        XCTAssertNil(dialog)
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.conflict(.keepMine))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Repaired")
    }

    func testConflictCancelAlsoCancelsPendingCloseAndRestoringHiddenWindowShowsConflict() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Mine")
        gtk_widget_set_visible(window, 0)
        try files.write(Data("Theirs".utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.conflict?.theirsSource == "Theirs" })
        XCTAssertNil(dialog)
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision?.action == .close })
        try respond(.dismissConflict)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision == nil })
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(environment.editorModel.state.source, "Mine")
        XCTAssertNotNil(environment.editorModel.state.conflict)
        XCTAssertEqual(try files.read(at: "a.md"), Data("Theirs".utf8))
        XCTAssertNil(dialog)
    }

    func testSelectionGuardCancelSaveAndDiscardKeepBrowserAndEditorTogether() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        try files.write(Data("Beta".utf8), at: "b.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Saved alpha")
        try select("b.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision != nil })
        XCTAssertEqual(environment.libraryBrowserModel.selection?.relativePath.string, "a.md")
        try respond(.decision(.cancel))
        XCTAssertEqual(environment.editorModel.state.source, "Saved alpha")
        let list = try widget("library-list", in: window)
        let selected = try XCTUnwrap(gtk_list_box_get_selected_row(mp_list_box(list)))
        XCTAssertEqual(Int(gtk_list_box_row_get_index(selected)), environment.libraryBrowserModel.rows.firstIndex { $0.relativePath.string == "a.md" })
        try select("b.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == "Beta" })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Saved alpha")
        replace(try widget("library-source", in: window), with: "Discard beta")
        XCTAssertTrue(environment.editorModel.state.isDirty)
        try select("a.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == "a.md" && self.environment.editorModel.state.status != .loading })
        XCTAssertEqual(try files.read(at: "b.md"), Data("Beta".utf8))
    }

    func testNativeCloseCancelDiscardAndSamePathReopenRetireUndo() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        try files.write(Data("Other".utf8), at: "folder/b.md")
        let window = try open("a.md")
        let selected = environment.libraryBrowserModel.selection
        let source = try widget("library-source", in: window)
        replace(source, with: "Draft")
        environment.libraryBrowserModel.selectSection(.folder(RelativePath("folder")))
        environment.libraryBrowserModel.setFilter("no matching row")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        try respond(.decision(.cancel))
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(environment.editorModel.state.source, "Draft")
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_w), GDK_CONTROL_MASK), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertNil(environment.editorModel.state.prompt)
        XCTAssertEqual(environment.libraryBrowserModel.selection, selected)
        XCTAssertEqual(environment.libraryBrowserModel.selectedSection, .folder(RelativePath("folder")))
        XCTAssertEqual(environment.libraryBrowserModel.filter, "no matching row")
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin {
            gtk_widget_get_visible(window) != 0 && self.environment.editorModel.state.prompt == selected
                && self.environment.editorModel.state.source == "Original"
        })
        drain()
        XCTAssertEqual(environment.libraryBrowserModel.selectedSection, .folder(RelativePath("folder")))
        XCTAssertEqual(environment.libraryBrowserModel.filter, "no matching row")
        XCTAssertEqual(contents(source), "Original")
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0)
    }

    func testQuitActionWaitsForSaveDiscardOrCancelAndCoalescesRepeatRequests() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Saved before quit")
        quit()
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision?.action == .quit })
        XCTAssertEqual(quitCount, 0)
        XCTAssertTrue(environment.editorModel.state.queuedActions.isEmpty)
        try respond(.decision(.cancel))
        drain()
        XCTAssertEqual(quitCount, 0)
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin { self.quitCount == 1 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Saved before quit")
        replace(try widget("library-source", in: window), with: "Discard on quit")
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { self.quitCount == 2 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Saved before quit")
    }

    func testQuitActionApprovesAfterEnvironmentIsReleased() {
        weak var released = environment
        environment.shutdown()
        environment = nil
        XCTAssertNil(released, "Quit's action must not retain the environment")
        quit()
        XCTAssertEqual(quitCount, 1, "A released environment must not swallow Quit")
    }

    func testQuitCanBeRequestedAfterGraphReplacementBeforeDiscardReplyDrains() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision?.action == .quit })
        let old = environment.editorModel
        old.resolveDecision(.discard, id: try XCTUnwrap(old.state.pendingDecision).id)
        let replacement = tools.directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        XCTAssertTrue(environment.editorModel !== old)
        quit()
        XCTAssertEqual(quitCount, 1, "The retired graph's quit latch must not block the new graph")
        drain()
        XCTAssertEqual(quitCount, 1, "The retired quit must not approve after replacement")
    }

    func testShutdownCompletesAbandonedAndLaterEditorRequestsAsInactive() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        let old = environment.editorModel
        var replies: [EditorGuardResult] = []
        old.request(.close) { replies.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { old.state.pendingDecision != nil })
        old.request(.quit) { replies.append($0) }
        environment.shutdown()
        old.request(.revert) { replies.append($0) }
        drain()
        XCTAssertEqual(replies, [.inactive, .inactive, .inactive], "Retirement must deliver every guard completion")
    }

    func testDecisionNativeDismissalCancelsWithoutHidingOrRecreatingDialog() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        for useEscape in [false, true] {
            gtk_window_close(mp_window(window))
            XCTAssertNotEqual(gtk_widget_get_visible(window), 0, "close-request must stop GTK's default hide")
            XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
            let alert = try XCTUnwrap(dialog)
            let message = try widget("library-dialog-message", in: alert)
            XCTAssertEqual(gtk_label_get_wrap(mp_label(message)), 1)
            XCTAssertEqual(gtk_label_get_max_width_chars(mp_label(message)), 64)
            if useEscape {
                XCTAssertNotEqual(mp_test_emit_key_pressed(alert, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
            } else { gtk_window_close(mp_window(alert)) }
            XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision == nil && self.dialog == nil },
                "Native dismissal must resolve the decision as Cancel")
            environment.libraryBrowserModel.setFilter(useEscape ? "Draft" : "Original")
            drain()
            XCTAssertNil(dialog, "A cancelled decision must not reappear on render")
            XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
            XCTAssertEqual(environment.editorModel.state.source, "Draft")
        }
    }

    func testDialogEscapeIgnoresLockBitsAndRejectsRealChords() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        // GTK4 does not name X11's Num Lock MOD2 bit, but it can occur in state.
        for locks in [GDK_LOCK_MASK.rawValue, UInt32(1 << 4), GDK_LOCK_MASK.rawValue | UInt32(1 << 4)] {
            gtk_window_close(mp_window(window))
            XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
            let alert = try XCTUnwrap(dialog)
            XCTAssertEqual(mp_test_emit_key_pressed(alert, UInt32(GDK_KEY_Escape),
                GdkModifierType(rawValue: locks | GDK_CONTROL_MASK.rawValue)), 0)
            XCTAssertNotNil(environment.editorModel.state.pendingDecision)
            XCTAssertNotEqual(mp_test_emit_key_pressed(alert, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: locks)), 0,
                "Escape must cancel with Caps/Num Lock enabled")
            XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision == nil && self.dialog == nil })
            drain() // Cancel's queued completion releases the close request.
        }
        XCTAssertEqual(environment.editorModel.state.source, "Draft")
    }

    func testDialogRespondsOnceWhenCallbackReentersNativeEvents() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        environment.editorModel.request(.quit)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision != nil && self.dialog != nil })
        let decision = try XCTUnwrap(environment.editorModel.state.pendingDecision)
        for firstResponse in [LinuxEditorResponse.decision(.save), .decision(.cancel)] {
            let existingWindows = windows
            var alert: GTK.Widget?
            var responses: [LinuxEditorResponse] = []
            let native = LinuxEditorDialog(parent: window, state: .decision(decision, status: .idle)) { response in
                responses.append(response)
                if responses.count == 1, let alert {
                    XCTAssertNotEqual(mp_test_emit_key_pressed(alert, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
                }
            }
            defer { native.destroy() }
            alert = try XCTUnwrap(windows.first { !existingWindows.contains($0) })
            let presented = try XCTUnwrap(alert)
            if firstResponse == .decision(.save) {
                XCTAssertNotEqual(gtk_widget_activate(try widget("library-dialog-response-0", in: presented)), 0)
                XCTAssertTrue(GTKTestSupport.spin { !responses.isEmpty })
            } else { gtk_window_close(mp_window(presented)) }
            XCTAssertEqual(responses, [firstResponse], "A nested Escape must not send a second response")
            gtk_window_close(mp_window(presented))
            XCTAssertEqual(responses, [firstResponse], "Later native dismissal must not send another response")
        }
    }

    func testUnchangedPreviewKeepsNativeBufferAndCaret() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        let window = try open("a.md")
        let preview = try widget("library-preview", in: window)
        let previewBuffer = buffer(preview)
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(previewBuffer, &end)
        gtk_text_buffer_place_cursor(previewBuffer, &end)
        var changes = 0
        GTK.onSignal(UnsafeMutableRawPointer(previewBuffer), "changed") { changes += 1 }
        replace(try widget("library-source", in: window), with: "---\ncustom: draft\n---\nBody")
        drain()
        environment.libraryBrowserModel.setFilter("Body")
        drain()
        XCTAssertEqual(changes, 0, "Unchanged Preview must not reset its text, scroll or selection")
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(previewBuffer, &caret, gtk_text_buffer_get_insert(previewBuffer))
        XCTAssertEqual(gtk_text_iter_get_offset(&caret), 4)
        replace(try widget("library-source", in: window), with: "Changed")
        XCTAssertTrue(GTKTestSupport.spin { self.contents(preview) == "Changed" })
        XCTAssertGreaterThan(changes, 0)
    }

    func testRejectedSaveAndFavoriteShortcutsAreNotConsumed() throws {
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        let window = try open("future.md")
        for key in [GDK_KEY_s, GDK_KEY_d] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0,
                "A read-only editor must leave rejected shortcuts unhandled")
        }
        try files.write(Data("Valid".utf8), at: "valid.md")
        _ = try open("valid.md")
        replace(try widget("library-source", in: window), with: "---\n[broken\n---\nDraft")
        drain()
        XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_d), GDK_CONTROL_MASK), 0)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_s), GDK_CONTROL_MASK), 0)
        XCTAssertTrue(GTKTestSupport.spin { if case .failed(.invalid) = self.environment.editorModel.state.status { return true }; return false })
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_w), GDK_CONTROL_MASK), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_w), GDK_CONTROL_MASK), 0)
        try respond(.decision(.cancel))
    }

    func testSameSessionNilLoadingSourcePreservesBufferButReplacementClearsIt() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.library) != nil })
        try select("a.md", in: try XCTUnwrap(self.window(titled: LinuxStrings.library)))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .loading })
        let loading = environment.editorModel.state
        XCTAssertNotNil(loading.prompt)
        XCTAssertNil(loading.source)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == "Original" })
        let native = LinuxLibrarySourceEditor()
        g_object_ref_sink(native.widget)
        defer { g_object_unref(native.widget) }
        native.update(environment.editorModel.state, revision: 1, available: true)
        XCTAssertEqual(contents(native.widget), "Original", "Load must populate the buffer before drafting")
        gtk_text_buffer_begin_user_action(buffer(native.widget))
        gtk_text_buffer_insert_at_cursor(buffer(native.widget), "Draft", -1)
        gtk_text_buffer_end_user_action(buffer(native.widget))
        let draft = contents(native.widget)
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer(native.widget)), 0)
        native.update(loading, revision: 1, available: true)
        XCTAssertEqual(contents(native.widget), draft, "A nil source has not supplied replacement text")
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer(native.widget)), 0)
        native.update(loading, revision: 2, available: true)
        XCTAssertEqual(contents(native.widget), "", "A new loading session must not show the retired draft")
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(native.widget)), 0)
    }

    func testOpeningNewIdentityAtSamePathRetiresUndoBeforeLoading() throws {
        holdWork()
        let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal"
        try files.write(Data(original.utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        replace(source, with: original.replacingOccurrences(of: "Original", with: "Saved"))
        environment.editorModel.save()
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0)

        let replacement = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAW\n---\nReplacement"
        try files.write(Data(replacement.utf8), at: "a.md")
        let id = try XCTUnwrap(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW"))
        let selection = LibraryPromptSelection(identity: .assigned(id), relativePath: "a.md")
        environment.editorModel.open(selection)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt == selection
            && self.environment.editorModel.state.status == .loading })
        drain()
        XCTAssertEqual(contents(source), "", "A different identity starts a new session despite the same path")
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == replacement })
        drain()
        XCTAssertEqual(contents(source), replacement)
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0, "Undo must not restore the retired prompt's id")
    }

    func testCleanConflictUsesCoreUnsavedGuardForQuitAndFolderSwitch() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        replace(source, with: "Mine")
        try files.write(Data("Theirs".utf8), at: "a.md")
        try waitForConflict(.modified)
        try respond(.dismissConflict)
        replace(source, with: "Original")
        drain()
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertNotNil(environment.editorModel.state.conflict)
        quit()
        XCTAssertEqual(quitCount, 1, "The baseline draft has no unsaved edits to discard")
        XCTAssertNil(environment.editorModel.state.pendingDecision)
        let replacement = tools.directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        XCTAssertEqual(try files.read(at: "a.md"), Data("Theirs".utf8))
    }

    func testUnavailableLibraryPreservesNativeUndoAndAllowsDiscardThenSwitch() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        replace(source, with: "Draft")
        let root = LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw")
        try FileManager.default.moveItem(at: root, to: tools.directory.appendingPathComponent("Retired"))
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.pickerModel.libraryAvailable })
        drain()
        XCTAssertEqual(contents(source), "Draft")
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(source)), 0)
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0,
            "A health transition without replacement text must retain native undo")
        let replacement = tools.directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy)
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt == nil })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
    }

    func testCloseAndQuitQueueBehindSaveAndWaitForItsCompletion() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Saved")
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saving })
        gtk_window_close(mp_window(window))
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.queuedActions == [.close, .quit] })
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(quitCount, 0)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 && self.quitCount == 1 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Saved")
    }

    func testFailedDecisionSaveKeepsClosePendingUntilCancelOrRepair() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "---\n[broken\n---\nBad")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin { if case .failed(.invalid) = self.environment.editorModel.state.status { return self.dialog != nil }; return false })
        XCTAssertNotNil(environment.editorModel.state.pendingDecision)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        try respond(.decision(.cancel))
        replace(try widget("library-source", in: window), with: "Repaired")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Repaired")
    }

    func testCommandRunningDisablesRevertAndQueuesQuitUntilCompletion() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let editor = environment.editorModel
        editor.rename(to: "renamed.md")
        XCTAssertTrue(GTKTestSupport.spin { editor.state.status == .commandRunning })
        drain()
        XCTAssertEqual(label(try widget("library-editor-status", in: window)), "Updating the file…")
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source", in: window))), 0)
        for name in ["library-save", "library-save-copy", "library-revert"] {
            XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0)
        }
        quit()
        quit()
        drain()
        XCTAssertEqual(quitCount, 0)
        XCTAssertEqual(editor.state.queuedActions, [.quit])
        XCTAssertNil(dialog)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.quitCount == 1 })
        XCTAssertEqual(editor.state.prompt?.relativePath.string, "renamed.md")
        drain()
        XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("library-revert", in: window)), 0)
    }

    func testSettingsRefusesCommandRunningUntilCompletion() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        _ = try open("a.md")
        let editor = environment.editorModel
        let replacement = tools.directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        editor.move(to: "folder")
        XCTAssertTrue(GTKTestSupport.spin { editor.state.status == .commandRunning })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy)
        XCTAssertTrue(environment.editorModel === editor)
        guard environment.editorModel === editor else { return }
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(self.window(titled: LinuxStrings.settings))
        environment.generalSettingsModel.chooseFolder(replacement.path)
        XCTAssertTrue(GTKTestSupport.spin {
            (try? self.widget("settings-library-message", in: settings)).map(self.label) == LinuxEditorStrings.librarySwitchRefused
        })
        XCTAssertTrue(environment.editorModel === editor)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { editor.state.status == .saved })
        environment.showSettings()
        drain()
        XCTAssertEqual(gtk_widget_get_visible(try widget("settings-library-message", in: settings)), 0)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
    }

    func testCommandRunningHoldsConflictDialogUntilCompletion() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let editor = environment.editorModel
        let source = try widget("library-source", in: window)
        replace(source, with: "Mine")
        try files.write(Data("Theirs".utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { editor.state.conflict?.isLoading == true })
        heldWork?.runAll()
        try waitForConflict(.modified)
        try respond(.dismissConflict)
        replace(source, with: "Original")
        XCTAssertFalse(editor.state.isDirty)
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        editor.rename(to: "renamed.md")
        XCTAssertTrue(GTKTestSupport.spin { editor.state.status == .commandRunning })
        drain()
        XCTAssertNil(dialog, "Conflict choices must wait for the stamped command reply")
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { editor.state.status != .commandRunning && editor.state.conflict?.isLoading == true })
        XCTAssertNil(dialog)
        heldWork?.runAll()
        try waitForConflict(.modified)
        XCTAssertEqual(editor.state.conflict?.theirsSource, "Theirs")
        XCTAssertNil(try files.stamp(at: "renamed.md"))
    }

    func testBlockedHistoryKeepsCloseAndDraftPendingUntilSaveRetry() throws {
        let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal"
        try files.write(Data(original.utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Retry draft")
        // A file blocks history's parent directory even when CI runs as root.
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        try data.write(Data("Blocked".utf8), at: "history")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin {
            if case .failed(.editing) = self.environment.editorModel.state.status { return self.dialog != nil }
            return false
        })
        XCTAssertNotNil(environment.editorModel.state.pendingDecision)
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(environment.editorModel.state.source, "Retry draft")
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        try data.delete(at: "history")
        try respond(.decision(.save))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Retry draft")
    }

    func testRevertUsesTheDiscardGuardAndReloadsDisk() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        replace(try widget("library-source", in: window), with: "Draft")
        try click("library-revert", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision?.action == .revert })
        try respond(.decision(.cancel))
        XCTAssertEqual(environment.editorModel.state.source, "Draft")
        try click("library-revert", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == "Original" && self.environment.editorModel.state.status != .loading })
        drain()
        XCTAssertEqual(contents(try widget("library-source", in: window)), "Original")
        XCTAssertFalse(environment.editorModel.state.isDirty)
    }

    func testSamePathExternalReloadRefreshesNativeSource() throws {
        let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal"
        try files.write(Data(original.utf8), at: "a.md")
        let window = try open("a.md")
        let prompt = try XCTUnwrap(environment.editorModel.state.prompt)
        let changed = original.replacingOccurrences(of: "Original", with: "External")
        try files.write(Data(changed.utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == changed
            && self.environment.editorModel.state.status != .loading })
        drain()
        XCTAssertEqual(environment.editorModel.state.prompt, prompt)
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertEqual(contents(try widget("library-source", in: window)), changed)
    }

    func testReopeningSavedCopyRetainsFilterAndSection() throws {
        try files.write(Data("Original".utf8), at: "folder/a.md")
        try files.write(Data("Original Charlie".utf8), at: "folder/c.md")
        let window = try open("folder/a.md")
        try click("library-save-copy", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.lastCopy != nil
            && self.environment.editorModel.state.status == .saved })
        drain()
        let copy = try XCTUnwrap(environment.editorModel.state.lastCopy)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection == copy },
            "The copy must be indexed and selected before navigating away")
        environment.libraryBrowserModel.selectSection(.folder("folder"))
        environment.libraryBrowserModel.setFilter("Original")
        try select("folder/c.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == "Original Charlie"
            && self.environment.editorModel.state.status != .loading })
        XCTAssertNil(environment.editorModel.state.lastCopy, "A fresh open clears the earlier adoption")
        try select(copy.relativePath.string, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt == copy
            && self.environment.editorModel.state.status != .loading })
        drain()
        XCTAssertEqual(environment.libraryBrowserModel.filter, "Original")
        XCTAssertEqual(environment.libraryBrowserModel.selectedSection, .folder("folder"))
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        _ = try open(copy.relativePath.string)
        XCTAssertEqual(environment.libraryBrowserModel.filter, "Original")
        XCTAssertEqual(environment.libraryBrowserModel.selectedSection, .folder("folder"))
    }

    func testSettingsRefusesDirtySavingAndPendingEditorWithSpecificMessage() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let replacement = tools.directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let old = environment.editorModel
        replace(try widget("library-source", in: window), with: "Draft")
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.settings) != nil })
        environment.generalSettingsModel.chooseFolder(replacement.path)
        let settings = try XCTUnwrap(self.window(titled: LinuxStrings.settings))
        XCTAssertTrue(GTKTestSupport.spin { (try? self.widget("settings-library-message", in: settings)).map(self.label) == LinuxEditorStrings.librarySwitchRefused })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy)
        XCTAssertTrue(environment.editorModel === old)
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { old.state.status == .saving })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { old.state.status == .saved })
        environment.showSettings()
        drain()
        let switchMessage = try widget("settings-library-message", in: settings)
        XCTAssertEqual(gtk_widget_get_visible(switchMessage), 0, "Completed editor work must clear the stale refusal")
        old.edit("New draft")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { old.state.pendingDecision != nil })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy)
        try respond(.decision(.cancel))
        old.request(.close)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .editorBusy) // Awaiting the queued guard.
        XCTAssertTrue(GTKTestSupport.spin { old.state.pendingDecision != nil })
        old.resolveDecision(.discard, id: try XCTUnwrap(old.state.pendingDecision).id)
        XCTAssertTrue(GTKTestSupport.spin { old.state.prompt == nil })
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        XCTAssertTrue(environment.editorModel !== old)
        old.edit("Retired")
        XCTAssertNil(old.state.source)
    }

    func testReplacementAndShutdownDropQueuedEditorRepliesAndRetireSamePathInput() throws {
        holdWork()
        try files.write(Data("Old".utf8), at: "a.md")
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.library) != nil })
        let window = try XCTUnwrap(self.window(titled: LinuxStrings.library))
        try select("a.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .loading })
        let old = environment.editorModel
        var publications = 0
        old.addObserver { _ in publications += 1 }
        let replacement = tools.directory.appendingPathComponent("Second")
        let second = try RootedFileStore(root: replacement)
        try second.write(Data("New".utf8), at: "a.md")
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        heldWork?.runAll()
        drain()
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(contents(try widget("library-source", in: window)), "")
        XCTAssertEqual(try open("a.md"), window)
        XCTAssertEqual(contents(try widget("library-source", in: window)), "New")
        replace(try widget("library-source", in: window), with: "Late draft")
        environment.editorModel.save()
        let current = environment.editorModel
        environment.shutdown()
        heldWork?.runAll()
        drain()
        XCTAssertEqual(try second.read(at: "a.md"), Data("New".utf8))
        XCTAssertNotEqual(current.state.status, .saved)
        XCTAssertEqual(gtk_widget_get_visible(window), 0)
    }

    func testSettingsRetainsUnavailableSwitchMessageWhenRaisedAgain() throws {
        environment.shutdown()
        compose(watcherFactory: { _ in throw FileStoreError.ioFailure })
        let second = tools.directory.appendingPathComponent("Unavailable")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(window(titled: LinuxStrings.settings))
        environment.generalSettingsModel.chooseFolder(second.path)
        let outcome = LibrarySwitchOutcome.libraryUnavailable(.ioFailure)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.lastSwitchMessage == outcome })
        drain()
        let message = try widget("settings-library-message", in: settings)
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertEqual(label(message), GeneralSettingsStrings.message(for: outcome))
        XCTAssertNotEqual(gtk_widget_get_visible(message), 0)
        gtk_window_close(mp_window(settings))
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(settings) != 0 })
        drain()
        XCTAssertEqual(label(message), GeneralSettingsStrings.message(for: outcome))
        XCTAssertNotEqual(gtk_widget_get_visible(message), 0, "Idle editor work must not hide a startup failure")
    }

    func testNativeUndoAndCaretSurviveSaveNormalizationAndUnrelatedRefresh() throws {
        try files.write(Data("Body 👋 e\u{301}".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        let textBuffer = buffer(source)
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(textBuffer, &end)
        gtk_text_buffer_place_cursor(textBuffer, &end)
        gtk_text_buffer_begin_user_action(textBuffer)
        gtk_text_buffer_insert_at_cursor(textBuffer, "!", -1)
        gtk_text_buffer_end_user_action(textBuffer)
        let draft = contents(source)
        environment.libraryBrowserModel.setFilter("Body")
        drain()
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(textBuffer, &caret, gtk_text_buffer_get_insert(textBuffer))
        XCTAssertEqual(gtk_text_iter_get_offset(&caret), gtk_text_buffer_get_char_count(textBuffer))
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(textBuffer), 0)
        gtk_text_buffer_undo(textBuffer)
        XCTAssertEqual(contents(source), draft)
        XCTAssertEqual(environment.editorModel.state.source, draft)
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(textBuffer), 0)
        gtk_text_buffer_undo(textBuffer)
        XCTAssertEqual(contents(source), "Body 👋 e\u{301}")
    }

    func testCopyAdoptionAfterDeletionUsesAlternatePathAndRetiresNativeUndo() throws {
        let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal"
        try files.write(Data(original.utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        let selection = try XCTUnwrap(environment.editorModel.state.prompt)
        replace(source, with: original.replacingOccurrences(of: "Original", with: "Mine"))
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0)
        try files.delete(at: "a.md")
        try waitForConflict(.deleted)
        try respond(.conflict(.saveAsCopy))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.lastCopy != nil
            && self.environment.editorModel.state.conflict == nil })
        drain()
        let copy = try XCTUnwrap(environment.editorModel.state.lastCopy)
        XCTAssertNotEqual(copy.identity, selection.identity)
        XCTAssertEqual(copy.relativePath.string, "a 2.md")
        XCTAssertNil(try files.stamp(at: "a.md"))
        XCTAssertEqual(gtk_text_buffer_get_can_undo(buffer(source)), 0)
        XCTAssertEqual(contents(source), environment.editorModel.state.source)
    }

    func testNewerNativeDraftDuringSaveKeepsCloseGuardPending() throws {
        holdWork()
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        replace(source, with: "Submitted")
        try click("library-save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saving })
        replace(source, with: "Newer draft")
        gtk_window_close(mp_window(window))
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision?.action == .close })
        drain()
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertEqual(contents(source), "Newer draft")
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Submitted")
        try respond(.decision(.cancel))
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(environment.editorModel.state.source, "Newer draft")
        quit()
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != nil })
        try respond(.decision(.save))
        XCTAssertEqual(quitCount, 0)
        heldWork?.runAll()
        XCTAssertTrue(GTKTestSupport.spin { self.quitCount == 1 })
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Newer draft")
    }

    func testSourcePreeditKeepsNativeKeysAndDefersRefreshUntilCommit() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try open("a.md")
        let source = try widget("library-source", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_window_is_active(mp_window(window)) != 0 },
            "Window never became active; the display must support focus")
        gtk_widget_grab_focus(source)
        mp_test_emit_preedit_changed(source, "かな")
        for (key, flags) in [(UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)),
                             (UInt32(GDK_KEY_Return), GdkModifierType(rawValue: 0)),
                             (UInt32(GDK_KEY_s), GDK_CONTROL_MASK), (UInt32(GDK_KEY_w), GDK_CONTROL_MASK)] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, key, flags), 0)
        }
        environment.editorModel.edit("Updated while composing")
        drain()
        XCTAssertEqual(contents(source), "Original")
        mp_test_emit_preedit_changed(source, "")
        drain()
        XCTAssertEqual(contents(source), "Updated while composing")
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertNotNil(environment.editorModel.state.prompt)
    }

    func testPickerEditRevealsHiddenPromptInEditTabAfterGuardAndDeduplicatesPendingOpen() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        try files.write(Data("Beta".utf8), at: "folder/b.md")
        let window = try open("a.md")
        let tabs = try widget("library-editor-tabs", in: window)
        let fields = try widget("library-fields", in: window)
        let fieldsPage = try XCTUnwrap((0..<gtk_notebook_get_n_pages(mp_notebook(tabs))).first { index in
            guard let page = gtk_notebook_get_nth_page(mp_notebook(tabs), index) else { return false }
            return gtk_widget_is_ancestor(fields, page) != 0
        }, "Fields must have a notebook page")
        gtk_notebook_set_current_page(mp_notebook(tabs), fieldsPage)
        replace(try widget("library-source", in: window), with: "Draft alpha")
        try select("folder/b.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision != nil })
        environment.libraryBrowserModel.setFilter("Alpha")
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        environment.pickerModel.setQuery("Beta")
        environment.pickerModel.editSelected()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .closed && gtk_notebook_get_current_page(mp_notebook(tabs)) == 0 })
        XCTAssertTrue(environment.editorModel.state.queuedActions.isEmpty)
        try respond(.decision(.discard))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source == "Beta" })
        XCTAssertEqual(environment.libraryBrowserModel.filter, "")
        XCTAssertEqual(environment.libraryBrowserModel.selectedSection, .all)
        XCTAssertEqual(environment.libraryBrowserModel.selection?.relativePath.string, "folder/b.md")
    }

    private func compose(watcherFactory: ((URL) throws -> FileStoreWatcher)? = nil) {
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            libraryWatcherFactory: watcherFactory, backgroundWork: heldWork, clipboard: clipboard,
            launchURI: { _ in XCTFail("Editor launched an external URI") })
        MonkeysPawLinuxApp.installLibraryAction(application: application, environment: environment)
        MonkeysPawLinuxApp.installQuitAction(application: application, environment: environment, approved: { [weak self] in self?.quitCount += 1 })
    }

    private func holdWork() { environment.shutdown(); heldWork = EditorHeldWork(); compose() }

    private func open(_ path: String) throws -> GTK.Widget {
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.library).map { gtk_widget_get_visible($0) != 0 } == true })
        let window = try XCTUnwrap(self.window(titled: LinuxStrings.library))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.contains { $0.relativePath.string == path } })
        drain()
        try select(path, in: window)
        if let heldWork {
            XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .loading })
            heldWork.runAll()
        }
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == path
            && self.environment.editorModel.state.status != .loading && self.environment.libraryBrowserModel.selection?.relativePath.string == path })
        drain()
        return window
    }

    private func select(_ path: String, in window: GTK.Widget) throws {
        drain()
        let position = try XCTUnwrap(environment.libraryBrowserModel.rows.firstIndex { $0.relativePath.string == path })
        let list = try widget("library-list", in: window)
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
    }

    private func waitForConflict(_ kind: EditorConflict.Kind) throws {
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.conflict?.kind == kind
            && self.environment.editorModel.state.conflict?.isLoading == false && self.dialog != nil })
        let dialog = try XCTUnwrap(dialog)
        XCTAssertNotEqual(gtk_window_get_modal(mp_window(dialog)), 0)
        XCTAssertEqual(gtk_window_get_transient_for(mp_window(dialog)), self.window(titled: LinuxStrings.library).map(mp_window))
    }

    private func respond(_ response: LinuxEditorResponse) throws {
        drain()
        let alert = try XCTUnwrap(dialog)
        let button = try XCTUnwrap(find(in: alert) {
            mp_is_button($0) != 0 && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == response.title
        })
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.dialog != alert })
        drain()
    }

    private func quit() { g_action_group_activate_action(mp_action_group(application), ActionName.quit.rawValue, nil) }
    private var dialog: GTK.Widget? { windows.first { String(cString: gtk_widget_get_name($0)) == "library-editor-dialog" } }
    private func window(titled title: String) -> GTK.Widget? {
        windows.first { gtk_window_get_title(mp_window($0)).map { String(cString: $0) } == title }
    }
    private var windows: [GTK.Widget] {
        var result = [GTK.Widget]()
        let node = gtk_window_get_toplevels()
        for position in 0..<g_list_model_get_n_items(node) {
            guard let object = g_list_model_get_item(node, position) else { continue }
            result.append(object.assumingMemoryBound(to: GtkWidget.self))
            g_object_unref(object)
        }
        return result
    }
    private func widget(_ name: String, in window: GTK.Widget) throws -> GTK.Widget {
        try XCTUnwrap(find(in: window) { String(cString: gtk_widget_get_name($0)) == name }, "Missing \(name)")
    }
    private func find(in widget: GTK.Widget, matching predicate: (GTK.Widget) -> Bool) -> GTK.Widget? {
        if predicate(widget) { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = find(in: current, matching: predicate) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
    private func click(_ name: String, in window: GTK.Widget) throws {
        drain()
        XCTAssertNotEqual(gtk_widget_activate(try widget(name, in: window)), 0)
    }
    private func buffer(_ widget: GTK.Widget) -> UnsafeMutablePointer<GtkTextBuffer> { gtk_text_view_get_buffer(mp_text_view(widget))! }
    private func contents(_ widget: GTK.Widget) -> String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer(widget), &start, &end)
        let text = gtk_text_buffer_get_text(buffer(widget), &start, &end, 0)!
        defer { g_free(text) }
        return String(cString: text)
    }
    private func replace(_ widget: GTK.Widget, with text: String) {
        drain()
        XCTAssertNotEqual(gtk_text_view_get_editable(mp_text_view(widget)), 0)
        let buffer = buffer(widget)
        gtk_text_buffer_begin_user_action(buffer)
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        gtk_text_buffer_delete(buffer, &start, &end)
        gtk_text_buffer_insert(buffer, &start, text, Int32(text.utf8.count))
        gtk_text_buffer_end_user_action(buffer)
    }
    private func label(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }
    private func labels(_ widget: GTK.Widget) -> [String] {
        var result = [String]()
        if String(cString: g_type_name_from_instance(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self))) == "GtkLabel" { result.append(label(widget)) }
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += labels(current); child = gtk_widget_get_next_sibling(current) }
        return result
    }
    private func drain() {
        var drained = false
        GTK.onMainLoop { GTK.onMainLoop { drained = true } }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

final class LinuxEditorBackgroundWorkTests: XCTestCase {
    func testWorkerIsSerialOffUIAndReturnsThroughGLib() throws {
        try GTKTestSupport.requireDisplay()
        let worker = LinuxBackgroundWork()
        let main = GLibMainThread()
        var order: [Int] = []
        for position in 0..<3 {
            worker.run {
                XCTAssertFalse(Thread.isMainThread)
                main.run { XCTAssertTrue(Thread.isMainThread); order.append(position) }
            }
        }
        XCTAssertTrue(GTKTestSupport.spin { order.count == 3 })
        XCTAssertEqual(order, [0, 1, 2])
    }
}

private final class EditorHeldWork: BackgroundWork {
    private var work: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { self.work.append(work) }
    func runAll() { while !work.isEmpty { work.removeFirst()() } }
}

private final class EditorClipboard: Clipboard {
    private(set) var reads = 0
    private(set) var writes = 0
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { reads += 1; completion("Private clipboard") }
    func writeText(_ text: String) { writes += 1 }
}
#endif
