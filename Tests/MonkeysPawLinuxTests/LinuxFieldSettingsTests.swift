#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxFieldSettingsTests: XCTestCase {
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
            launchURI: { _ in XCTFail("Field settings tests launch no external URI") })
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

    func testApplyStagesChoiceEditsAndSavePreservesUnknownMetadata() throws {
        let source = """
            ---
            title: Hello
            custom: keep
            fields:
              topic:
                type: choice
                label: Topic
                default: earth
                options:
                  - {label: Earth, value: earth, extra: keep}
                  - Moon
            ---
            Hello {{topic}}
            """
        try files.write(Data(source.utf8), at: "a.md")
        let window = try open("a.md")
        let buttons = settingsButtons(in: window)
        XCTAssertEqual(buttons.count, 1)
        click(buttons[0])
        let dialog = try XCTUnwrap(settingsDialog(), "Settings button opened no dialog")
        XCTAssertEqual(gtk_window_get_modal(mp_window(dialog)), 1)
        XCTAssertEqual(gtk_window_get_transient_for(mp_window(dialog)), mp_window(window))
        XCTAssertEqual(defaultText(try widget("field-settings-default", in: dialog)), "earth")
        mp_entry_set_text(try widget("field-settings-label", in: dialog), "Subject")
        mp_entry_set_text(try widget("field-settings-description", in: dialog), "Pick a world")
        mp_entry_set_text(findAll(in: dialog) { named($0, "field-settings-option-label") }[1], "Luna")
        mp_entry_set_text(findAll(in: dialog) { named($0, "field-settings-option-value") }[1], "luna")
        setDefault(try widget("field-settings-default", in: dialog), "luna")
        XCTAssertFalse(environment.editorModel.state.isDirty, "Staged controls must not touch the draft")
        click(try widget("field-settings-apply", in: dialog))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.isDirty })
        drain()
        XCTAssertNil(settingsDialog(), "Apply must close the dialog")
        let staged = try XCTUnwrap(environment.editorModel.state.form?.fieldSettings.first)
        XCTAssertEqual(staged.label, "Subject")
        XCTAssertEqual(staged.description, "Pick a world")
        XCTAssertEqual(staged.defaultValue, "luna")
        XCTAssertEqual(staged.options.map(\.value), ["earth", "luna"])
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        let saved = String(decoding: try files.read(at: "a.md"), as: UTF8.self)
        XCTAssertTrue(saved.contains("custom: keep"), "Field edits keep unknown header keys")
        XCTAssertTrue(saved.contains("extra: keep"), "Option edits keep unknown option keys")
        let parsed = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        let field = try XCTUnwrap(parsed.frontMatter.fields.first)
        XCTAssertEqual(field.kind, .choice)
        XCTAssertEqual(field.label, "Subject")
        XCTAssertEqual(field.description, "Pick a world")
        XCTAssertEqual(field.defaultValue, "luna")
        XCTAssertEqual(field.options.map(\.label), ["Earth", "Luna"])
        XCTAssertEqual(field.options.map(\.value), ["earth", "luna"])
    }

    func testNilAndEmptyDefaultsStayDistinctThroughSave() throws {
        try files.write(Data("---\ntitle: Hello\nfields:\n  topic: {default: Earth}\n---\nHello {{topic}}".utf8), at: "a.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        var dialog = try XCTUnwrap(settingsDialog())
        // An enabled default holding an empty entry is an explicit empty string.
        setDefault(try widget("field-settings-default", in: dialog), "")
        click(try widget("field-settings-apply", in: dialog))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.isDirty })
        drain()
        XCTAssertEqual(environment.editorModel.state.form?.fieldSettings.first?.defaultValue, "")
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        var parsed = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        XCTAssertEqual(parsed.frontMatter.fields.first?.defaultValue, "")
        click(settingsButtons(in: window)[0])
        dialog = try XCTUnwrap(settingsDialog())
        // Turning the toggle off removes the key: nil differs from empty.
        gtk_check_button_set_active(mp_check_button(try widget("field-settings-default-toggle", in: dialog)), 0)
        click(try widget("field-settings-apply", in: dialog))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.isDirty })
        drain()
        XCTAssertNil(environment.editorModel.state.form?.fieldSettings.first?.defaultValue)
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        parsed = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        XCTAssertEqual(parsed.frontMatter.fields.first?.defaultValue, "")
        XCTAssertFalse(String(decoding: try files.read(at: "a.md"), as: UTF8.self).contains("default"),
                       "A removed default must not leave the key behind")
    }

    func testCancelStagesNothingAndLeavesDraftClean() throws {
        try files.write(Data(choicePrompt.utf8), at: "a.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        let dialog = try XCTUnwrap(settingsDialog())
        mp_entry_set_text(try widget("field-settings-label", in: dialog), "Changed")
        mp_entry_set_text(findAll(in: dialog) { named($0, "field-settings-option-value") }[1], "luna")
        gtk_check_button_set_active(mp_check_button(try widget("field-settings-optional", in: dialog)), 1)
        click(try widget("field-settings-cancel", in: dialog))
        drain()
        XCTAssertNil(settingsDialog(), "Cancel must close the dialog")
        XCTAssertFalse(environment.editorModel.state.isDirty)
        let staged = try XCTUnwrap(environment.editorModel.state.form?.fieldSettings.first)
        XCTAssertEqual(staged.label, "Topic")
        XCTAssertEqual(staged.options.map(\.value), ["earth", "Moon"])
        XCTAssertFalse(staged.optional)
        XCTAssertEqual(environment.editorModel.state.source, choicePrompt)
        XCTAssertEqual(String(decoding: try files.read(at: "a.md"), as: UTF8.self), choicePrompt)
    }

    func testChangedSourceRetiresStagedSettingsEvenWhenFieldsAreUnchanged() throws {
        try files.write(Data(choicePrompt.utf8), at: "a.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        let dialog = try XCTUnwrap(settingsDialog())
        mp_entry_set_text(try widget("field-settings-label", in: dialog), "Staged")
        environment.editorModel.edit(.body("Changed {{topic}}"))
        drain()
        XCTAssertNil(settingsDialog(), "Settings belong to the exact source they were opened against")
        XCTAssertEqual(environment.editorModel.state.form?.fieldSettings.first?.label, "Topic")
    }

    func testMultilineDefaultCanBeEditedWithoutLosingLineBreaks() throws {
        try files.write(Data("---\nfields:\n  topic: {type: multiline}\n---\n{{topic}}".utf8), at: "a.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        let dialog = try XCTUnwrap(settingsDialog())
        let input = try widget("field-settings-default", in: dialog)
        let isMultiline = g_type_check_instance_is_a(UnsafeMutableRawPointer(input)
            .assumingMemoryBound(to: GTypeInstance.self), gtk_text_view_get_type()) != 0
        XCTAssertTrue(isMultiline, "The default control must accept line breaks")
        guard isMultiline else { return }
        gtk_check_button_set_active(mp_check_button(try widget("field-settings-default-toggle", in: dialog)), 1)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(input)), "First\nSecond\n", -1)
        click(try widget("field-settings-apply", in: dialog))
        drain()
        XCTAssertEqual(environment.editorModel.state.form?.fieldSettings.first?.defaultValue, "First\nSecond\n")
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        let saved = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        XCTAssertEqual(saved.effectiveFields.first?.defaultValue, "First\nSecond\n")
    }

    func testImplicitFieldDeclaresOnlyAfterASettingChanges() throws {
        try files.write(Data("---\ntitle: T\n---\nHello {{topic}}".utf8), at: "a.md")
        let window = try open("a.md")
        XCTAssertEqual(environment.editorModel.state.form?.fieldSettings.first?.isImplicit, true)
        click(settingsButtons(in: window)[0])
        var dialog = try XCTUnwrap(settingsDialog())
        click(try widget("field-settings-apply", in: dialog))
        drain()
        XCTAssertNil(settingsDialog())
        XCTAssertFalse(environment.editorModel.state.isDirty,
                       "Applying unchanged implicit settings must not write a declaration")
        click(settingsButtons(in: window)[0])
        dialog = try XCTUnwrap(settingsDialog())
        gtk_combo_box_set_active(mp_combo_box(try widget("field-settings-kind", in: dialog)), 1)
        mp_entry_set_text(try widget("field-settings-label", in: dialog), "Topic")
        click(try widget("field-settings-apply", in: dialog))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.isDirty })
        activate("save", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        let saved = String(decoding: try files.read(at: "a.md"), as: UTF8.self)
        XCTAssertTrue(saved.contains("fields:"), "A changed setting declares the field")
        XCTAssertTrue(saved.contains("multiline"))
        let parsed = PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md")
        let field = try XCTUnwrap(parsed.frontMatter.fields.first)
        XCTAssertEqual(field.kind, .multiline)
        XCTAssertEqual(field.label, "Topic")
    }

    func testSwitchingPromptsRetiresTheDialogWithoutApplying() throws {
        try files.write(Data(choicePrompt.utf8), at: "a.md")
        try files.write(Data("---\ntitle: B\n---\nB".utf8), at: "b.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        let dialog = try XCTUnwrap(settingsDialog())
        mp_entry_set_text(try widget("field-settings-label", in: dialog), "Changed")
        try select("b.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.editorModel.state.prompt?.relativePath.string == "b.md"
                && self.environment.editorModel.state.status != .loading })
        drain()
        XCTAssertNil(settingsDialog(), "A prompt switch must retire the dialog")
        XCTAssertFalse(environment.editorModel.state.isDirty)
        XCTAssertEqual(String(decoding: try files.read(at: "a.md"), as: UTF8.self), choicePrompt)
        XCTAssertEqual(String(decoding: try files.read(at: "b.md"), as: UTF8.self), "---\ntitle: B\n---\nB")
    }

    func testReadOnlyAndMalformedPromptsShowNoSettingsControls() throws {
        let unsupported = try XCTUnwrap(PromptFormatVersion(2))
        try files.write(Data("---\nformat: 2\n---\nFuture {{topic}}".utf8), at: "future.md")
        let window = try open("future.md")
        XCTAssertEqual(environment.editorModel.state.readOnlyReason, .unsupportedFormat(unsupported))
        XCTAssertNil(environment.editorModel.state.form)
        XCTAssertTrue(settingsButtons(in: window).isEmpty)
        XCTAssertEqual(gtk_widget_get_visible(try widget("library-form-fields-section", in: window)), 0)
        try files.write(Data("---\n[broken\n---\nBody {{topic}}".utf8), at: "broken.md")
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.libraryBrowserModel.rows.contains { $0.relativePath.string == "broken.md" } })
        try select("broken.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.editorModel.state.prompt?.relativePath.string == "broken.md"
                && self.environment.editorModel.state.status != .loading })
        drain()
        XCTAssertNil(environment.editorModel.state.form)
        XCTAssertTrue(settingsButtons(in: window).isEmpty)
    }

    func testMissingOptionsAndInvalidDefaultDisableApply() throws {
        try files.write(Data(choicePrompt.utf8), at: "a.md")
        let window = try open("a.md")
        click(settingsButtons(in: window)[0])
        let dialog = try XCTUnwrap(settingsDialog())
        let apply = try widget("field-settings-apply", in: dialog)
        let validation = try widget("field-settings-validation", in: dialog)
        XCTAssertNotEqual(gtk_widget_get_sensitive(apply), 0)
        click(findAll(in: dialog) { named($0, "field-settings-option-remove") }[0])
        click(findAll(in: dialog) { named($0, "field-settings-option-remove") }[0])
        XCTAssertEqual(gtk_widget_get_sensitive(apply), 0)
        XCTAssertTrue(label(validation).contains("option"), "Missing options must explain the refusal")
        click(try widget("field-settings-option-add", in: dialog))
        mp_entry_set_text(findAll(in: dialog) { named($0, "field-settings-option-label") }[0], "Earth")
        mp_entry_set_text(findAll(in: dialog) { named($0, "field-settings-option-value") }[0], "earth")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(apply) != 0 },
                      "A matching default and one option must validate")
        setDefault(try widget("field-settings-default", in: dialog), "mars")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(apply) == 0 })
        XCTAssertTrue(label(validation).contains("default"), "An unmatched default must explain the refusal")
        setDefault(try widget("field-settings-default", in: dialog), "earth")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(apply) != 0 })
        click(try widget("field-settings-cancel", in: dialog))
        drain()
        XCTAssertFalse(environment.editorModel.state.isDirty)
    }

    private var choicePrompt: String {
        """
        ---
        title: Hello
        fields:
          topic:
            type: choice
            label: Topic
            default: earth
            options:
              - {label: Earth, value: earth}
              - Moon
        ---
        Hello {{topic}}
        """
    }

    private func named(_ widget: GTK.Widget, _ name: String) -> Bool {
        String(cString: gtk_widget_get_name(widget)) == name
    }

    private func settingsButtons(in window: GTK.Widget) -> [GTK.Widget] {
        findAll(in: window) { named($0, "library-form-field-settings") }
    }

    private func settingsDialog() -> GTK.Widget? {
        windows.first { named($0, "library-field-settings-dialog") && gtk_widget_get_visible($0) != 0 }
    }

    private func click(_ button: GTK.Widget) {
        var clicked = false
        GTK.onSignal(button, "clicked") { clicked = true }
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin { clicked })
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

    private func entryText(_ entry: GTK.Widget) -> String { String(cString: mp_entry_text(entry)) }

    private func setDefault(_ view: GTK.Widget, _ text: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(view)), text, -1)
    }

    private func defaultText(_ view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let text = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }

    private func label(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }

    private func widget(_ name: String, in window: GTK.Widget) throws -> GTK.Widget {
        try XCTUnwrap(find(in: window) { named($0, name) }, "Missing \(name)")
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
