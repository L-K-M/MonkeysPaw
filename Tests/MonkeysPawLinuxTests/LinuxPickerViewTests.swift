#if os(Linux)
import CGtk
import Foundation
import Glibc
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

    func testTerminalPrimaryReturnReachesInjector() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try configureX11Target(windowClass: "Gnome-terminal")
        try open()
        XCTAssertTrue(hintText().contains("X11 terminal · Ctrl+Shift+V"))
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+shift+v"])
        XCTAssertEqual(tools.arguments.filter { $0 == ["getactivewindow"] }.count, 1)
    }

    func testTerminalPrimaryButtonAndRowActivationUseRecommendation() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try configureX11Target(windowClass: "kitty")
        try open()
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-use")), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        try open()
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(mp_list_box(try widget("picker-results")), 0))
        XCTAssertNotEqual(GTKTestSupport.activate(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self)), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.filter { $0.first == "key" }, [
            ["key", "--clearmodifiers", "ctrl+shift+v"], ["key", "--clearmodifiers", "ctrl+shift+v"],
        ])
    }

    func testUnknownXtermUsesStandardAndExplicitTerminalWins() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try configureX11Target(windowClass: "XTerm")
        try open()
        XCTAssertTrue(hintText().contains("X11 target · Ctrl+V"))
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        try open()
        XCTAssertTrue(sendKey(GDK_KEY_Return, modifiers: GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.filter { $0.first == "key" }, [
            ["key", "--clearmodifiers", "ctrl+v"], ["key", "--clearmodifiers", "ctrl+shift+v"],
        ])
    }

    func testSavedDefaultFillModeSurvivesPreferenceChangeAndMultilineReturnStaysNative() throws {
        try files.write(Data("---\nfields:\n  detail: {type: multiline, default: Detail}\n---\n{{detail}}".utf8), at: "a.md")
        try configureX11Target(windowClass: "Firefox", defaultChord: .terminal)
        try open()
        XCTAssertTrue(hintText().contains("X11 target · Ctrl+Shift+V"))
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertEqual(fill.preferredMode, .paste(.terminal))
        environment.settingsModel.setLinuxDefaultPasteChord(.standard)
        fill.setValue("First\nSecond", name: "detail")
        XCTAssertTrue(hintText().contains("X11 target · Ctrl+Shift+V"))
        XCTAssertFalse(sendKey(GDK_KEY_Return))
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(environment.pickerModel.state, .fill)
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-use")), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+shift+v"])
    }

    func testTerminalFillExplicitStandardAndCopyChoicesWin() throws {
        try files.write(Data("---\nfields:\n  topic: {default: Topic}\n---\n{{topic}}".utf8), at: "a.md")
        try configureX11Target(windowClass: "kitty")
        try open()
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.deliverEnabled == true })
        XCTAssertTrue(sendKey(GDK_KEY_Return, modifiers: GDK_CONTROL_MASK))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+v"])
        try open()
        XCTAssertTrue(sendKey(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertEqual(fill.preferredMode, .copyOnly)
        XCTAssertTrue(hintText().contains("X11 terminal · Copy only"))
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(tools.arguments.filter { $0.first == "key" }.count, 1)
    }

    func testPreferredTerminalFallbackNotificationCarriesCapturedTargetAndChord() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        tools.environment["FAKE_PASTE_STATUS"] = "1"
        try configureX11Target(windowClass: "Alacritty")
        try open()
        XCTAssertTrue(hintText().contains("X11 terminal · Ctrl+Shift+V"))
        XCTAssertTrue(sendKey(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin {
            if case .done(.copiedOnly(.backendsFailed)) = self.environment.pickerModel.state { return true }
            return false
        })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+shift+v"])
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
        XCTAssertEqual(notifications.notificationBodies.last, "Copied. Press Ctrl+Shift+V\nX11 terminal")
    }

    private func configureX11Target(windowClass: String, defaultChord: PasteChord = .standard) throws {
        environment.shutdown()
        tools.environment["XDG_SESSION_TYPE"] = "x11"
        tools.environment["FAKE_WM_CLASS"] = "WM_CLASS(STRING) = \"instance\", \"\(windowClass)\""
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments + #"""

            case "$1" in
                getactivewindow) printf '12345\n' ;;
                key) exit "${FAKE_PASTE_STATUS-0}" ;;
                *) exit 1 ;;
            esac
            """#)
        try tools.install("xprop", script: #"printf '%s\n' "$FAKE_WM_CLASS""#)
        let config = try RootedFileStore(root: LinuxPaths(environment: tools.environment).configDirectory)
        let settings = SettingsService(store: SettingsStore(files: config))
        try settings.setLinuxDefaultPasteChord(defaultChord)
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    private func hintText() -> String {
        guard let label = try? widget("picker-hint") else { return "" }
        return String(cString: gtk_label_get_text(mp_label(label)))
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

    func testDestroyedPanelIgnoresPendingBlurAndQueuedUIWork() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        let panel = environment.panel
        let picker = environment.pickerModel
        let other = try XCTUnwrap(gtk_application_window_new(application))
        defer { gtk_window_destroy(mp_window(other)) }
        gtk_window_present(mp_window(other))
        let lostFocus = GTKTestSupport.spin {
            panel.isVisible && !panel.isActiveAndVisible
                && gtk_window_is_active(mp_window(other)) != 0
        }
        XCTAssertTrue(lostFocus)
        guard lostFocus else { return }
        XCTAssertEqual(picker.state, .picker)

        // Keep the Swift panel alive after destroying its borrowed GTK window,
        // before the focus-out timer can run on the next main-loop iteration.
        gtk_window_destroy(mp_window(panel.clipboardOwner))
        let deadline = ContinuousClock().now.advanced(by: Limits.blurHideDelay + .milliseconds(100))
        XCTAssertTrue(GTKTestSupport.spin { ContinuousClock().now >= deadline })
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isActiveAndVisible)
        XCTAssertEqual(picker.state, .picker)

        var queuedUIRan = false
        environment.mainThread.run {
            picker.setQuery("after destruction")
            panel.showStatus(LinuxStrings.createPromptFailed)
            panel.show()
            panel.hide()
            panel.hideForDelivery()
            queuedUIRan = true
        }
        XCTAssertTrue(GTKTestSupport.spin { queuedUIRan })
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isActiveAndVisible)
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

    func testToggleRequestSurvivesBlurWhilePresentationIsQueued() throws {
        try assertPresentationSurvivesQueuedBlur { self.environment.activateToggle() }
    }

    func testLauncherRequestSurvivesBlurWhilePresentationIsQueued() throws {
        environment.settingsModel.markSetupPresented()
        environment.settingsModel.completeLibraryFolderStep()
        environment.settingsModel.markSeedsOffered()
        environment.settingsModel.completeTour()
        XCTAssertNil(environment.settingsModel.error)
        try assertPresentationSurvivesQueuedBlur { self.environment.presentFromLauncher() }
    }

    func testBlurWithoutAnotherPresentationStillDismissesPicker() throws {
        try open()
        let other = try XCTUnwrap(gtk_application_window_new(application))
        defer { gtk_window_destroy(mp_window(other)) }
        gtk_window_present(mp_window(other))
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.pickerModel.state == .closed && !self.environment.panel.isVisible
        })
    }

    private func assertPresentationSurvivesQueuedBlur(_ request: () -> Void) throws {
        try open()
        XCTAssertTrue(GTKTestSupport.spin { g_main_context_pending(nil) == 0 })
        let window = UnsafeMutableRawPointer(environment.panel.clipboardOwner).assumingMemoryBound(to: GObject.self)
        // Hold focus notifications so native focus handoff cannot start the blur timer yet.
        g_object_freeze_notify(window)
        var notificationsFrozen = true
        defer { if notificationsFrozen { g_object_thaw_notify(window) } }
        let other = try XCTUnwrap(gtk_application_window_new(application))
        defer { gtk_window_destroy(mp_window(other)) }
        gtk_window_present(mp_window(other))
        let picker = environment.pickerModel
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.panel.isVisible && !self.environment.panel.isActiveAndVisible
                && gtk_window_is_active(mp_window(other)) != 0
        })
        XCTAssertEqual(picker.state, .picker)

        // GLib allocates source IDs in order. Thaw synchronously queues the blur
        // timeout; bracket it without iterating the loop, then hold that source.
        let before = GTK.after(.greatestFiniteMagnitude) {}
        g_source_remove(before)
        g_object_thaw_notify(window)
        notificationsFrozen = false
        let after = GTK.after(.greatestFiniteMagnitude) {}
        g_source_remove(after)
        let sources = ((before + 1)..<after).compactMap { g_main_context_find_source_by_id(nil, $0) }
            .filter { g_source_get_ready_time($0) > 0 }
        XCTAssertEqual(sources.count, 1, "Focus loss must queue one blur timer.")
        let blur = try XCTUnwrap(sources.first)
        g_source_ref(blur)
        defer {
            g_source_destroy(blur)
            g_source_unref(blur)
        }
        XCTAssertEqual(g_source_get_priority(blur), G_PRIORITY_DEFAULT)
        XCTAssertGreaterThan(g_source_get_ready_time(blur), 0)
        g_source_set_ready_time(blur, -1)

        let render = picker.onChange
        defer { picker.onChange = render }
        var delayedPresentation = false
        picker.onChange = { [weak picker] in
            render?()
            guard !delayedPresentation else { return }
            XCTAssertEqual(picker?.state, .picker, "Blur fired before the new show was queued.")
            guard picker?.state == .picker else { return }
            delayedPresentation = true
            // A ready timeout precedes the queued show idle, independent of host load.
            g_source_set_ready_time(blur, 0)
        }
        request()
        XCTAssertTrue(GTKTestSupport.spin { delayedPresentation })
        var drained = false
        environment.mainThread.run { self.environment.mainThread.run { drained = true } }
        XCTAssertTrue(GTKTestSupport.spin { drained })
        XCTAssertNotEqual(g_source_is_destroyed(blur), 0, "The stale blur timer must have fired.")
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(environment.panel.isVisible)
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
        let originalStamp = try files.stamp(at: "Name.md")
        try createPrompt(query: "Name", expectedPath: "Name 2.md")
        XCTAssertEqual(try files.read(at: "Name.md"), Data("---\ntitle: Unrelated\n---\nExisting body".utf8))
        XCTAssertEqual(try files.stamp(at: "Name.md"), originalStamp)
    }

    func testEditSelectedOpensLibraryEditorAndDismissesPicker() throws {
        let path = "folder name/Prompt #%.md"
        try files.write(Data("Body".utf8), at: path)
        try open()
        XCTAssertEqual(environment.pickerModel.results.first?.relativePath, path)

        environment.pickerModel.editSelected()
        XCTAssertNil(environment.pickerModel.requestedIntent)
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == path
            && self.environment.editorModel.state.source == "Body" }, "Editor did not load the selected path '\(path)'")
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testFooterPresentsFlatKeyHintButtonsAndOverflowMenu() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        for (name, hint) in [("picker-use", LinuxPickerStrings.useHint),
                             ("picker-copy", LinuxPickerStrings.copyHint),
                             ("picker-edit", LinuxPickerStrings.editHint),
                             ("picker-open-folder", LinuxPickerStrings.libraryHint)] {
            let button = try widget(name)
            XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), hint, name)
            XCTAssertEqual(gtk_widget_has_css_class(button, "flat"), 1, name)
        }
        _ = try widget("picker-menu")
        for (name, title) in [("picker-forget-values", LinuxStrings.forgetValues),
                              ("picker-setup", LinuxStrings.setup),
                              ("picker-settings", LinuxStrings.openSettings)] {
            let item = try widget(name)
            XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(item))), title, name)
        }
        XCTAssertNotEqual(gtk_widget_get_visible(try widget("picker-forget-values")), 0)
    }

    func testFooterUseButtonOpensFillAndBecomesSuggestedDeliver() throws {
        try files.write(Data("{{topic}}".utf8), at: "a.md")
        try open()
        let use = try widget("picker-use")
        XCTAssertNotEqual(GTKTestSupport.activate(use), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .fill })
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(use))), LinuxPickerStrings.deliverHint)
        XCTAssertEqual(gtk_widget_has_css_class(use, "suggested-action"), 1)
        XCTAssertEqual(gtk_widget_get_visible(try widget("picker-edit")), 0)
        XCTAssertEqual(gtk_widget_get_visible(try widget("picker-open-folder")), 0)
    }

    func testFooterUseButtonDeliversFieldlessPrompt() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try configureX11Target(windowClass: "kitty")
        try open()
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-use")), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+shift+v"])
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testFooterCopyButtonCopiesPromptWithoutOpeningFill() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        let copy = try widget("picker-copy")
        XCTAssertNotEqual(GTKTestSupport.activate(copy), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertFalse(environment.panel.isVisible)
        let clipboard = PickerClipboardRead()
        GTKClipboard(owner: environment.panel.clipboardOwner).readText { clipboard.store($0) }
        XCTAssertTrue(GTKTestSupport.spin { clipboard.value == "Body" })
    }

    func testFooterEditButtonOpensLibraryEditorAndDismissesPicker() throws {
        let path = "sub dir/Prompt.md"
        try files.write(Data("Body".utf8), at: path)
        try open()
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-edit")), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .closed })
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.editorModel.state.prompt?.relativePath.string == path
                && self.environment.editorModel.state.source == "Body" })
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testFooterLibraryButtonOpensLibraryAndDismissesPicker() throws {
        try files.write(Data("Body".utf8), at: "a.md")
        try open()
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-open-folder")), 0)
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(self.application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.library
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testNativeOpenLibraryButtonOpensBrowserAndDismissesPicker() throws {
        try open()
        mp_entry_set_text(try widget("picker-query"), "missing prompt")
        let button = try widget("picker-library")
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), LinuxStrings.library)
        XCTAssertNotEqual(GTKTestSupport.activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(self.application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.library
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
        XCTAssertNil(environment.pickerModel.requestedIntent)
        XCTAssertTrue(launchedURLs.isEmpty)
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

    func testExternalInPlaceSaveReachesPickerWithinOneSecondThroughGFileMonitor() throws {
        try assertExternalSaveWithinOneSecond(.inPlace)
    }

    func testExternalAtomicReplaceReachesPickerWithinOneSecondThroughGFileMonitor() throws {
        try assertExternalSaveWithinOneSecond(.atomicReplace)
    }

    private enum ExternalSaveMode: String {
        case inPlace = "in-place"
        case atomicReplace = "atomic-replace"
    }

    private func assertExternalSaveWithinOneSecond(_ mode: ExternalSaveMode) throws {
        try files.write(Data("---\ntitle: Original\n---\nOriginal body".utf8), at: "external.md")
        try open()
        XCTAssertEqual(environment.pickerModel.results.map(\.title), ["Original"])
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("Original body"))
        let preview = try widget("picker-preview")
        let destination = root.appendingPathComponent("external.md")
        let updated = Data("---\ntitle: Updated\n---\nUpdated body".utf8)

        // Start before all external I/O. Use the production graph's real
        // GFileMonitor, LibraryWatcher debounce and index, without reloads.
        let started = ProcessInfo.processInfo.systemUptime
        switch mode {
        case .inPlace:
            try updated.write(to: destination)
        case .atomicReplace:
            let temporary = root.appendingPathComponent(".external-save.tmp")
            try updated.write(to: temporary)
            let result = Glibc.rename(temporary.path, destination.path)
            let renameError = errno
            XCTAssertEqual(result, 0, "Atomic replacement failed with errno \(renameError)")
        }
        let arrived = GTKTestSupport.spin(timeout: .seconds(5)) {
            self.environment.pickerModel.results.map(\.relativePath) == ["external.md"]
                && self.environment.pickerModel.results.map(\.title) == ["Updated"]
                && self.environment.pickerModel.selectedPreview == .body("Updated body")
                && self.text(in: preview) == "Updated body"
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("External \(mode.rawValue) save -> GTK picker: \(elapsed) seconds")
        XCTAssertTrue(arrived, "Real GFileMonitor -> debounce -> index -> GTK picker did not refresh within five seconds")
        XCTAssertLessThan(elapsed, 1.0, "External \(mode.rawValue) save must reach results and preview within one second")
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
        XCTAssertNotEqual(GTKTestSupport.activate(button), 0)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.files.stamp(at: expectedPath)) != nil })
        let document = PromptCodec.parseFile(try files.read(at: expectedPath), filename: expectedPath)
        XCTAssertEqual(document.frontMatter.title, query)
        XCTAssertEqual(document.body, LinuxStrings.newPromptBody)
        XCTAssertTrue(document.canRender)
        XCTAssertNotNil(document.frontMatter.id)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == expectedPath
            && self.environment.editorModel.state.source == document.source }, "Editor did not load the created prompt '\(expectedPath)'")
        XCTAssertTrue(launchedURLs.isEmpty)
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
