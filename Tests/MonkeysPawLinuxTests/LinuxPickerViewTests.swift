#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPickerViewTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var notifications: FakePortal!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var root: URL!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        root = LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw")
        files = try RootedFileStore(root: root)
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        files = nil
        tools = nil
    }

    func testQueryAndNativeRowSelectionDeliverFromTheLiveLibrary() throws {
        try files.write(Data("---\ntitle: Alpha\nfavorite: true\ntags: [code]\n---\nAlpha body".utf8), at: "a.md")
        try files.write(Data("Beta body".utf8), at: "b.md")
        try open()
        XCTAssertEqual(environment.pickerModel.results.count, 2)
        XCTAssertEqual(environment.pickerModel.selectionIndex, 0)
        let list = try widget("picker-results")
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), 1))
        XCTAssertEqual(environment.pickerModel.selectionIndex, 1)
        XCTAssertEqual(text(in: try widget("picker-preview")), "Beta body")

        mp_entry_set_text(try widget("picker-query"), "Alpha")
        XCTAssertEqual(environment.pickerModel.query, "Alpha")
        XCTAssertEqual(environment.pickerModel.results.map(\.title), ["Alpha"])
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
        let clipboard = PickerClipboardRead()
        GTKClipboard(owner: environment.panel.clipboardOwner).readText { clipboard.store($0) }
        XCTAssertTrue(GTKTestSupport.spin { clipboard.value == "Alpha body" })
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        XCTAssertEqual(try UsageStore(files: data, clock: SystemClock()).useEvents(
            for: environment.pickerModel.results[0].identity).count, 1)
    }

    func testClipboardSnapshotDisablesUseUntilSharedClipboardReadCompletes() throws {
        try files.write(Data("{{clipboard}}".utf8), at: "clipboard.md")
        try open()
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("Snapshot")
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("{{clipboard}}"))
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(environment.pickerModel.isResolvingBuiltins)
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("picker-use")), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("picker-copy")), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
        let clipboard = PickerClipboardRead()
        GTKClipboard(owner: environment.panel.clipboardOwner).readText { clipboard.store($0) }
        XCTAssertTrue(GTKTestSupport.spin { clipboard.value == "Snapshot" })
    }

    func testReopeningWhileFillIsVisibleReturnsFocusToQueryAndKeepsDraft() throws {
        try files.write(Data("{{topic}}".utf8), at: "fields.md")
        try open()
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.builtinsResolved == true })
        mp_entry_set_text(try widget("fill-field-topic"), "Draft")
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let focus = gtk_window_get_focus(mp_window(self.environment.panel.clipboardOwner)),
                  let entry = try? self.widget("picker-query") else { return false }
            return focus == entry || gtk_widget_is_ancestor(focus, entry) != 0
        })
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.builtinsResolved == true })
        XCTAssertEqual(environment.pickerModel.fillModel?.values["topic"], "Draft")
        environment.pickerModel.escape()
        XCTAssertEqual(environment.pickerModel.state, .picker)
        let query = try widget("picker-query")
        let focus = try XCTUnwrap(gtk_window_get_focus(mp_window(environment.panel.clipboardOwner)))
        XCTAssertTrue(focus == query || gtk_widget_is_ancestor(focus, query) != 0)
    }

    func testRememberedChoiceOutsideCurrentOptionsBlocksDeliveryWithActionablePreview() throws {
        try files.write(Data("---\nfields:\n  language:\n    type: choice\n    options: [Rust, Swift]\n    default: Rust\n---\n{{language}}".utf8), at: "choice.md")
        try open()
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        try ValuesStore(files: data).record(identity: identity, values: ["language": "Java"])
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.builtinsResolved == true })
        let choice = try widget("fill-field-language")
        XCTAssertNil(gtk_combo_box_get_active_id(mp_combo_box(choice)))
        XCTAssertEqual(environment.pickerModel.fillModel?.deliverEnabled, false)
        XCTAssertEqual(text(in: try widget("picker-preview")), PromptRenderError.invalidChoiceValue("language").description)
        gtk_combo_box_set_active_id(mp_combo_box(choice), "Swift")
        XCTAssertEqual(environment.pickerModel.fillModel?.values["language"], "Swift")
        XCTAssertEqual(text(in: try widget("picker-preview")), "Swift")
    }

    func testAllFieldKindsUpdatePreviewKeepControlsAndRetainDraftOnToggle() throws {
        let source = """
        ---
        title: Field kinds
        fields:
          topic:
            label: Topic
            description: Describe the topic
            default: Swift
          detail:
            type: multiline
            default: First line
          language:
            type: choice
            options:
              - {label: English, value: en}
              - {label: French, value: fr}
            default: en
        ---
        {{topic}}: {{detail}} ({{language}})
        """
        try files.write(Data(source.utf8), at: "fields.md")
        try open()
        environment.pickerModel.use(mode: .paste(.terminal))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertEqual(fill.preferredMode, .paste(.terminal))
        let topic = try widget("fill-field-topic")
        let detail = try widget("fill-field-detail")
        let language = try widget("fill-field-language")
        mp_entry_set_text(topic, "Rust")
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(detail)), "Line one\nLine two", -1)
        gtk_combo_box_set_active_id(mp_combo_box(language), "fr")
        XCTAssertEqual(fill.values, ["topic": "Rust", "detail": "Line one\nLine two", "language": "fr"])
        XCTAssertEqual(text(in: try widget("picker-preview")), "Rust: Line one\nLine two (fr)")
        XCTAssertEqual(topic, try widget("fill-field-topic"))
        XCTAssertEqual(String(cString: try XCTUnwrap(gtk_widget_get_tooltip_text(topic))), "Describe the topic")

        gtk_widget_grab_focus(language)
        XCTAssertEqual(fill.focusIndex, 2)
        fill.focusNext()
        XCTAssertEqual(fill.focusIndex, 0)
        let focus = try XCTUnwrap(gtk_window_get_focus(mp_window(environment.panel.clipboardOwner)))
        XCTAssertTrue(focus == topic || gtk_widget_is_ancestor(focus, topic) != 0)
        environment.activateToggle()
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertEqual(fill.state, .closed)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        environment.pickerModel.use(mode: .copyOnly)
        let reopened = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertEqual(reopened.values, fill.values)
        XCTAssertTrue(GTKTestSupport.spin { reopened.deliverEnabled })
        reopened.deliver(mode: reopened.preferredMode)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
    }

    func testWatcherPublishesExternalChangesAndRootLossRetainsCachedPrompts() throws {
        try files.write(Data("First".utf8), at: "a.md")
        try open()
        try files.write(Data("Second".utf8), at: "b.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.count == 2 })
        try files.write(Data("Updated".utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.selectedPreview == .body("Updated") })
        try FileManager.default.moveItem(at: root, to: tools.directory.appendingPathComponent("retired-library"))
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.pickerModel.libraryAvailable })
        XCTAssertEqual(environment.pickerModel.results.count, 2)
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("Updated"))
        XCTAssertTrue(String(cString: gtk_label_get_text(mp_label(try widget("picker-status"))))
            .contains(LinuxStrings.libraryUnavailable))
    }

    func testServiceGraphKeepsOneRootWhenUserDirectoriesChangeBeforeStart() throws {
        try files.write(Data("First".utf8), at: "a.md")
        _ = environment.pickerModel // Compose stores before watcher startup.
        let config = LinuxPaths(environment: tools.environment).configDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let otherDocuments = tools.directory.appendingPathComponent("OtherDocuments")
        try Data("XDG_DOCUMENTS_DIR=\"\(otherDocuments.path)\"\n".utf8)
            .write(to: config.appendingPathComponent("user-dirs.dirs"))
        try open()
        XCTAssertEqual(environment.pickerModel.results.count, 1)
        try files.write(Data("Second".utf8), at: "b.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.count == 2 })
    }

    func testUnavailableRootDoesNotCrashAndNoMatchesShowDisabledAssistant() throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Not a directory".utf8).write(to: root)
        try open()
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        mp_entry_set_text(try widget("picker-query"), "new prompt")
        XCTAssertEqual(environment.pickerModel.noMatches?.createTitle, "new prompt")
        XCTAssertEqual(gtk_widget_get_sensitive(try widget("picker-assistant")), 0)
        XCTAssertEqual(String(cString: try XCTUnwrap(gtk_widget_get_tooltip_text(try widget("picker-assistant")))),
                       LinuxStrings.assistantNotConfigured)
    }

    private func open() throws {
        environment.activateToggle()
        // Wait for native focus-in before switching controls; visible alone
        // still leaves the X11 focus event queued on GTK 4.8.
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
        _ = try widget("picker-query")
    }

    private func widget(_ name: String) throws -> GTK.Widget {
        func find(_ widget: GTK.Widget) -> GTK.Widget? {
            if String(cString: gtk_widget_get_name(widget)) == name { return widget }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if let found = find(current) { return found }
                child = gtk_widget_get_next_sibling(current)
            }
            return nil
        }
        return try XCTUnwrap(find(environment.panel.clipboardOwner), "Missing GTK control \(name)")
    }

    private func text(in view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let value = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(value) }
        return String(cString: value)
    }
}

private final class PickerClipboardRead: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
    func store(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        text = value
    }
}
#endif
