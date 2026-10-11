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
    private var launchedURLs: [URL] = []

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
        launchedURLs = []
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            launchURI: { [weak self] url in
                guard let self else { return }
                XCTAssertFalse(self.environment.panel.isVisible)
                self.launchedURLs.append(url)
            })
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

    func testSearchPreeditKeepsReturnAndEscapeNativeUntilCompositionEnds() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        // A failing regression may start asynchronous delivery. Drain it before
        // tearDown destroys the native clipboard owner.
        defer { _ = GTKTestSupport.spin { self.environment.pickerModel.state != .delivering } }
        let query = try widget("picker-query")
        let text = try XCTUnwrap(mp_entry_text_delegate(query))
        mp_test_emit_preedit_changed(text, "かな")

        XCTAssertFalse(sendKey(GDK_KEY_Return))
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertFalse(environment.pickerModel.isResolvingBuiltins)
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertFalse(sendKey(GDK_KEY_Escape))
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertTrue(environment.panel.isVisible)

        mp_test_emit_preedit_changed(text, "")
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin {
            if case .done = self.environment.pickerModel.state { return true }
            return false
        })
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testFillPreeditKeepsDeliveryAndEscapeNativeForBothTextKinds() throws {
        // A failing regression may start asynchronous delivery. Drain it before
        // tearDown destroys the native clipboard owner.
        defer { _ = GTKTestSupport.spin { self.environment.pickerModel.state != .delivering } }
        try files.write(Data("---\nfields:\n  topic: {default: Topic}\n  detail: {type: multiline, default: Detail}\n---\n{{topic}} {{detail}}".utf8), at: "fields.md")
        try open()
        environment.pickerModel.use(mode: .copyOnly)
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })

        for name in ["topic", "detail"] {
            let control = try widget("fill-field-" + name)
            XCTAssertNotEqual(gtk_widget_grab_focus(control), 0)
            let input = name == "topic" ? try XCTUnwrap(mp_entry_text_delegate(control)) : control
            mp_test_emit_preedit_changed(input, "かな")
            // Ctrl+Return would deliver even from a multiline field.
            XCTAssertFalse(sendKey(GDK_KEY_Return, modifiers: GDK_CONTROL_MASK))
            if name == "topic" { XCTAssertFalse(sendKey(GDK_KEY_Return)) }
            XCTAssertFalse(sendKey(GDK_KEY_Escape))
            XCTAssertEqual(environment.pickerModel.state, .fill)
            XCTAssertEqual(fill.state, .editing)
            XCTAssertTrue(environment.panel.isVisible)
            mp_test_emit_preedit_changed(input, "")
        }

        XCTAssertTrue(sendKey(GDK_KEY_Escape))
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertTrue(environment.panel.isVisible)
    }

    func testPreeditInUnfocusedControlDoesNotBlockPickerKeys() throws {
        try files.write(Data("{{topic}}".utf8), at: "fields.md")
        try open()
        let query = try widget("picker-query")
        mp_test_emit_preedit_changed(try XCTUnwrap(mp_entry_text_delegate(query)), "かな")
        let use = try widget("picker-use")
        XCTAssertNotEqual(gtk_widget_grab_focus(use), 0)
        XCTAssertTrue(sendKey(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertEqual(environment.pickerModel.state, .fill)
        XCTAssertEqual(environment.pickerModel.fillModel?.preferredMode, .copyOnly)
    }

    func testToggleRaisesVisibleInactivePickerInsteadOfClosingIt() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        let other = try XCTUnwrap(gtk_application_window_new(application))
        defer { gtk_window_destroy(mp_window(other)) }
        gtk_window_present(mp_window(other))
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.panel.isVisible && !self.environment.panel.isActiveAndVisible
                && gtk_window_is_active(mp_window(other)) != 0
        })
        gtk_window_set_focus(mp_window(environment.panel.clipboardOwner), nil)

        environment.activateToggle()
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertEqual(environment.pickerModel.state, .picker)
        // Bare Xvfb has no window manager to grant reactivation of a mapped
        // window. Restored query focus proves the queued presentation ran.
        let query = try widget("picker-query")
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        var presented = false
        // Drain promptly like the native loop: the common spin helper's 5 ms
        // pause per iteration can delay idle presentation behind the blur timer.
        while !presented, ContinuousClock().now < deadline {
            _ = g_main_context_iteration(nil, 0)
            guard let focus = gtk_window_get_focus(mp_window(self.environment.panel.clipboardOwner)) else { continue }
            presented = focus == query || gtk_widget_is_ancestor(focus, query) != 0
        }
        XCTAssertTrue(presented)
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertEqual(environment.pickerModel.state, .picker)
        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
    }

    func testFieldDescriptionsAppearBelowControlsOnlyWhenNonempty() throws {
        let source = """
        ---
        fields:
          topic: {description: Describe the topic}
          detail: {type: multiline, description: Add details}
          language: {type: choice, options: [Swift, Rust], description: Choose a language}
          plain: {}
          empty: {description: ""}
        ---
        {{topic}} {{detail}} {{language}} {{plain}} {{empty}}
        """
        try files.write(Data(source.utf8), at: "fields.md")
        try open()
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.builtinsResolved == true })
        for (name, text) in [("topic", "Describe the topic"), ("detail", "Add details"),
                             ("language", "Choose a language")] {
            let description = try widget("fill-description-" + name)
            XCTAssertEqual(String(cString: gtk_label_get_text(mp_label(description))), text)
            XCTAssertNotEqual(gtk_widget_is_visible(description), 0)
            let control = try widget("fill-field-" + name)
            let preceding = name == "detail" ? gtk_widget_get_parent(control) : control
            XCTAssertEqual(gtk_widget_get_next_sibling(preceding), description)
        }
        for name in ["plain", "empty"] {
            XCTAssertNil(findWidget { String(cString: gtk_widget_get_name($0)) == "fill-description-" + name })
        }
    }

    func testNoMatchCreationPreservesTitleAfterFilenameSanitizing() throws {
        try createPrompt(query: "a/b", expectedPath: "a b.md")
    }

    func testNoMatchCreationPreservesTitleAfterFilenameCollision() throws {
        try files.write(Data("---\ntitle: Unrelated\n---\nExisting body".utf8), at: "Name.md")
        try createPrompt(query: "Name", expectedPath: "Name 2.md")
        XCTAssertEqual(try files.read(at: "Name.md"), Data("---\ntitle: Unrelated\n---\nExisting body".utf8))
    }

    func testEditSelectedLaunchesFileURIAndDismissesPicker() throws {
        let path = "folder name/Prompt #%.md"
        try files.write(Data("Body".utf8), at: path)
        try open()
        XCTAssertEqual(environment.pickerModel.results.first?.relativePath, path)

        environment.pickerModel.editSelected()
        XCTAssertNil(environment.pickerModel.requestedIntent)
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertTrue(GTKTestSupport.spin { !self.launchedURLs.isEmpty })
        XCTAssertEqual(launchedURLs, [root.appendingPathComponent(path)])
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testNativeOpenLibraryButtonLaunchesFolderURIAndDismissesPicker() throws {
        try open()
        mp_entry_set_text(try widget("picker-query"), "missing prompt")
        let button = try widget("picker-open-folder")
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin { !self.launchedURLs.isEmpty })
        XCTAssertNil(environment.pickerModel.requestedIntent)
        XCTAssertEqual(launchedURLs, [URL(fileURLWithPath: root.path, isDirectory: true)])
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testUnavailableLibraryShortcutsKeepPickerQueryAndSelection() throws {
        try files.write(Data("Cached Alpha".utf8), at: "cached-alpha.md")
        try files.write(Data("Cached Beta".utf8), at: "cached-beta.md")
        try open()
        let picker = environment.pickerModel
        let query = try widget("picker-query")
        mp_entry_set_text(query, "cached")
        let list = try widget("picker-results")
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), 1))
        XCTAssertEqual(picker.selectionIndex, 1)
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(GTKTestSupport.spin { !picker.libraryAvailable })

        for key in [GDK_KEY_l, GDK_KEY_Return] {
            XCTAssertTrue(sendKey(key, modifiers: GDK_CONTROL_MASK))
            var uiDrained = false
            environment.mainThread.run { uiDrained = true }
            XCTAssertTrue(GTKTestSupport.spin { uiDrained })
            XCTAssertNil(picker.requestedIntent)
            XCTAssertEqual(picker.state, .picker)
            XCTAssertTrue(environment.panel.isVisible)
            XCTAssertTrue(launchedURLs.isEmpty)
            XCTAssertEqual(picker.query, "cached")
            XCTAssertEqual(String(cString: mp_entry_text(query)), "cached")
            XCTAssertEqual(picker.selectionIndex, 1)
            let status = try widget("picker-status")
            XCTAssertEqual(String(cString: gtk_label_get_text(mp_label(status))), LinuxStrings.libraryUnavailable)
            XCTAssertNotEqual(gtk_widget_get_visible(status), 0)
        }
    }

    func testTransientCreationFailureStatusIsClearedWhenPickerReopens() throws {
        try open()
        let query = try widget("picker-query")
        mp_entry_set_text(query, "new prompt")
        environment.panel.showStatus(LinuxStrings.createPromptFailed)
        let status = try widget("picker-status")
        XCTAssertEqual(String(cString: gtk_label_get_text(mp_label(status))), LinuxStrings.createPromptFailed)
        XCTAssertNotEqual(gtk_widget_get_visible(status), 0)

        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        // Keep the query unchanged so its changed signal cannot clear the status.
        XCTAssertEqual(environment.pickerModel.query, "new prompt")
        XCTAssertEqual(String(cString: mp_entry_text(query)), "new prompt")
        XCTAssertEqual(String(cString: gtk_label_get_text(mp_label(status))), "")
        XCTAssertEqual(gtk_widget_get_visible(status), 0)
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
        XCTAssertTrue(GTKTestSupport.spin {
            guard let focus = gtk_window_get_focus(mp_window(self.environment.panel.clipboardOwner)) else { return false }
            return focus == query || gtk_widget_is_ancestor(focus, query) != 0
        })
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
        XCTAssertTrue(GTKTestSupport.spin {
            guard let focus = gtk_window_get_focus(mp_window(self.environment.panel.clipboardOwner)) else { return false }
            return focus == topic || gtk_widget_is_ancestor(focus, topic) != 0
        })
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

    func testEmptyRootLossShowsBannerAndRestorationRequiresRestart() throws {
        try open()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertTrue(environment.pickerModel.results.isEmpty)
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.pickerModel.libraryAvailable })
        XCTAssertTrue(String(cString: gtk_label_get_text(mp_label(try widget("picker-status"))))
            .contains(LinuxStrings.libraryUnavailable))
        try files.write(Data("Restored".utf8), at: "restored.md")
        let deadline = Date().addingTimeInterval(0.8)
        _ = GTKTestSupport.spin { Date() >= deadline }
        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertTrue(environment.pickerModel.results.isEmpty)
    }

    func testRootLossDuringPendingModificationRetainsCachedPrompt() throws {
        let scheduler = PickerWatchScheduler()
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
                                       scheduler: scheduler)
        try files.write(Data("Cached".utf8), at: "cached.md")
        try open()
        XCTAssertTrue(scheduler.delays.isEmpty)
        try Data("Pending edit".utf8).write(to: root.appendingPathComponent("cached.md"))
        // A queued debounce proves the real driver observed the modification.
        // This scheduler holds it pending regardless of native-loop timing.
        XCTAssertTrue(GTKTestSupport.spin { scheduler.delays.contains(Limits.watchDebounce) })
        XCTAssertTrue(scheduler.delays.allSatisfy { $0 == Limits.watchDebounce })
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("Cached"))
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(GTKTestSupport.spin { scheduler.delays.contains(.zero) })
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        // Health flushes the pending modification before stopping the graph.
        scheduler.fireAll()
        // Let any index publication reach the picker before checking its cache.
        var uiDrained = false
        environment.mainThread.run { uiDrained = true }
        XCTAssertTrue(GTKTestSupport.spin { uiDrained })
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.pickerModel.results.count, 1)
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("Cached"))
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

    private func sendKey(_ key: Int32, modifiers: GdkModifierType = GdkModifierType(rawValue: 0)) -> Bool {
        mp_test_emit_key_pressed(environment.panel.clipboardOwner, UInt32(key), modifiers) != 0
    }

    private func widget(_ name: String) throws -> GTK.Widget {
        try XCTUnwrap(findWidget { String(cString: gtk_widget_get_name($0)) == name }, "Missing GTK control \(name)")
    }

    private func createPrompt(query: String, expectedPath: String) throws {
        try open()
        mp_entry_set_text(try widget("picker-query"), query)
        XCTAssertEqual(environment.pickerModel.noMatches?.createTitle, query)
        let createLabel = try XCTUnwrap(environment.pickerModel.noMatches?.createLabel)
        let button = try XCTUnwrap(findWidget {
            mp_is_button($0) != 0 && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == createLabel
        })
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.files.stamp(at: expectedPath)) != nil })
        let document = PromptCodec.parseFile(try files.read(at: expectedPath), filename: expectedPath)
        XCTAssertEqual(document.frontMatter.title, query)
        XCTAssertEqual(document.body, LinuxStrings.newPromptBody)
        XCTAssertTrue(document.canRender)
        XCTAssertNotNil(document.frontMatter.id)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        XCTAssertTrue(GTKTestSupport.spin { !self.launchedURLs.isEmpty })
        XCTAssertEqual(launchedURLs, [root.appendingPathComponent(expectedPath)])
    }

    private func findWidget(matching predicate: (GTK.Widget) -> Bool) -> GTK.Widget? {
        func find(_ widget: GTK.Widget) -> GTK.Widget? {
            if predicate(widget) { return widget }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if let found = find(current) { return found }
                child = gtk_widget_get_next_sibling(current)
            }
            return nil
        }
        return find(environment.panel.clipboardOwner)
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

private final class PickerWatchScheduler: Scheduler {
    private(set) var delays = [Duration]()
    private var callbacks = [() -> Void]()

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        callbacks.append(work)
    }

    func fireAll() {
        let pending = callbacks
        callbacks.removeAll()
        for work in pending { work() }
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
