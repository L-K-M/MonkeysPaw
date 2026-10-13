#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryWindowTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var root: URL!
    private var notifications: FakePortal!
    private var launched: [URL] = []

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        root = LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw", isDirectory: true)
        files = try RootedFileStore(root: root)
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        launched = []
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            launchURI: { [weak self] in self?.launched.append($0) })
        MonkeysPawLinuxApp.installLibraryAction(application: application, environment: environment)
        MonkeysPawLinuxApp.installSettingsAction(application: application, environment: environment)
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        tools = nil
        files = nil
    }

    func testDesktopActionReusesHideOnCloseWindowAlongsideSettings() throws {
        let window = try openLibrary()
        let browser = environment.libraryBrowserModel
        let controllers = gtk_widget_observe_controllers(window)!
        defer { g_object_unref(UnsafeMutableRawPointer(controllers)) }
        let controllerCount = g_list_model_get_n_items(controllers)
        XCTAssertEqual(gtk_window_get_hide_on_close(mp_window(window)), 1)
        XCTAssertEqual(try openLibrary(), window)
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertEqual(try openLibrary(), window)
        XCTAssertTrue(environment.libraryBrowserModel === browser)
        XCTAssertEqual(g_list_model_get_n_items(controllers), controllerCount)
        XCTAssertEqual(libraryWindows, [window])

        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin {
            self.windows.contains { self.title($0) == LinuxStrings.settings && gtk_widget_get_visible($0) != 0 }
        })
        let settings = try XCTUnwrap(windows.first { title($0) == LinuxStrings.settings })
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        gtk_window_close(mp_window(settings))
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        try click("library-open-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.launched == [self.root] })
    }

    func testPickerLibraryButtonAndControlLWorkWithoutTrayAndReuseWindow() throws {
        try files.write(Data("A prompt".utf8), at: "a.md")
        for keyboard in [false, true] {
            environment.pickerModel.open()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
            if keyboard {
                XCTAssertNotEqual(mp_test_emit_key_pressed(environment.panel.clipboardOwner,
                    UInt32(GDK_KEY_l), GDK_CONTROL_MASK), 0)
            } else {
                try click("picker-library", in: environment.panel.clipboardOwner)
            }
            XCTAssertTrue(GTKTestSupport.spin { self.libraryWindows.first.map { gtk_widget_get_visible($0) != 0 } == true })
            let window = try XCTUnwrap(libraryWindows.first)
            XCTAssertFalse(environment.panel.isVisible)
            XCTAssertEqual(environment.pickerModel.state, .closed)
            XCTAssertEqual(libraryWindows.count, 1)
            XCTAssertTrue(launched.isEmpty)
            gtk_window_close(mp_window(window))
        }
    }

    func testSectionsCountsFilterSelectionAndIssueBadgesRenderFromBrowser() throws {
        try files.write(Data("---\ntitle: Alpha\nfavorite: true\ntags: [Code]\nfields:\n  topic: {default: Earth}\n---\nHello {{topic}} {{missing}} {{clipboard}}".utf8), at: "alpha.md")
        try files.write(Data("---\ntitle: Beta\ntags: [design]\n---\nBeta body".utf8), at: "nested/deep/beta.md")
        try files.write(Data("---\n[broken\n---\nBody".utf8), at: "invalid.md")
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        try files.write(Data(repeating: 65, count: Limits.maxPromptBytes + 1), at: "oversized.md")
        let window = try openLibrary()
        let browser = environment.libraryBrowserModel
        let sidebar = try settingsWidget("library-sidebar", in: window)
        for (position, section) in browser.sections.enumerated() {
            let row = try rowWidget(in: sidebar, at: position)
            XCTAssertEqual(labels(in: row), ["\(section.title) (\(section.count))"])
            let label = try XCTUnwrap(gtk_widget_get_first_child(row))
            XCTAssertEqual(gtk_widget_get_margin_start(label), Int32(section.depth * 12))
        }
        XCTAssertEqual(browser.sections.first { $0.id == .all }?.count, 5)
        XCTAssertEqual(browser.sections.first { $0.id == .folder(RelativePath("nested")) }?.count, 1)
        XCTAssertEqual(browser.sections.first { $0.id == .tag("code") }?.count, 1)
        try select("alpha.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.preview(in: window) == "Hello Earth {missing} {clipboard}" })
        let selected = browser.selection
        let filter = try settingsWidget("library-filter", in: window)
        mp_entry_set_text(filter, "does not match")
        XCTAssertTrue(GTKTestSupport.spin { browser.rows.isEmpty })
        drain()
        XCTAssertEqual(browser.selection, selected)
        XCTAssertEqual(preview(in: window), "Hello Earth {missing} {clipboard}")
        XCTAssertEqual(browser.sections.first?.count, 5)
        mp_entry_set_text(filter, "")
        try selectSection(.folder(RelativePath("nested/deep")), in: window)
        XCTAssertTrue(GTKTestSupport.spin { browser.rows.map(\.relativePath.string) == ["nested/deep/beta.md"] })
        try selectSection(.all, in: window)
        for path in ["invalid.md", "future.md", "oversized.md"] {
            try select(path, in: window)
            let row = try XCTUnwrap(browser.state.selectedPrompt)
            XCTAssertFalse(row.canRender)
            XCTAssertEqual(preview(in: window), row.issues.map(\.message).joined(separator: "\n"))
            let position = try XCTUnwrap(browser.rows.firstIndex { $0.relativePath.string == path })
            let labels = labels(in: try rowWidget(in: settingsWidget("library-list", in: window), at: position))
            XCTAssertTrue(labels.contains { $0.contains(LinuxStrings.invalidPrompt) })
            if path != "invalid.md" {
                XCTAssertTrue(labels.contains { $0.contains(LinuxStrings.readOnly) })
                XCTAssertEqual(gtk_widget_get_sensitive(try settingsWidget("library-favorite", in: window)), 0)
            }
        }
    }

    func testNativeListNavigationReturnAndEscapeRespectFilterAndPreedit() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        try files.write(Data("Beta".utf8), at: "b.md")
        let window = try openLibrary()
        let list = try settingsWidget("library-list", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_window_is_active(mp_window(window)) != 0 })
        let first = try rowWidget(in: list, at: 0)
        XCTAssertNotEqual(gtk_widget_grab_focus(first), 0)
        moveCursor(in: list, by: 1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection?.relativePath.string == "b.md" })
        // GTK activates a list row on Return; there is no open/edit handler yet.
        XCTAssertNotEqual(gtk_widget_activate(try rowWidget(in: list, at: 1)), 0)
        drain()
        XCTAssertTrue(launched.isEmpty)
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertNotEqual(gtk_widget_child_focus(window, GTK_DIR_TAB_FORWARD), 0)
        XCTAssertNotEqual(gtk_widget_child_focus(window, GTK_DIR_TAB_BACKWARD), 0)

        let filter = try settingsWidget("library-filter", in: window)
        gtk_widget_grab_focus(filter)
        mp_entry_set_text(filter, "Alpha")
        let text = try XCTUnwrap(mp_entry_text_delegate(filter))
        mp_test_emit_preedit_changed(text, "かな")
        XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertEqual(environment.libraryBrowserModel.filter, "Alpha")
        mp_test_emit_preedit_changed(text, "")
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertEqual(environment.libraryBrowserModel.filter, "")
        XCTAssertEqual(String(cString: mp_entry_text(filter)), "")
        XCTAssertNotEqual(gtk_widget_get_visible(window), 0)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
    }

    func testFavoriteButtonAndShortcutSaveThroughSharedIndexIncludingIdentityMigration() throws {
        try files.write(Data("Favourite body".utf8), at: "a.md")
        let window = try openLibrary()
        try select("a.md", in: window)
        let browser = environment.libraryBrowserModel
        let original = browser.selection
        try click("library-favorite", in: window)
        XCTAssertTrue(GTKTestSupport.spin { browser.state.selectedPrompt?.favorite == true })
        XCTAssertNotEqual(browser.selection?.identity, original?.identity)
        XCTAssertEqual(browser.selection?.relativePath, original?.relativePath)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.first?.favorite == true })
        XCTAssertTrue(PromptCodec.parseFile(try files.read(at: "a.md"), filename: "a.md").frontMatter.favorite)
        try selectSection(.favourites, in: window)
        XCTAssertEqual(browser.rows.count, 1)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_d), GDK_CONTROL_MASK), 0)
        XCTAssertTrue(GTKTestSupport.spin { browser.rows.isEmpty && browser.state.selectedPrompt?.favorite == false })
        XCTAssertEqual(browser.sections.first { $0.id == .favourites }?.count, 0)
        XCTAssertEqual(preview(in: window), "Favourite body")
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("library-status", in: window)), 0)
    }

    func testFavoriteWhileDirtyChangesOnlyTheDraft() throws {
        try files.write(Data("Original".utf8), at: "a.md")
        let window = try openLibrary()
        try select("a.md", in: window)
        environment.editorModel.edit("Draft")
        try click("library-favorite", in: window)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.editorModel.state.source?.contains("favorite: true") == true
        })
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertEqual(try files.read(at: "a.md"), Data("Original".utf8))
        XCTAssertEqual(environment.libraryBrowserModel.state.selectedPrompt?.favorite, false)
    }

    func testDeliveryRefreshesRecentAndOnlyRecentRowsShowLastUse() throws {
        try files.write(Data("Used prompt".utf8), at: "used.md")
        let window = try openLibrary()
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.sections.first { $0.id == .recent }?.count == 1 })
        try selectSection(.recent, in: window)
        let list = try settingsWidget("library-list", in: window)
        XCTAssertTrue(labels(in: list).contains { $0.hasPrefix("Last used:") })
        try selectSection(.all, in: window)
        XCTAssertFalse(labels(in: list).contains { $0.hasPrefix("Last used:") })
    }

    func testSwitchRebindsOpenAndHiddenWindowAndRetiresQueuedOldGraphWork() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        let window = try openLibrary()
        let old = environment.libraryBrowserModel
        try select("a.md", in: window)
        var oldPublications = 0
        old.addObserver { _ in oldPublications += 1 }
        old.setFilter("Alpha") // Leave publication queued during replacement.
        let second = tools.directory.appendingPathComponent("Second")
        let replacement = try RootedFileStore(root: second)
        try replacement.write(Data("Beta".utf8), at: "b.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        drain()
        XCTAssertEqual(oldPublications, 0)
        let browser = environment.libraryBrowserModel
        XCTAssertTrue(GTKTestSupport.spin { browser.rows.map(\.relativePath.string) == ["b.md"] })
        XCTAssertTrue(browser !== old)
        XCTAssertEqual(browser.rows.map(\.relativePath.string), ["b.md"])
        XCTAssertEqual(preview(in: window), LinuxStrings.selectLibraryPrompt)
        old.setFilter("Late")
        if case .inactive = old.toggleFavorite() {} else { XCTFail("Retired browser still accepts writes") }
        try files.write(Data("Old graph change".utf8), at: "old.md")
        drain()
        XCTAssertEqual(oldPublications, 0)
        XCTAssertEqual(try openLibrary(), window)
        try select("b.md", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.preview(in: window) == "Beta" })
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        XCTAssertEqual(try openLibrary(), window)
        XCTAssertEqual(environment.libraryBrowserModel.rows.count, 2)
        XCTAssertEqual(preview(in: window), LinuxStrings.selectLibraryPrompt)
    }

    func testQueuedOpenIsCancelledAtShutdownAndDestroyedViewIgnoresCallbacks() throws {
        environment.showLibrary()
        environment.shutdown()
        drain()
        XCTAssertTrue(libraryWindows.isEmpty)

        // Keep a native view wrapper alive after GTK destroys its borrowed window.
        let browser = environment.libraryBrowserModel
        let view = LinuxLibraryWindow(application: application, browser: browser, editor: environment.editorModel, openFolder: {})
        view.show()
        let window = try XCTUnwrap(libraryWindows.first)
        gtk_window_destroy(mp_window(window))
        browser.setFilter("Queued after destroy")
        view.rebind(browser: browser, editor: environment.editorModel)
        view.show()
        view.hide()
        drain()
        XCTAssertFalse(view.isVisible)
        XCTAssertTrue(libraryWindows.isEmpty)
    }

    private func openLibrary() throws -> GTK.Widget {
        g_action_group_activate_action(mp_action_group(application), ActionName.library.rawValue, nil)
        XCTAssertTrue(GTKTestSupport.spin { self.libraryWindows.first.map { gtk_widget_get_visible($0) != 0 } == true })
        drain()
        return try XCTUnwrap(libraryWindows.first)
    }

    private func select(_ path: String, in window: GTK.Widget) throws {
        let browser = environment.libraryBrowserModel
        let index = try XCTUnwrap(browser.rows.firstIndex { $0.relativePath.string == path })
        let list = try settingsWidget("library-list", in: window)
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(index)))
        XCTAssertTrue(GTKTestSupport.spin { browser.selection?.relativePath.string == path
            && self.environment.editorModel.state.prompt?.relativePath.string == path
            && self.environment.editorModel.state.status != .loading })
        drain()
    }

    private func selectSection(_ section: LibrarySectionID, in window: GTK.Widget) throws {
        let browser = environment.libraryBrowserModel
        let index = try XCTUnwrap(browser.sections.firstIndex { $0.id == section })
        let sidebar = try settingsWidget("library-sidebar", in: window)
        gtk_list_box_select_row(mp_list_box(sidebar), gtk_list_box_get_row_at_index(mp_list_box(sidebar), Int32(index)))
        XCTAssertTrue(GTKTestSupport.spin { browser.selectedSection == section })
        drain()
    }

    private func click(_ name: String, in window: GTK.Widget) throws {
        XCTAssertNotEqual(gtk_widget_activate(try settingsWidget(name, in: window)), 0)
    }

    private var libraryWindows: [GTK.Widget] { windows.filter { title($0) == LinuxStrings.library } }

    private var windows: [GTK.Widget] {
        var result = [GTK.Widget]()
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data { result.append(mp_window_widget(data.assumingMemoryBound(to: GtkWindow.self))) }
            node = current.pointee.next
        }
        return result
    }

    private func title(_ window: GTK.Widget) -> String? {
        gtk_window_get_title(mp_window(window)).map { String(cString: $0) }
    }

    private func rowWidget(in list: GTK.Widget, at position: Int) throws -> GTK.Widget {
        var row = gtk_widget_get_first_child(list)
        for _ in 0..<position { row = row.flatMap(gtk_widget_get_next_sibling) }
        return try XCTUnwrap(row)
    }

    private func moveCursor(in list: GTK.Widget, by count: Int32) {
        // GTK's arrow binding emits move-cursor, rather than focus traversal.
        // g_signal_emitv supplies its exact native signature without a C shim.
        var values = [GValue](repeating: GValue(), count: 5)
        g_value_init(&values[0], gtk_list_box_get_type())
        g_value_set_object(&values[0], list)
        g_value_init(&values[1], gtk_movement_step_get_type())
        g_value_set_enum(&values[1], Int32(GTK_MOVEMENT_DISPLAY_LINES.rawValue))
        g_value_init(&values[2], g_type_from_name("gint"))
        g_value_set_int(&values[2], count)
        for position in [3, 4] {
            g_value_init(&values[position], g_type_from_name("gboolean"))
            g_value_set_boolean(&values[position], 0)
        }
        values.withUnsafeMutableBufferPointer {
            g_signal_emitv($0.baseAddress, g_signal_lookup("move-cursor", gtk_list_box_get_type()), 0, nil)
        }
        for position in values.indices { g_value_unset(&values[position]) }
    }

    private func labelText(_ label: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(label))) }

    private func labels(in widget: GTK.Widget) -> [String] {
        // Widget type names let tests traverse the real GTK tree without new shim APIs.
        var result = [String]()
        if String(cString: g_type_name_from_instance(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self))) == "GtkLabel" {
            result.append(labelText(widget))
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            result += labels(in: current)
            child = gtk_widget_get_next_sibling(current)
        }
        return result
    }

    private func preview(in window: GTK.Widget) -> String {
        guard let widget = try? settingsWidget("library-preview", in: window) else { return "" }
        let buffer = gtk_text_view_get_buffer(mp_text_view(widget))!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(text) }
        return String(cString: text)
    }

    private func drain() {
        var drained = false
        GTK.onMainLoop { GTK.onMainLoop { drained = true } }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

#endif
