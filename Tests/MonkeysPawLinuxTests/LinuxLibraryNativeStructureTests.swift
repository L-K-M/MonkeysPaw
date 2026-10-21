#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryNativeStructureTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var portal: FakePortal!

    override func setUpWithError() throws {
        let bus = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        let root = LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw")
        files = try RootedFileStore(root: root)
        try files.write(Data("---\ntitle: Example\nfields:\n  topic: {default: Earth}\n---\nHello {{topic}}".utf8), at: "folder/a.md")
        portal = try FakePortal(address: bus)
        try portal.ownNotifications()
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        portal?.shutdown()
        portal = nil
        files = nil
        tools = nil
    }

    func testHeaderShowsSectionCountAndOpenPromptEditedState() throws {
        let window = try openLibrary()
        XCTAssertEqual(try label("library-title", in: window), environment.libraryBrowserModel.sections.first?.title)
        XCTAssertEqual(try label("library-subtitle", in: window), "1 prompt")
        environment.libraryBrowserModel.selectSection(.favourites)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.label("library-subtitle", in: window)) == "0 prompts" })
        XCTAssertEqual(try label("library-title", in: window), "Favourites")
        environment.libraryBrowserModel.selectSection(.all)
        try selectPrompt(in: window)
        XCTAssertEqual(try label("library-title", in: window), "Example")
        XCTAssertEqual(try label("library-subtitle", in: window), "folder/a.md")
        environment.editorModel.edit("Edited body")
        XCTAssertTrue(GTKTestSupport.spin { (try? self.label("library-subtitle", in: window)) == "folder/a.md — Edited" })
        XCTAssertEqual(String(cString: gtk_window_get_title(mp_window(window))), LinuxStrings.library)
    }

    func testControlFRevealsSearchAndEscapeClearsWithoutClosing() throws {
        let window = try openLibrary()
        try selectPrompt(in: window)
        let filter = try settingsWidget("library-filter", in: window)
        let searchBar = try XCTUnwrap(gtk_widget_get_ancestor(filter, gtk_search_bar_get_type()))
        XCTAssertEqual(gtk_search_bar_get_search_mode(mp_search_bar(searchBar)), 0)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_f), GDK_CONTROL_MASK), 0)
        XCTAssertNotEqual(gtk_search_bar_get_search_mode(mp_search_bar(searchBar)), 0)
        activate("search", in: window)
        XCTAssertNotEqual(gtk_search_bar_get_search_mode(mp_search_bar(searchBar)), 0, "Find must keep an open search bar visible")
        let focus = try XCTUnwrap(gtk_window_get_focus(mp_window(window)))
        XCTAssertTrue(focus == filter || gtk_widget_is_ancestor(focus, filter) != 0)
        mp_entry_set_text(filter, "missing")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.isEmpty })
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertEqual(String(cString: mp_entry_text(filter)), "")
        XCTAssertEqual(gtk_search_bar_get_search_mode(mp_search_bar(searchBar)), 0)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        gtk_widget_grab_focus(try settingsWidget("library-source", in: window))
        XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
    }

    func testModeButtonsAndControlOneTwoSelectEditorPages() throws {
        let window = try openLibrary()
        try selectPrompt(in: window)
        let stack = try settingsWidget("library-editor-stack", in: window)
        let edit = try settingsWidget("library-mode-edit", in: window)
        let preview = try settingsWidget("library-mode-preview", in: window)
        XCTAssertNotEqual(gtk_widget_activate(preview), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.page(stack) == "preview" })
        XCTAssertNotEqual(gtk_toggle_button_get_active(mp_toggle_button(preview)), 0)
        XCTAssertEqual(gtk_toggle_button_get_active(mp_toggle_button(edit)), 0)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_1), GDK_CONTROL_MASK), 0)
        XCTAssertEqual(page(stack), "edit")
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_2), GDK_CONTROL_MASK), 0)
        XCTAssertEqual(page(stack), "preview")
        XCTAssertNotEqual(gtk_widget_activate(edit), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.page(stack) == "edit" })
    }

    func testInspectorStartsHiddenAndHasThreeNamedPages() throws {
        let window = try openLibrary()
        let inspector = try settingsWidget("library-inspector", in: window)
        let stack = try settingsWidget("library-inspector-stack", in: window)
        XCTAssertEqual(gtk_widget_get_visible(inspector), 0)
        var names = [String]()
        var child = gtk_widget_get_first_child(stack)
        while let current = child {
            if let page = gtk_stack_get_page(mp_stack(stack), current), let name = gtk_stack_page_get_name(page) {
                names.append(String(cString: name))
            }
            child = gtk_widget_get_next_sibling(current)
        }
        XCTAssertEqual(names, ["fields", "history", "assistant"])
        activate("history", in: window)
        XCTAssertNotEqual(gtk_widget_get_visible(inspector), 0)
        XCTAssertEqual(page(stack), "history")
        activate("assistant", in: window)
        XCTAssertEqual(page(stack), "assistant")
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("library-assistant-panel", in: window)), 0)
    }

    func testContextCommandsAndDialogDisableActionsUntilCancelled() throws {
        let window = try openLibrary()
        let menu = try settingsWidget("library-context-menu", in: window)
        let model = try XCTUnwrap(gtk_popover_menu_get_menu_model(mp_popover_menu(menu)))
        let names = (0..<g_menu_model_get_n_items(model)).compactMap { index -> String? in
            guard let value = g_menu_model_get_item_attribute_value(model, index, "action", nil) else { return nil }
            defer { g_variant_unref(value) }
            return String(cString: g_variant_get_string(value, nil))
        }
        XCTAssertEqual(names, ["win.edit", "win.favorite", "win.rename", "win.move", "win.duplicate", "win.show-files", "win.delete"])
        XCTAssertFalse(enabled("rename", in: window))
        try selectPrompt(in: window)
        for name in ["rename", "move", "delete", "duplicate", "favorite", "show-files"] { XCTAssertTrue(enabled(name, in: window), name) }
        activate("rename", in: window)
        let form = try XCTUnwrap(commandDialog)
        for name in ["rename", "move", "delete", "save", "duplicate", "favorite", "search", "close"] {
            XCTAssertFalse(enabled(name, in: window), name)
        }
        activate("delete", in: window)
        XCTAssertTrue(commandDialog == form)
        gtk_window_close(mp_window(form))
        XCTAssertTrue(GTKTestSupport.spin { self.enabled("rename", in: window) })
        XCTAssertNotNil(try files.stamp(at: "folder/a.md"))
    }

    func testListDeleteF2AndReturnForwardToExistingCommands() throws {
        let window = try openLibrary()
        try selectPrompt(in: window)
        let list = try settingsWidget("library-list", in: window)
        for key in [UInt32(GDK_KEY_Delete), UInt32(GDK_KEY_F2)] {
            gtk_widget_grab_focus(mp_row_widget(gtk_list_box_get_row_at_index(mp_list_box(list), 0)))
            XCTAssertNotEqual(mp_test_emit_key_pressed(window, key, GdkModifierType(rawValue: 0)), 0)
            let form = try XCTUnwrap(commandDialog)
            XCTAssertEqual(String(cString: gtk_window_get_title(mp_window(form))), key == UInt32(GDK_KEY_Delete)
                ? LinuxEditorStrings.deleteTitle("folder/a.md") : LinuxEditorStrings.renameTitle)
            gtk_window_close(mp_window(form))
            XCTAssertTrue(GTKTestSupport.spin { self.enabled("rename", in: window) })
        }
        gtk_widget_grab_focus(mp_row_widget(gtk_list_box_get_row_at_index(mp_list_box(list), 0)))
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Return), GdkModifierType(rawValue: 0)), 0)
        let source = try settingsWidget("library-source", in: window)
        XCTAssertEqual(gtk_window_get_focus(mp_window(window)), source)
    }

    func testPreeditDisablesActionsAndImportMenuRevealsBar() throws {
        let window = try openLibrary()
        try selectPrompt(in: window)
        let source = try settingsWidget("library-source", in: window)
        gtk_widget_grab_focus(source)
        mp_test_emit_preedit_changed(source, "かな")
        XCTAssertFalse(enabled("preview", in: window))
        activate("preview", in: window)
        XCTAssertEqual(page(try settingsWidget("library-editor-stack", in: window)), "edit")
        mp_test_emit_preedit_changed(source, "")
        XCTAssertTrue(GTKTestSupport.spin { self.enabled("preview", in: window) })
        let bar = try settingsWidget("library-import-bar", in: window)
        XCTAssertEqual(gtk_revealer_get_reveal_child(mp_revealer(bar)), 0)
        activate("import-files", in: window)
        XCTAssertNotEqual(gtk_revealer_get_reveal_child(mp_revealer(bar)), 0)
    }

    func testMenuStateChangesUseCommandsAndRespectDialogGates() throws {
        let window = try openLibrary()
        try selectPrompt(in: window)
        let sidebar = try settingsWidget("library-sidebar-pane", in: window)
        let inspector = try settingsWidget("library-inspector", in: window)
        let group = mp_window_action_group(window)
        g_action_group_change_action_state(group, "sidebar", g_variant_new_boolean(0))
        XCTAssertEqual(gtk_widget_get_visible(sidebar), 0)
        g_action_group_change_action_state(group, "sidebar", g_variant_new_boolean(0))
        XCTAssertEqual(gtk_widget_get_visible(sidebar), 0, "Requesting the current state must not toggle again")
        g_action_group_change_action_state(group, "inspector", g_variant_new_boolean(1))
        XCTAssertNotEqual(gtk_widget_get_visible(inspector), 0)
        activate("rename", in: window)
        let dialog = try XCTUnwrap(commandDialog)
        g_action_group_change_action_state(group, "inspector", g_variant_new_boolean(0))
        XCTAssertNotEqual(gtk_widget_get_visible(inspector), 0)
        let state = try XCTUnwrap(g_action_group_get_action_state(group, "inspector"))
        defer { g_variant_unref(state) }
        XCTAssertNotEqual(g_variant_get_boolean(state), 0, "A refused request must preserve the action state as well as the pane")
        gtk_window_close(mp_window(dialog))
    }

    private func openLibrary() throws -> GTK.Widget {
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.libraryBrowserModel.rows.isEmpty })
        return try XCTUnwrap(windows.first { gtk_window_get_title(mp_window($0)).map { String(cString: $0) } == LinuxStrings.library })
    }

    private func selectPrompt(in window: GTK.Widget) throws {
        let list = try settingsWidget("library-list", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_list_box_get_row_at_index(mp_list_box(list), 0) != nil })
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), 0))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source != nil && self.environment.editorModel.state.status == .idle })
        XCTAssertTrue(GTKTestSupport.spin { self.enabled("save", in: window) })
    }

    private func activate(_ action: String, in window: GTK.Widget) {
        g_action_group_activate_action(mp_window_action_group(window), action, nil)
    }

    private func enabled(_ action: String, in window: GTK.Widget) -> Bool {
        g_action_group_get_action_enabled(mp_window_action_group(window), action) != 0
    }

    private func label(_ name: String, in window: GTK.Widget) throws -> String {
        String(cString: gtk_label_get_text(mp_label(try settingsWidget(name, in: window))))
    }

    private func page(_ stack: GTK.Widget) -> String? {
        gtk_stack_get_visible_child_name(mp_stack(stack)).map { String(cString: $0) }
    }

    private var windows: [GTK.Widget] {
        let model = gtk_window_get_toplevels()!
        return (0..<g_list_model_get_n_items(model)).compactMap { index in
            guard let item = g_list_model_get_item(model, index) else { return nil }
            defer { g_object_unref(item) }
            return item.assumingMemoryBound(to: GtkWidget.self)
        }
    }

    private var commandDialog: GTK.Widget? {
        windows.first { String(cString: gtk_widget_get_name($0)) == "library-file-command-dialog" && gtk_widget_get_visible($0) != 0 }
    }
}
#endif
