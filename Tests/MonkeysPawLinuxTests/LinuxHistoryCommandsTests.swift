#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxHistoryCommandsTests: XCTestCase {
    private let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var files: LinuxHistoryTestStore!
    private var data: LinuxHistoryTestStore!
    private var index: PromptIndex!
    private var library: LibraryService!
    private var editing: PromptEditingService!
    private var editor: EditorModel!
    private var browser: LibraryBrowserModel!
    private var controller: LinuxLibraryWindow!
    private var work: LinuxHistoryHeldWork!

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        files = try LinuxHistoryTestStore(root: tools.directory.appendingPathComponent("library"))
        data = try LinuxHistoryTestStore(root: tools.directory.appendingPathComponent("data"))
        let clock = SystemClock()
        let usage = UsageStore(files: data, clock: clock)
        library = LibraryService(library: files, data: data, clock: clock, entropy: SystemEntropy(), keyedStores: [usage])
        index = PromptIndex(service: library, usage: usage, clock: clock)
        let main = GLibMainThread()
        work = LinuxHistoryHeldWork()
        editing = PromptEditingService(library: library, index: index, work: work, main: main)
        editor = EditorModel(editing: editing, clock: clock, timeZone: { .current }, main: main)
        browser = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: main, editor: editor)
        controller = LinuxLibraryWindow(application: application, browser: browser, editor: editor,
            openFolder: { XCTFail("A file command launched an external URI") })
    }

    override func tearDown() {
        controller?.tearDown()
        browser?.deactivate()
        editor?.deactivate()
        editing?.deactivate()
        work?.releaseAll()
        if let application { GTKTestSupport.destroy(application) }
        controller = nil
        browser = nil
        editor = nil
        editing = nil
        application = nil
        library = nil
        index = nil
        work = nil
        files = nil
        data = nil
        tools = nil
    }

    func testHistoryTabLoadsNewestFirstWithMetadataAndReadOnlyExactPreview() throws {
        let sources = [Data("Previous\r\n".utf8), Data("---\ntitle: [broken\n---\nForensic".utf8),
            Data([0xff, 0xfe]), Data("---\nformat: 2\n---\nFuture".utf8),
            Data(repeating: 65, count: Limits.maxPromptBytes + 1)]
        let names = try sources.enumerated().map { try snapshot($0.element, sequence: $0.offset) }
        let window = try open()
        let before = editor.state.source
        try showHistory(in: window)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), names.reversed())
        XCTAssertEqual(editor.state.history.revisions.map(\.byteCount), sources.reversed().map(\.count))
        let list = try widget("library-history-list", in: window)
        let preview = try widget("library-history-preview", in: window)
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(preview)), 0)
        XCTAssertEqual(gtk_text_view_get_monospace(mp_text_view(preview)), 1)
        for (position, row) in editor.state.history.revisions.enumerated() {
            let nativeRow = try XCTUnwrap(gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
            XCTAssertEqual(labels(UnsafeMutableRawPointer(nativeRow).assumingMemoryBound(to: GtkWidget.self)),
                [LinuxEditorStrings.timestamp(row.revision.timestamp), LinuxEditorStrings.revisionMetadata(row)])
            try selectRevision(position, in: window)
            XCTAssertEqual(contents(preview), row.source ?? "")
            let status = label(try widget("library-history-status", in: window))
            if let reason = row.restoreFailure { XCTAssertTrue(status.contains(LinuxEditorStrings.restoreRefusal(reason))) }
            if row.source == nil {
                XCTAssertTrue(status.contains(row.byteCount > Limits.maxPromptBytes
                    ? LinuxEditorStrings.oversizedPreview : LinuxEditorStrings.noUTF8Preview))
            }
            XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("library-restore", in: window)), 0)
            XCTAssertEqual(editor.state.source, before)
            XCTAssertFalse(editor.state.isDirty)
        }
    }

    func testRestoreUpdatesEditorAndHistoryAndKeepsIdentity() throws {
        let body = "  Previous {{field}}\r\n\r\n"
        let filename = try snapshot(Data(body.utf8))
        let window = try open()
        let selection = editor.state.prompt
        try showHistory(in: window)
        try selectRevision(0, in: window)
        try click("library-restore", in: window)
        wait { self.editor.state.history.revisions.count == 2 && self.editor.state.status == .saved }
        drain()
        XCTAssertEqual(editor.state.prompt, selection)
        XCTAssertEqual(browser.selection, selection)
        XCTAssertEqual(Array(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body.utf8), Array(body.utf8))
        XCTAssertEqual(contents(try widget("library-source", in: window)), editor.state.source)
        XCTAssertEqual(editor.state.history.selectedRevision?.filename, filename)
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.restored)
        XCTAssertFalse(editor.state.isDirty)
        let list = try widget("library-history-list", in: window)
        XCTAssertNotNil(gtk_list_box_get_row_at_index(mp_list_box(list), 1))
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), body)
    }

    func testHistorySelectedDuringFailedCommandLoadsAfterCompletion() throws {
        let filename = try snapshot(Data("Earlier".utf8))
        try files.write(Data("Occupied".utf8), at: "occupied.md")
        let window = try open()
        let prompt = editor.state.prompt
        try click("library-rename", in: window)
        try confirm(input: "occupied.md")
        XCTAssertEqual(editor.state.status, .commandRunning)
        gtk_notebook_set_current_page(mp_notebook(try widget("library-editor-tabs", in: window)), 3)
        drain(releaseWork: false)
        XCTAssertFalse(editor.state.history.isLoading)
        wait { self.editor.state.status != .commandRunning && !self.editor.state.history.isLoading
            && self.editor.state.history.revisions.count == 1 }
        drain()
        XCTAssertEqual(editor.state.prompt, prompt)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [filename])
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.occupied)
        try selectRevision(0, in: window)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
    }

    func testPreviouslyLoadedHistorySelectedDuringFailedCommandRefreshesAfterCompletion() throws {
        let first = try snapshot(Data("Earlier".utf8))
        try files.write(Data("Occupied".utf8), at: "occupied.md")
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        let tabs = mp_notebook(try widget("library-editor-tabs", in: window))
        gtk_notebook_set_current_page(tabs, 0)
        let second = try snapshot(Data("Later".utf8), sequence: 1)
        try click("library-rename", in: window)
        try confirm(input: "occupied.md")
        XCTAssertEqual(editor.state.status, .commandRunning)
        gtk_notebook_set_current_page(tabs, 3)
        drain(releaseWork: false)
        XCTAssertFalse(editor.state.history.isLoading)
        wait { self.editor.state.status != .commandRunning && !self.editor.state.history.isLoading
            && self.editor.state.history.revisions.count == 2 }
        drain()
        XCTAssertEqual(editor.state.prompt?.relativePath, "a.md")
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [second, first])
        XCTAssertEqual(editor.state.history.selectedRevision?.filename, first)
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.occupied)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
    }

    func testFirstSaveReloadsHistoryAtSamePathWithoutResettingSourceSession() throws {
        let window = try open(source: "Plain")
        let before = try XCTUnwrap(editor.state.prompt)
        let tabs = mp_notebook(try widget("library-editor-tabs", in: window))
        gtk_notebook_set_current_page(tabs, 3)
        wait { !self.editor.state.history.isLoading }
        drain()
        XCTAssertTrue(editor.state.history.revisions.isEmpty)
        let source = try widget("library-source", in: window)
        let buffer = try XCTUnwrap(gtk_text_view_get_buffer(mp_text_view(source)))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
        gtk_text_buffer_begin_user_action(buffer)
        gtk_text_buffer_insert_at_cursor(buffer, " edited", -1)
        gtk_text_buffer_end_user_action(buffer)
        drain()
        let draft = contents(source)
        try click("library-save", in: window)
        wait { self.editor.state.status == .saved && !self.editor.state.history.isLoading
            && self.editor.state.history.revisions.count == 1 }
        drain()
        let assigned = try XCTUnwrap(editor.state.prompt)
        guard case .assigned = assigned.identity else { return XCTFail("Expected first-save identity") }
        XCTAssertEqual(assigned.relativePath, before.relativePath)
        XCTAssertNotEqual(assigned.identity, before.identity)
        XCTAssertEqual(browser.selection, assigned)
        XCTAssertEqual(gtk_notebook_get_current_page(tabs), 3)
        let revision = try XCTUnwrap(editor.state.history.revisions.first)
        XCTAssertEqual(revision.revision.identity, assigned.identity)
        XCTAssertEqual(revision.source, "Plain")
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &caret, gtk_text_buffer_get_insert(buffer))
        XCTAssertEqual(gtk_text_iter_get_offset(&caret), gtk_text_buffer_get_char_count(buffer))
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(buffer), 0)
        gtk_text_buffer_undo(buffer)
        XCTAssertEqual(contents(source), draft)
        XCTAssertEqual(editor.state.source, draft)
        gtk_text_buffer_redo(buffer)
        drain()
        XCTAssertFalse(editor.state.isDirty)
        try selectRevision(0, in: window)
        try click("library-rename", in: window)
        try confirm(input: "renamed.md")
        wait { self.editor.state.prompt?.relativePath == "renamed.md" && !self.editor.state.history.isLoading
            && self.editor.state.history.revisions.first?.revision == revision.revision }
        drain()
        XCTAssertEqual(editor.state.prompt?.identity, assigned.identity)
        XCTAssertEqual(browser.selection, editor.state.prompt)
        try selectRevision(0, in: window)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Plain")
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "renamed.md"), filename: "renamed.md").body, draft)
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.renamed)
    }

    func testHistoryReloadsWhenSamePathGainsAssignedIdentity() throws {
        let filename = try snapshot(Data("Earlier".utf8))
        let window = try open(source: "Plain")
        let before = try XCTUnwrap(editor.state.prompt)
        gtk_notebook_set_current_page(mp_notebook(try widget("library-editor-tabs", in: window)), 3)
        wait { !self.editor.state.history.isLoading }
        drain()
        XCTAssertTrue(editor.state.history.revisions.isEmpty)
        try files.write(Data("---\nid: \(id)\n---\nPlain externally assigned".utf8), at: "a.md")
        try index.rebuild()
        wait { self.editor.state.prompt?.identity != before.identity && self.editor.state.status != .loading
            && !self.editor.state.history.isLoading && self.editor.state.history.revisions.count == 1 }
        drain()
        let assigned = try XCTUnwrap(editor.state.prompt)
        guard case .assigned = assigned.identity else { return XCTFail("Expected external identity assignment") }
        XCTAssertEqual(assigned.relativePath, before.relativePath)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [filename])
        XCTAssertEqual(editor.state.history.revisions.first?.revision.identity, assigned.identity)
        try selectRevision(0, in: window)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
    }

    func testHistoryReloadsAfterCommittedSaveWhileTabStaysOpen() throws {
        let filename = try snapshot(Data("Earlier".utf8))
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        let prompt = editor.state.prompt
        let original = try XCTUnwrap(editor.state.source)
        editor.edit(original + " saved")
        drain()
        try click("library-save", in: window)
        XCTAssertEqual(editor.state.status, .saving)
        wait { self.editor.state.status == .saved && !self.editor.state.history.isLoading
            && self.editor.state.history.revisions.count == 2 }
        drain()
        XCTAssertEqual(editor.state.prompt, prompt)
        XCTAssertEqual(gtk_notebook_get_current_page(mp_notebook(try widget("library-editor-tabs", in: window))), 3)
        XCTAssertEqual(editor.state.history.revisions.first?.source, original)
        XCTAssertEqual(editor.state.history.selectedRevision?.filename, filename)
        let list = try widget("library-history-list", in: window)
        XCTAssertNotNil(gtk_list_box_get_row_at_index(mp_list_box(list), 1))
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body, "Original saved")
    }

    func testHistoryReloadsWhenLibraryReturnsWithoutChangingTabs() throws {
        let first = try snapshot(Data("Earlier".utf8))
        let window = try open()
        let tabs = mp_notebook(try widget("library-editor-tabs", in: window))
        controller.setLibraryAvailable(false)
        gtk_notebook_set_current_page(tabs, 3)
        drain(releaseWork: false)
        XCTAssertFalse(editor.state.history.isLoading)
        XCTAssertTrue(editor.state.history.revisions.isEmpty)
        controller.setLibraryAvailable(true)
        wait { !self.editor.state.history.isLoading && self.editor.state.history.revisions.count == 1 }
        drain()
        try selectRevision(0, in: window)
        data.listFailure = .ioFailure
        try click("library-history-refresh", in: window)
        wait { self.editor.state.history.failure == .fileStore(.ioFailure) }
        controller.setLibraryAvailable(false)
        data.listFailure = nil
        let second = try snapshot(Data("Later".utf8), sequence: 1)
        controller.setLibraryAvailable(true)
        wait { !self.editor.state.history.isLoading && self.editor.state.history.failure == nil
            && self.editor.state.history.revisions.count == 2 }
        drain()
        XCTAssertEqual(gtk_notebook_get_current_page(tabs), 3)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [second, first])
        XCTAssertEqual(editor.state.history.selectedRevision?.filename, first)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
        let lists = data.lists
        controller.setLibraryAvailable(true)
        XCTAssertFalse(editor.state.history.isLoading, "Unchanged availability does not reload History")
        drain()
        XCTAssertEqual(data.lists, lists)
    }

    func testAvailabilityRecoveryDuringSamePromptLoadRetriesHistoryAfterCompletion() throws {
        let first = try snapshot(Data("Earlier".utf8))
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        let prompt = editor.state.prompt
        data.listFailure = .ioFailure
        try click("library-history-refresh", in: window)
        wait { self.editor.state.history.failure == .fileStore(.ioFailure) }
        try click("library-revert", in: window)
        XCTAssertEqual(editor.state.status, .loading)
        controller.setLibraryAvailable(false)
        data.listFailure = nil
        let second = try snapshot(Data("Later".utf8), sequence: 1)
        let lists = data.lists
        controller.setLibraryAvailable(true)
        XCTAssertFalse(editor.state.history.isLoading, "History waits for the prompt load")
        wait { self.editor.state.status != .loading && !self.editor.state.history.isLoading
            && self.editor.state.history.failure == nil && self.editor.state.history.revisions.count == 2 }
        drain()
        XCTAssertEqual(editor.state.prompt, prompt)
        XCTAssertNil(editor.state.history.failure)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [second, first])
        XCTAssertEqual(editor.state.history.selectedRevision?.filename, first)
        XCTAssertEqual(data.lists, lists + 1)
        XCTAssertEqual(gtk_notebook_get_current_page(mp_notebook(try widget("library-editor-tabs", in: window))), 3)
        XCTAssertNotNil(gtk_list_box_get_row_at_index(mp_list_box(try widget("library-history-list", in: window)), 1))
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
    }

    func testAvailabilityRecoveryRetiresAnInFlightHistoryFailure() throws {
        let filename = try snapshot(Data("Earlier".utf8))
        let window = try open()
        data.listFailure = .ioFailure
        let lists = data.lists
        gtk_notebook_set_current_page(mp_notebook(try widget("library-editor-tabs", in: window)), 3)
        XCTAssertTrue(editor.state.history.isLoading)
        // Compute the old failure but leave its reply queued on GLib.
        work.releaseAll()
        XCTAssertEqual(data.lists, lists + 1)
        XCTAssertTrue(editor.state.history.isLoading)
        controller.setLibraryAvailable(false)
        data.listFailure = nil
        controller.setLibraryAvailable(true)
        wait { !self.editor.state.history.isLoading && self.editor.state.history.failure == nil
            && self.editor.state.history.revisions.count == 1 }
        drain()
        XCTAssertNil(editor.state.history.failure)
        XCTAssertEqual(editor.state.history.revisions.map(\.revision.filename), [filename])
        _ = try XCTUnwrap(editor.state.history.revisions.first)
        try selectRevision(0, in: window)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Earlier")
    }

    func testRestoreHistoryMaintenanceWarningReportsCommittedWrite() throws {
        for sequence in 0..<Limits.historyCapPerPrompt { try snapshot(Data("Previous \(sequence)".utf8), sequence: sequence) }
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        data.deleteFailure = .ioFailure
        try click("library-restore", in: window)
        wait { self.editor.state.historyMaintenanceFailed && !self.editor.state.history.isLoading }
        drain()
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.historyWarning)
        XCTAssertFalse(editor.state.isDirty)
        XCTAssertEqual(editor.state.history.revisions.count, Limits.historyCapPerPrompt + 1)
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").body,
            "Previous \(Limits.historyCapPerPrompt - 1)")
    }

    func testMovedDestinationConflictKeepsSelectionAndRecoveryAtNewPath() throws {
        let window = try open()
        let theirs = Data("---\nid: \(id)\n---\nExternal at destination".utf8)
        files.replaceMovedDestination = theirs
        try click("library-move", in: window)
        try confirm(input: "new")
        wait { self.editor.state.prompt?.relativePath.string == "new/a.md"
            && self.editor.state.conflict?.theirsSource != nil && self.dialog("library-editor-dialog") != nil }
        drain()
        XCTAssertEqual(browser.selection, editor.state.prompt)
        XCTAssertNil(try files.stamp(at: "a.md"))
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.relocated)
        try respond(.conflict(.takeTheirs))
        wait { self.editor.state.conflict == nil }
        XCTAssertEqual(try files.read(at: "new/a.md"), theirs)
        XCTAssertNil(try files.stamp(at: "a.md"))
    }

    func testReopeningSamePromptInHistoryReloadsItsRevisions() throws {
        try snapshot(Data("Previous".utf8))
        let window = try open()
        try showHistory(in: window)
        controller.hide()
        wait { self.editor.state.prompt == nil && !self.controller.isVisible }
        _ = try open()
        XCTAssertEqual(gtk_notebook_get_current_page(mp_notebook(try widget("library-editor-tabs", in: window))), 3)
        wait { self.editor.state.history.revisions.count == 1 && !self.editor.state.history.isLoading }
    }

    func testForensicFutureAndMissingRevisionsReturnTypedRefusalsWithoutWriting() throws {
        let fixtures: [(Data, PromptWriteError)] = [
            (Data("---\ntitle: [broken\n---\nBroken".utf8), .invalidPrompt),
            (Data([0xff]), .invalidPrompt),
            (Data(repeating: 65, count: Limits.maxPromptBytes + 1), .invalidPrompt),
            (Data("---\nformat: 2\n---\nFuture".utf8), .unsupportedFormat(try XCTUnwrap(PromptFormatVersion(2))))]
        for (sequence, fixture) in fixtures.enumerated() { try snapshot(fixture.0, sequence: sequence) }
        let window = try open()
        let original = try files.read(at: "a.md")
        try showHistory(in: window)
        for (position, fixture) in fixtures.reversed().enumerated() {
            try selectRevision(position, in: window)
            try click("library-restore", in: window)
            wait { self.commandStatus(in: window) == LinuxEditorStrings.restoreRefusal(fixture.1) }
            XCTAssertEqual(try files.read(at: "a.md"), original)
            XCTAssertEqual(editor.state.history.revisions.count, fixtures.count)
        }
        let selected = try XCTUnwrap(editor.state.history.selectedRevision)
        try data.delete(at: "history/\(id)/\(selected.filename)")
        try click("library-restore", in: window)
        wait { self.commandStatus(in: window) == LinuxEditorStrings.revisionMissing }
        XCTAssertEqual(try files.read(at: "a.md"), original)
    }

    func testStaleRestoreAndEachFileCommandOpenTheExistingConflictDialog() throws {
        try snapshot(Data("Previous".utf8))
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        let operations = ["library-restore", "library-rename", "library-move", "library-delete"]
        for (position, operation) in operations.enumerated() {
            if operation != "library-restore" { try click(operation, in: window) }
            let theirs = "---\nid: \(id)\n---\nExternal \(position)"
            try files.write(Data(theirs.utf8), at: "a.md") // No index notification: exercise the stale stamp itself.
            if operation == "library-restore" { try click(operation, in: window) }
            else { try confirm(input: operation == "library-delete" ? nil : operation == "library-rename" ? "renamed.md" : "folder") }
            wait { self.editor.state.conflict?.theirsSource == theirs && self.dialog("library-editor-dialog") != nil }
            XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.changed)
            XCTAssertEqual(try files.read(at: "a.md"), Data(theirs.utf8))
            try respond(.conflict(.takeTheirs))
            wait { self.editor.state.conflict == nil && self.editor.state.source == theirs }
        }
    }

    func testRenameAndMoveFollowLocalSelectionKeepBytesAndDeleteClearsEditorKeepingHistory() throws {
        let window = try open(source: "---\ntitle: Keep title\n---\nOriginal")
        let original = try files.read(at: "a.md")
        let selection = editor.state.prompt
        try click("library-rename", in: window)
        let form = try XCTUnwrap(dialog("library-file-command-dialog"))
        XCTAssertEqual(String(cString: mp_entry_text(try widget("library-command-input", in: form))), "a.md")
        try confirm(input: "renamed.md")
        wait { self.editor.state.prompt?.relativePath.string == "renamed.md" && self.browser.selection == self.editor.state.prompt }
        drain()
        XCTAssertNotEqual(editor.state.prompt?.identity, selection?.identity)
        XCTAssertNil(try files.stamp(at: "a.md"))
        XCTAssertEqual(try files.read(at: "renamed.md"), original)
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.renamed)
        try click("library-move", in: window)
        try confirm(input: "new/deep")
        wait { self.editor.state.prompt?.relativePath.string == "new/deep/renamed.md" && self.browser.selection == self.editor.state.prompt }
        drain()
        XCTAssertEqual(try files.read(at: "new/deep/renamed.md"), original)
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.moved)
        try click("library-move", in: window)
        try confirm(input: "")
        wait { self.editor.state.prompt?.relativePath.string == "renamed.md" }
        drain()
        // Save once to assign an id and create a real history revision before deletion.
        editor.edit(editor.state.source! + "\nEdited")
        editor.save()
        wait { self.editor.state.status == .saved }
        let identity = try XCTUnwrap(editor.state.prompt?.identity)
        let history = try library.history(for: identity)
        XCTAssertEqual(history.count, 1)
        try click("library-delete", in: window)
        let confirmation = try XCTUnwrap(dialog("library-file-command-dialog"))
        XCTAssertEqual(label(try widget("library-command-message", in: confirmation)), LinuxEditorStrings.deleteHint("renamed.md"))
        XCTAssertEqual(gtk_window_get_focus(mp_window(confirmation)), try widget("library-command-cancel", in: confirmation))
        try click("library-command-cancel", in: confirmation)
        drain()
        XCTAssertNotNil(editor.state.prompt)
        try click("library-delete", in: window)
        try confirm()
        wait { self.editor.state.prompt == nil && self.browser.selection == nil }
        drain()
        XCTAssertNil(try files.stamp(at: "renamed.md"))
        XCTAssertEqual(try library.history(for: identity), history)
        XCTAssertEqual(contents(try widget("library-source", in: window)), "")
        XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.deleted)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
    }

    func testMoveChooserOffersKnownFoldersAndRootAlongsideTypedNewFolder() throws {
        try files.write(Data("Other".utf8), at: "existing/deep/b.md")
        let window = try open()
        try click("library-move", in: window)
        let form = try XCTUnwrap(dialog("library-file-command-dialog"))
        let chooser = try widget("library-command-folders", in: form)
        let input = try widget("library-command-input", in: form)
        gtk_combo_box_set_active(mp_combo_box(chooser), 2)
        XCTAssertEqual(String(cString: mp_entry_text(input)), "existing/deep")
        gtk_combo_box_set_active(mp_combo_box(chooser), 0)
        XCTAssertEqual(String(cString: mp_entry_text(input)), "")
        gtk_combo_box_set_active(mp_combo_box(chooser), 1)
        try confirm()
        wait { self.editor.state.prompt?.relativePath.string == "existing/a.md" && self.browser.selection == self.editor.state.prompt }
        XCTAssertEqual(browser.selection, editor.state.prompt)
    }

    func testOccupiedInvalidAndIOFailuresKeepThePromptAndShowTypedStatus() throws {
        try files.write(Data("Occupied".utf8), at: "occupied.md")
        try files.write(Data("Occupied folder".utf8), at: "folder/a.md")
        let window = try open()
        let original = try files.read(at: "a.md")
        let commands: [(String, String, String)] = [
            ("library-rename", "occupied.md", LinuxEditorStrings.occupied),
            ("library-move", "folder", LinuxEditorStrings.occupied),
            ("library-rename", "bad/name.md", LinuxEditorStrings.invalidDestination),
            ("library-rename", "_ignored.md", LinuxEditorStrings.invalidDestination),
            ("library-move", "../outside", LinuxEditorStrings.invalidDestination)]
        for (action, input, message) in commands {
            try click(action, in: window)
            try confirm(input: input)
            wait { self.commandStatus(in: window) == message }
            XCTAssertEqual(try files.read(at: "a.md"), original)
            XCTAssertEqual(browser.selection, editor.state.prompt)
        }
        XCTAssertEqual(try files.read(at: "occupied.md"), Data("Occupied".utf8))
        XCTAssertEqual(try files.read(at: "folder/a.md"), Data("Occupied folder".utf8))
        for command in ["library-rename", "library-move", "library-delete"] {
            if command == "library-delete" { files.deleteFailure = .ioFailure }
            else { files.moveFailure = .ioFailure }
            try click(command, in: window)
            try confirm(input: command == "library-delete" ? nil : command == "library-rename" ? "new.md" : "new")
            wait { self.editor.state.status == .failed(.editing(.fileStore(.ioFailure))) }
            drain()
            XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.editingFailure(.fileStore(.ioFailure)))
            XCTAssertEqual(try files.read(at: "a.md"), original)
        }
    }

    func testMissingFilesAndReadOnlyReplacementAreReportedWithoutResurrectionOrOverwrite() throws {
        let window = try open()
        let originals = ["library-rename", "library-move", "library-delete"]
        for command in originals {
            try click(command, in: window)
            try files.delete(at: "a.md")
            try confirm(input: command == "library-delete" ? nil : command == "library-rename" ? "new.md" : "new")
            wait { self.editor.state.conflict?.kind == .deleted && self.dialog("library-editor-dialog") != nil }
            XCTAssertEqual(commandStatus(in: window), LinuxEditorStrings.missing)
            XCTAssertNil(try files.stamp(at: "a.md"))
            try respond(.conflict(.keepMine))
            wait { self.editor.state.conflict == nil && self.editor.state.status == .saved }
        }
        try click("library-rename", in: window)
        let future = Data("---\nid: \(id)\nformat: 2\n---\nFuture".utf8)
        try files.write(future, at: "a.md")
        try confirm(input: "new.md")
        wait { self.dialog("library-editor-dialog") != nil }
        try respond(.conflict(.takeTheirs))
        wait { self.editor.state.readOnlyReason != nil }
        XCTAssertEqual(try files.read(at: "a.md"), future)
        for name in ["library-rename", "library-move", "library-delete", "library-restore"] {
            XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0)
        }
    }

    func testEveryCommandAndRestoreUsesSaveDiscardCancelGuard() throws {
        try snapshot(Data("Previous".utf8))
        let window = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        let selection = editor.state.prompt
        let original = try files.read(at: "a.md")
        let commands: [(String, EditorDiscardAction)] = [("library-rename", .rename), ("library-move", .move),
            ("library-delete", .delete), ("library-restore", .revert)]
        for (command, action) in commands {
            editor.edit("My unsaved draft")
            drain()
            try click(command, in: window)
            if command != "library-restore" { try confirm(input: command == "library-delete" ? nil : command == "library-rename" ? "new.md" : "new") }
            wait { self.editor.state.pendingDecision?.action == action && self.dialog("library-editor-dialog") != nil }
            try respond(.decision(.cancel))
            wait { self.editor.state.pendingDecision == nil }
            XCTAssertEqual(editor.state.source, "My unsaved draft")
            XCTAssertEqual(browser.selection, selection)
            XCTAssertEqual(try files.read(at: "a.md"), original)
        }
        try click("library-rename", in: window)
        try confirm(input: "renamed.md")
        wait { self.dialog("library-editor-dialog") != nil }
        try respond(.decision(.save))
        wait { self.editor.state.prompt?.relativePath.string == "renamed.md" }
        XCTAssertEqual(PromptCodec.parseFile(try files.read(at: "renamed.md"), filename: "renamed.md").body, "My unsaved draft")
        editor.edit("Discard this draft")
        drain()
        try click("library-move", in: window)
        try confirm(input: "new")
        wait { self.dialog("library-editor-dialog") != nil }
        try respond(.decision(.discard))
        wait { self.editor.state.prompt?.relativePath.string == "new/renamed.md" }
        XCTAssertEqual(editor.state.source.map { PromptCodec.parse($0, filename: "renamed.md").body }, "My unsaved draft")
    }

    func testControlsDisableForNoPromptReadOnlyUnavailableSavingGuardAndRunningCommand() throws {
        controller.show()
        drain()
        let window = try libraryWindow()
        let actions = ["library-rename", "library-move", "library-delete", "library-restore"]
        for name in actions { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        try snapshot(Data("Previous".utf8))
        _ = try open()
        try showHistory(in: window)
        try selectRevision(0, in: window)
        for name in actions { XCTAssertNotEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        controller.setLibraryAvailable(false)
        for name in actions + ["library-history-refresh"] { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        controller.setLibraryAvailable(true)
        try click("library-rename", in: window)
        try confirm(input: "renamed.md")
        XCTAssertTrue(GTKTestSupport.spin { self.editor.state.status == .commandRunning })
        drain(releaseWork: false)
        for name in actions + ["library-history-refresh"] { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        wait { self.editor.state.status != .commandRunning }
        editor.edit(editor.state.source! + "Draft")
        editor.save()
        drain(releaseWork: false)
        for name in actions { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        wait { self.editor.state.status == .saved }
        editor.edit(editor.state.source! + "Dirty")
        editor.request(.revert)
        wait { self.editor.state.pendingDecision != nil }
        for name in actions { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        try respond(.decision(.discard))
        wait { self.editor.state.pendingDecision == nil }
        for (path, bytes) in [("future.md", Data("---\nformat: 2\n---\nFuture".utf8)),
                              ("bytes.md", Data([0xff])), ("large.md", Data(repeating: 65, count: Limits.maxPromptBytes + 1))] {
            try files.write(bytes, at: path)
            _ = try open(path: path, source: nil)
            for name in actions { XCTAssertEqual(gtk_widget_get_sensitive(try widget(name, in: window)), 0) }
        }
    }

    func testFormsCancelOnEscapeCloseUnavailableRebindAndRespondOnce() throws {
        let window = try open()
        let original = try files.read(at: "a.md")
        for command in ["library-rename", "library-move", "library-delete"] {
            for nativeClose in [false, true] {
                try click(command, in: window)
                let form = try XCTUnwrap(dialog("library-file-command-dialog"))
                XCTAssertEqual(gtk_window_get_modal(mp_window(form)), 1)
                if nativeClose { gtk_window_close(mp_window(form)) }
                else { XCTAssertNotEqual(mp_test_emit_key_pressed(form, UInt32(GDK_KEY_Escape), GDK_LOCK_MASK), 0) }
                drain()
                XCTAssertNil(dialog("library-file-command-dialog"))
                XCTAssertNil(editor.state.pendingDecision)
                XCTAssertEqual(try files.read(at: "a.md"), original)
            }
        }
        try click("library-rename", in: window)
        controller.setLibraryAvailable(false)
        XCTAssertNil(dialog("library-file-command-dialog"))
        controller.setLibraryAvailable(true)
        try click("library-move", in: window)
        controller.rebind(browser: browser, editor: editor, imports: nil)
        XCTAssertNil(dialog("library-file-command-dialog"))
        drain()
        try click("library-delete", in: window)
        let form = try XCTUnwrap(dialog("library-file-command-dialog"))
        // A reentrant native close after confirmation must not cancel or repeat it.
        let confirm = try widget("library-command-confirm", in: form)
        g_object_ref(form)
        defer { g_object_unref(form) }
        GTK.onSignal(confirm, "clicked") { gtk_window_close(mp_window(form)) }
        XCTAssertNotEqual(gtk_widget_activate(confirm), 0)
        wait { self.editor.state.prompt == nil }
        XCTAssertNil(try files.stamp(at: "a.md"))
        XCTAssertEqual(files.deletes, 1)
    }

    func testHistoryFailureRefreshAndSelectionChangeDoNotKeepStalePreview() throws {
        try snapshot(Data("Previous".utf8))
        let window = try open()
        data.listFailure = .ioFailure
        try showHistory(in: window)
        XCTAssertEqual(editor.state.history.failure, .fileStore(.ioFailure))
        XCTAssertTrue(label(try widget("library-history-status", in: window)).contains(LinuxEditorStrings.editingFailure(.fileStore(.ioFailure))))
        data.listFailure = nil
        try click("library-history-refresh", in: window)
        wait { self.editor.state.history.revisions.count == 1 && !self.editor.state.history.isLoading }
        try selectRevision(0, in: window)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "Previous")
        _ = try open(path: "other.md", source: "Other")
        wait { !self.editor.state.history.isLoading }
        drain()
        XCTAssertTrue(editor.state.history.revisions.isEmpty)
        XCTAssertEqual(contents(try widget("library-history-preview", in: window)), "")
        XCTAssertEqual(label(try widget("library-history-status", in: window)), LinuxEditorStrings.noHistory)
    }

    @discardableResult
    private func snapshot(_ bytes: Data, sequence: Int = 0) throws -> String {
        let filename = "20261010T130700.123Z-" + String(format: "%06d", sequence) + ".md"
        try data.write(bytes, at: "history/\(id)/\(filename)")
        return filename
    }

    private func open(path: String = "a.md", source: String? = nil) throws -> GTK.Widget {
        if try files.stamp(at: path) == nil || source != nil {
            try files.write(Data((source ?? "---\nid: \(id)\ntitle: Keep title\n---\nOriginal").utf8), at: path)
        }
        try index.rebuild()
        controller.show()
        let window = try libraryWindow()
        drain()
        let position = try XCTUnwrap(browser.rows.firstIndex { $0.relativePath.string == path })
        let list = try widget("library-list", in: window)
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
        wait { self.editor.state.prompt?.relativePath.string == path && self.editor.state.status != .loading && self.browser.selection == self.editor.state.prompt }
        drain()
        return window
    }

    private func showHistory(in window: GTK.Widget) throws {
        gtk_notebook_set_current_page(mp_notebook(try widget("library-editor-tabs", in: window)), 3)
        wait { !self.editor.state.history.isLoading && (self.editor.state.history.failure != nil || !self.editor.state.history.revisions.isEmpty) }
        drain()
    }

    private func selectRevision(_ position: Int, in window: GTK.Widget) throws {
        let list = try widget("library-history-list", in: window)
        let preview = try widget("library-history-preview", in: window)
        wait { gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)) != nil }
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
        let revision = editor.state.history.revisions[position]
        wait { self.editor.state.history.selectedRevision == revision.revision
            && self.contents(preview) == (revision.source ?? "") }
        drain()
    }

    private func confirm(input: String? = nil) throws {
        let form = try XCTUnwrap(dialog("library-file-command-dialog"))
        if let input { mp_entry_set_text(try widget("library-command-input", in: form), input) }
        try click("library-command-confirm", in: form)
    }

    private func respond(_ response: LinuxEditorResponse) throws {
        let form = try XCTUnwrap(dialog("library-editor-dialog"))
        let button = try XCTUnwrap(find(form) { mp_is_button($0) != 0 && String(cString: gtk_button_get_label(mp_button($0))) == response.title })
        activate(button)
        drain()
    }

    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(GTKTestSupport.spin { self.work.releaseAll(); return predicate() }, file: file, line: line)
    }

    private func drain(releaseWork: Bool = true) {
        var drained = false
        GTK.onMainLoop { GTK.onMainLoop { drained = true } }
        XCTAssertTrue(GTKTestSupport.spin {
            if releaseWork { self.work.releaseAll() }
            return drained
        })
    }

    private func libraryWindow() throws -> GTK.Widget {
        try XCTUnwrap(windows.first { gtk_window_get_title(mp_window($0)).map { String(cString: $0) } == LinuxStrings.library })
    }
    private func dialog(_ name: String) -> GTK.Widget? { windows.first { String(cString: gtk_widget_get_name($0)) == name } }
    private var windows: [GTK.Widget] {
        let model = gtk_window_get_toplevels()
        return (0..<g_list_model_get_n_items(model)).compactMap { position in
            guard let object = g_list_model_get_item(model, position) else { return nil }
            defer { g_object_unref(object) }
            return object.assumingMemoryBound(to: GtkWidget.self)
        }
    }
    private func find(_ widget: GTK.Widget, matching predicate: (GTK.Widget) -> Bool) -> GTK.Widget? {
        if predicate(widget) { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = find(current, matching: predicate) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
    private func widget(_ name: String, in window: GTK.Widget) throws -> GTK.Widget {
        try XCTUnwrap(find(window) { String(cString: gtk_widget_get_name($0)) == name }, "Missing \(name)")
    }
    private func click(_ name: String, in window: GTK.Widget) throws {
        let button = try widget(name, in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(button) != 0 }, "\(name) stays disabled")
        activate(button)
        drain(releaseWork: false)
    }
    private func activate(_ button: GTK.Widget) {
        var clicked = false
        GTK.onSignal(button, "clicked") { clicked = true }
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        // Native activation uses a timer. Wait for clicked without releasing file work.
        XCTAssertTrue(GTKTestSupport.spin { clicked })
    }
    private func commandStatus(in window: GTK.Widget) -> String {
        guard let status = find(window, matching: { String(cString: gtk_widget_get_name($0)) == "library-editor-status" }) else { return "" }
        return label(status)
    }
    private func label(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }
    private func labels(_ widget: GTK.Widget) -> [String] {
        var result: [String] = []
        if String(cString: g_type_name_from_instance(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self))) == "GtkLabel" { result.append(label(widget)) }
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += labels(current); child = gtk_widget_get_next_sibling(current) }
        return result
    }
    private func contents(_ widget: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(widget))!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(text) }
        return String(cString: text)
    }
}

private final class LinuxHistoryHeldWork: BackgroundWork {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func releaseAll() { while !pending.isEmpty { pending.removeFirst()() } }
}

/// Deterministic errors work in CI as root and do not depend on permissions.
private final class LinuxHistoryTestStore: FileStore {
    private let base: RootedFileStore
    var moveFailure: FileStoreError?
    var deleteFailure: FileStoreError?
    var listFailure: FileStoreError?
    var replaceMovedDestination: Data?
    private(set) var deletes = 0
    private(set) var lists = 0
    init(root: URL) throws { base = try RootedFileStore(root: root); try base.createRoot() }
    func listFiles() throws -> [StoredFile] {
        lists += 1
        if let listFailure { throw listFailure }
        return try base.listFiles()
    }
    func stamp(at path: String) throws -> FileStamp? { try base.stamp(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func write(_ data: Data, at path: String) throws { try base.write(data, at: path) }
    func create(_ data: Data, at path: String) throws { try base.create(data, at: path) }
    func writePrivate(_ data: Data, at path: String) throws { try base.writePrivate(data, at: path) }
    func delete(at path: String) throws {
        if let failure = deleteFailure { deleteFailure = nil; throw failure }
        try base.delete(at: path)
        deletes += 1
    }
    func move(from source: String, to destination: String) throws {
        if let failure = moveFailure { moveFailure = nil; throw failure }
        try base.move(from: source, to: destination)
        if let bytes = replaceMovedDestination {
            replaceMovedDestination = nil
            try base.write(bytes, at: destination)
        }
    }
}
#endif
