#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryFormTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!

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
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            launchURI: { _ in XCTFail("Form tests launch no external URI") })
        MonkeysPawLinuxApp.installLibraryAction(application: application, environment: environment)
        MonkeysPawLinuxApp.installQuitAction(application: application, environment: environment, approved: {})
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        files = nil
        tools = nil
    }

    func testEditDefaultsToFormWithNativeControlsAndMountedSource() throws {
        let source = "---\ntitle: Hello\ndescription: About it\ntags: [alpha, beta]\nprivate: true\ncustom: keep\nfields:\n  topic: {default: Earth}\n---\nHello {{topic}}"
        try files.write(Data(source.utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertEqual(page(try widget("library-editor-stack", in: window)), "edit")
        XCTAssertNotNil(find(in: window) { String(cString: gtk_widget_get_name($0)) == "library-form" })
        XCTAssertEqual(entryText(try widget("library-form-title", in: window)), "Hello")
        XCTAssertEqual(entryText(try widget("library-form-description", in: window)), "About it")
        XCTAssertEqual(chipLabels(in: window), ["alpha", "beta"])
        for chip in chips(in: window) {
            XCTAssertNotNil(find(in: chip) { String(cString: gtk_widget_get_name($0)) == "library-tag-remove" })
        }
        XCTAssertEqual(gtk_check_button_get_active(mp_check_button(try widget("library-form-private", in: window))), 1)
        let hint = try widget("library-form-private-hint", in: window)
        XCTAssertTrue(label(hint).contains("never sent to the assistant"))
        let body = try widget("library-body", in: window)
        XCTAssertNotEqual(gtk_text_view_get_editable(mp_text_view(body)), 0)
        XCTAssertEqual(contents(body), "Hello {{topic}}")
        XCTAssertEqual(contents(try widget("library-source", in: window)), source)
    }

    func testFormAndBodyEditsSaveTogetherPreservingCustomMetadataAndFields() throws {
        let source = "---\ntitle: Hello\ntags: [alpha]\ncustom: keep\nfields:\n  topic: {default: Earth, description: Pick a topic}\n---\nHello {{topic}}"
        try files.write(Data(source.utf8), at: "a.md")
        let window = try open("a.md")
        mp_entry_set_text(try widget("library-form-title", in: window), "Renamed")
        mp_entry_set_text(try widget("library-form-description", in: window), "New description")
        mp_entry_set_text(try widget("library-form-tag-entry", in: window), "extra")
        // GTK defers a button's clicked emission past activate; spin it out.
        XCTAssertNotEqual(gtk_widget_activate(try widget("library-form-tag-add", in: window)), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.form?.tags == ["alpha", "extra"] })
        gtk_check_button_set_active(mp_check_button(try widget("library-form-private", in: window)), 1)
        replace(try widget("library-body", in: window), with: "Hello {{topic}} more")
        drain()
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertEqual(environment.editorModel.state.form?.tags, ["alpha", "extra"])
        XCTAssertTrue(actionEnabled("save", in: window))
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        let saved = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        XCTAssertEqual(saved.frontMatter.title, "Renamed")
        XCTAssertEqual(saved.frontMatter.description, "New description")
        XCTAssertEqual(saved.frontMatter.tags, ["alpha", "extra"])
        XCTAssertTrue(saved.frontMatter.isPrivate)
        XCTAssertEqual(saved.body, "Hello {{topic}} more")
        XCTAssertTrue(saved.source.contains("custom: keep"), "Form edits must keep unknown keys")
        XCTAssertTrue(saved.source.contains("fields:") && saved.source.contains("Pick a topic"),
            "Form edits must keep field declarations")
        XCTAssertEqual(environment.editorModel.state.form?.title, "Renamed")
    }

    func testTagsContainingPunctuationStayWholeChips() throws {
        try files.write(Data("---\ntitle: T\ntags: [\"a,b\", \"x;y\"]\n---\nBody".utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertEqual(environment.editorModel.state.form?.tags, ["a,b", "x;y"])
        XCTAssertEqual(chipLabels(in: window), ["a,b", "x;y"])
        mp_entry_set_text(try widget("library-form-tag-entry", in: window), "p,q")
        XCTAssertNotEqual(gtk_widget_activate(try widget("library-form-tag-add", in: window)), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.form?.tags == ["a,b", "x;y", "p,q"] })
        drain()
        XCTAssertEqual(environment.editorModel.state.form?.tags, ["a,b", "x;y", "p,q"])
        XCTAssertEqual(chipLabels(in: window), ["a,b", "x;y", "p,q"])
        XCTAssertNotEqual(gtk_widget_activate(removeButtons(in: window)[1]), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.form?.tags == ["a,b", "p,q"] })
        drain()
        XCTAssertEqual(environment.editorModel.state.form?.tags, ["a,b", "p,q"])
        XCTAssertEqual(chipLabels(in: window), ["a,b", "p,q"])
    }

    func testRemovingATagKeepsOtherExactValuesInOrder() throws {
        let first = "é"
        let last = "e\u{301}"
        try files.write(Data(("---\ntags: [\"" + first + "\", middle, \"" + last + "\"]\n---\nBody").utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertNotEqual(gtk_widget_activate(removeButtons(in: window)[2]), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.form?.tags.count == 2 })
        let remaining = try XCTUnwrap(environment.editorModel.state.form?.tags)
        XCTAssertEqual(remaining.map { Data($0.utf8) }, [first, "middle"].map { Data($0.utf8) })
    }

    func testSourceAndFormSwitchSynchronizeWithoutDirtying() throws {
        let source = "---\ntitle: Hello\n---\nBody"
        try files.write(Data(source.utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertFalse(environment.editorModel.state.isDirty)
        for action in ["preview", "source", "edit", "preview", "edit"] {
            activate(action, in: window)
            drain()
            XCTAssertFalse(environment.editorModel.state.isDirty)
            XCTAssertEqual(environment.editorModel.state.source, source)
        }
        activate("source", in: window)
        replace(try widget("library-source", in: window), with: "---\ntitle: Retitled\n---\nBody changed")
        activate("edit", in: window)
        drain()
        XCTAssertEqual(page(try widget("library-editor-stack", in: window)), "edit")
        XCTAssertEqual(entryText(try widget("library-form-title", in: window)), "Retitled")
        XCTAssertEqual(contents(try widget("library-body", in: window)), "Body changed")
        let dirty = environment.editorModel.state.source
        activate("preview", in: window)
        activate("source", in: window)
        activate("edit", in: window)
        drain()
        XCTAssertEqual(environment.editorModel.state.source, dirty)
        XCTAssertEqual(entryText(try widget("library-form-title", in: window)), "Retitled")
    }

    func testFormEditRefreshesControlsInPlaceAndKeepsActiveInput() throws {
        try files.write(Data("---\ntitle: Hello\n---\nBody".utf8), at: "a.md")
        let window = try open("a.md")
        let title = try widget("library-form-title", in: window)
        gtk_widget_grab_focus(title)
        mp_entry_set_text(title, "Typed")
        gtk_editable_set_position(OpaquePointer(title), 2)
        environment.editorModel.edit(.description("Other field"))
        drain()
        let focus = try XCTUnwrap(gtk_window_get_focus(mp_window(window)))
        XCTAssertTrue(focus == title || gtk_widget_is_ancestor(focus, title) != 0)
        XCTAssertEqual(entryText(title), "Typed")
        XCTAssertEqual(gtk_editable_get_position(OpaquePointer(title)), 2)
        XCTAssertEqual(entryText(try widget("library-form-description", in: window)), "Other field")
    }

    func testMalformedHeaderFallsBackToEditableSourceAndRecoversToForm() throws {
        try files.write(Data("---\n[broken\n---\nBody".utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertNil(environment.editorModel.state.form)
        let stack = try widget("library-editor-stack", in: window)
        XCTAssertEqual(page(stack), "source")
        let bar = try widget("library-form-fallback", in: window)
        XCTAssertNotEqual(gtk_widget_get_visible(bar), 0)
        XCTAssertTrue(labels(bar).contains { $0.contains("front matter") })
        XCTAssertNotEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source", in: window))), 0)
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-body", in: window))), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("library-form-title", in: window)), 0)
        replace(try widget("library-source", in: window), with: "---\ntitle: Repaired\n---\nBody")
        drain()
        XCTAssertEqual(page(stack), "edit")
        XCTAssertEqual(gtk_widget_get_visible(bar), 0)
        XCTAssertEqual(entryText(try widget("library-form-title", in: window)), "Repaired")
        replace(try widget("library-source", in: window), with: "---\n[broken\n---\nBody")
        drain()
        XCTAssertEqual(page(stack), "source")
        XCTAssertNotEqual(gtk_widget_get_visible(bar), 0)
    }

    func testReadOnlyGuardsDisableFormBodyAndSave() throws {
        let unsupported = try XCTUnwrap(PromptFormatVersion(2))
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        let window = try open("future.md")
        XCTAssertEqual(environment.editorModel.state.readOnlyReason, .unsupportedFormat(unsupported))
        XCTAssertNil(environment.editorModel.state.form)
        XCTAssertEqual(page(try widget("library-editor-stack", in: window)), "source")
        XCTAssertNotEqual(gtk_widget_get_visible(try widget("library-read-only", in: window)), 0)
        XCTAssertEqual(gtk_widget_get_visible(try widget("library-form-fallback", in: window)), 0)
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source", in: window))), 0)
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-body", in: window))), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("library-form-title", in: window)), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("library-form-private", in: window)), 0)
        XCTAssertFalse(actionEnabled("save", in: window))
        XCTAssertFalse(environment.editorModel.state.isDirty)
    }

    func testBodyEditorHasDistinctNativeUndoAndExactContents() throws {
        try files.write(Data("---\ntitle: T\n---\nHello".utf8), at: "a.md")
        let window = try open("a.md")
        let body = try widget("library-body", in: window)
        XCTAssertEqual(contents(body), "Hello")
        XCTAssertNotEqual(body, try widget("library-source", in: window))
        let bodyBuffer = gtk_text_view_get_buffer(mp_text_view(body))!
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(bodyBuffer, &end)
        gtk_text_buffer_place_cursor(bodyBuffer, &end)
        gtk_text_buffer_begin_user_action(bodyBuffer)
        gtk_text_buffer_insert_at_cursor(bodyBuffer, "!", -1)
        gtk_text_buffer_end_user_action(bodyBuffer)
        XCTAssertEqual(contents(body), "Hello!")
        XCTAssertEqual(environment.editorModel.state.form?.body, "Hello!")
        XCTAssertNotEqual(gtk_text_buffer_get_can_undo(bodyBuffer), 0)
        gtk_text_buffer_undo(bodyBuffer)
        XCTAssertEqual(contents(body), "Hello")
        XCTAssertEqual(environment.editorModel.state.form?.body, "Hello")
        XCTAssertEqual(contents(try widget("library-source", in: window)), environment.editorModel.state.source)
    }

    func testBodyValidationIssueKeepsFormUsable() throws {
        try files.write(Data("---\ntitle: Hello\n---\nBroken {{".utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertNotNil(environment.editorModel.state.form, "Body issues must not remove the form")
        XCTAssertFalse(environment.editorModel.state.issues.isEmpty)
        XCTAssertEqual(page(try widget("library-editor-stack", in: window)), "edit")
        XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("library-form-title", in: window)), 0)
        XCTAssertNotEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-body", in: window))), 0)
    }

    private func open(_ path: String) throws -> GTK.Widget {
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.window(titled: LinuxStrings.library).map { gtk_widget_get_visible($0) != 0 } == true })
        let window = try XCTUnwrap(self.window(titled: LinuxStrings.library))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.contains { $0.relativePath.string == path } })
        drain()
        try select(path, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == path
            && self.environment.editorModel.state.status != .loading
            && self.environment.libraryBrowserModel.selection?.relativePath.string == path })
        drain()
        return window
    }

    private func select(_ path: String, in window: GTK.Widget) throws {
        drain()
        let position = try XCTUnwrap(environment.libraryBrowserModel.rows.firstIndex { $0.relativePath.string == path })
        let list = try widget("library-list", in: window)
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
    }

    private func activate(_ action: String, in window: GTK.Widget) {
        g_action_group_activate_action(mp_window_action_group(window), action, nil)
    }

    private func actionEnabled(_ action: String, in window: GTK.Widget) -> Bool {
        g_action_group_get_action_enabled(mp_window_action_group(window), action) != 0
    }

    private func page(_ stack: GTK.Widget) -> String? {
        gtk_stack_get_visible_child_name(mp_stack(stack)).map { String(cString: $0) }
    }

    private func entryText(_ entry: GTK.Widget) -> String { String(cString: mp_entry_text(entry)) }

    private func chipLabels(in window: GTK.Widget) -> [String] {
        chips(in: window).map { chip in
            gtk_widget_get_first_child(chip).map { String(cString: gtk_label_get_text(mp_label($0))) } ?? ""
        }
    }

    private func chips(in window: GTK.Widget) -> [GTK.Widget] {
        findAll(in: window) { String(cString: gtk_widget_get_name($0)) == "library-tag-chip" }
    }

    private func removeButtons(in window: GTK.Widget) -> [GTK.Widget] {
        findAll(in: window) { String(cString: gtk_widget_get_name($0)) == "library-tag-remove" }
    }

    private func label(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }

    private func labels(_ widget: GTK.Widget) -> [String] {
        var result = [String]()
        if String(cString: g_type_name_from_instance(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self))) == "GtkLabel" { result.append(label(widget)) }
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += labels(current); child = gtk_widget_get_next_sibling(current) }
        return result
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

    private func widget(_ name: String, in window: GTK.Widget) throws -> GTK.Widget {
        try XCTUnwrap(find(in: window) { String(cString: gtk_widget_get_name($0)) == name }, "Missing \(name)")
    }

    private func find(in widget: GTK.Widget, matching predicate: (GTK.Widget) -> Bool) -> GTK.Widget? {
        findAll(in: widget, matching: predicate).first
    }

    private func findAll(in widget: GTK.Widget, matching predicate: (GTK.Widget) -> Bool) -> [GTK.Widget] {
        var result = predicate(widget) ? [widget] : []
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += findAll(in: current, matching: predicate); child = gtk_widget_get_next_sibling(current) }
        return result
    }

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

    private func drain() {
        var drained = false
        GTK.onMainLoop { GTK.onMainLoop { drained = true } }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}
#endif
