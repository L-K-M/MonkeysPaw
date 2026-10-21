#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxForgetControlsTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var notifications: FakePortal!
    private var environment: LinuxEnvironment!
    private var paths: LinuxPaths!
    private var files: RootedFileStore!
    private var data: RootedFileStore!
    private var values: ValuesStore!
    private var scheduler: ForgetControlsScheduler!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        paths = LinuxPaths(environment: tools.environment)
        files = try RootedFileStore(root: paths.documentsDirectory.appendingPathComponent("MonkeysPaw"))
        data = try RootedFileStore(root: paths.dataDirectory)
        values = ValuesStore(files: data)
        scheduler = ForgetControlsScheduler()
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: scheduler, folderChooser: SettingsFolderChooser())
        try files.write(Data("---\ntitle: Alpha\nfields:\n  topic: {default: Alpha default}\n---\n{{topic}}".utf8), at: "a.md")
        try files.write(Data("---\ntitle: Beta\nfields:\n  topic: {default: Beta default}\n---\n{{topic}}".utf8), at: "b.md")
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        drainUI()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        values = nil
        data = nil
        files = nil
        tools = nil
    }

    func testPickerForgetClearsSelectedValuesAndDraftButKeepsOtherPrompt() throws {
        try openPicker()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Alpha remembered", "stale": "Old field"])
        try values.record(identity: beta, values: ["topic": "Beta remembered"])
        try draft("Beta draft", for: "Beta")
        try draft("Alpha draft", for: "Alpha")
        let button = try pickerWidget("picker-forget-values")
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), "Forget values")
        XCTAssertNotEqual(gtk_widget_get_visible(button), 0)
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("Keep clipboard")

        try click("picker-forget-values", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.values.rememberedValues(for: alpha)) == [:] })
        XCTAssertEqual(try values.rememberedValues(for: beta), ["topic": "Beta remembered"])
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertNil(environment.pickerModel.forgetValuesError)
        XCTAssertEqual(labelText(try pickerWidget("picker-status")), "")
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Alpha default")
        environment.pickerModel.escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta draft")
        try assertNoDeliveryOrLearning([alpha, beta])
    }

    func testFillForgetResetsNativeControlsInPlaceWithoutDelivery() throws {
        let source = """
        ---
        title: Alpha
        fields:
          topic: {default: Alpha default}
          detail: {type: multiline, default: Detail default, remember: false}
          language: {type: choice, options: [en, fr], default: en}
        ---
        {{topic}} / {{detail}} / {{language}}
        """
        try files.write(Data(source.utf8), at: "a.md")
        try openPicker()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Remembered", "language": "fr"])
        try values.record(identity: beta, values: ["topic": "Kept"])
        let fill = try openForm("Alpha", mode: .paste(.terminal))
        let topic = try pickerWidget("fill-field-topic")
        let detail = try pickerWidget("fill-field-detail")
        let language = try pickerWidget("fill-field-language")
        mp_entry_set_text(topic, "Draft")
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(detail)), "Edited detail", -1)
        gtk_combo_box_set_active_id(mp_combo_box(language), "fr")
        gtk_widget_grab_focus(detail)
        let focus = fill.focusIndex
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("Keep clipboard")

        try click("picker-forget-values", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { fill.values["topic"] == "Alpha default" })
        XCTAssertTrue(environment.pickerModel.fillModel === fill)
        XCTAssertEqual(environment.pickerModel.state, .fill)
        XCTAssertEqual(fill.preferredMode, .paste(.terminal))
        XCTAssertEqual(fill.focusIndex, focus)
        XCTAssertEqual(fill.values, ["topic": "Alpha default", "detail": "Detail default", "language": "en"])
        XCTAssertEqual(topic, try pickerWidget("fill-field-topic"))
        XCTAssertEqual(String(cString: mp_entry_text(topic)), "Alpha default")
        XCTAssertEqual(text(in: detail), "Detail default")
        XCTAssertEqual(gtk_combo_box_get_active_id(mp_combo_box(language)).map(String.init(cString:)), "en")
        XCTAssertEqual(text(in: try pickerWidget("picker-preview")), "Alpha default / Detail default / en")
        XCTAssertEqual(try values.rememberedValues(for: alpha), [:])
        XCTAssertEqual(try values.rememberedValues(for: beta), ["topic": "Kept"])
        try assertNoDeliveryOrLearning([alpha, beta])
    }

    func testCorruptValuesShowSanitizedFailureAndKeepFormAndDraft() throws {
        try openPicker()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try data.read(at: "values.json")
        let fill = try openForm("Alpha")
        mp_entry_set_text(try pickerWidget("fill-field-topic"), "Keep draft")
        let corrupt = Data("private invalid contents".utf8)
        try data.write(corrupt, at: "values.json")

        try click("picker-forget-values", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.forgetValuesError != nil })
        XCTAssertEqual(environment.pickerModel.forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(labelText(try pickerWidget("picker-status")),
            RememberedValuesStrings.message(for: .libraryFailure(.operationFailed)))
        XCTAssertNotEqual(gtk_widget_get_visible(try pickerWidget("picker-status")), 0)
        XCTAssertTrue(environment.pickerModel.fillModel === fill)
        XCTAssertEqual(fill.values["topic"], "Keep draft")
        XCTAssertEqual(try data.read(at: "values.json"), corrupt)
        environment.pickerModel.escape()
        try data.writePrivate(original, at: "values.json")
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Keep draft")
        XCTAssertEqual(try values.rememberedValues(for: alpha), ["topic": "Remembered"])
        try click("picker-forget-values", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.forgetValuesError == nil })
        XCTAssertEqual(labelText(try pickerWidget("picker-status")), "")
    }

    func testForgetHiddenWithoutSelectionAndRetiredButtonCannotClearNewLibrary() throws {
        try openPicker()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Kept"])
        let button = try pickerWidget("picker-forget-values")
        g_object_ref(button)
        defer { g_object_unref(button) }
        mp_entry_set_text(try pickerWidget("picker-query"), "No matching prompt")
        XCTAssertNil(environment.pickerModel.selectionIndex)
        XCTAssertEqual(gtk_widget_get_visible(button), 0)
        let second = tools.directory.appendingPathComponent("Second")
        try RootedFileStore(root: second).write(Data("{{topic}}".utf8), at: "a.md")

        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        emitClick(button)
        drainUI()
        XCTAssertEqual(try values.rememberedValues(for: alpha), ["topic": "Kept"])
    }

    func testSettingsCancelKeepsValuesAndConfirmClearsAllDraftsWithPanelClosed() throws {
        try openPicker()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Alpha remembered"])
        try values.record(identity: beta, values: ["topic": "Beta remembered"])
        try draft("Alpha draft", for: "Alpha")
        try draft("Beta draft", for: "Beta")
        let original = try data.read(at: "values.json")
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("Keep clipboard")
        let window = try showSettings()
        XCTAssertFalse(environment.panel.isVisible)
        let button = try settingsWidget("settings-forget-all", in: window)
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), "Forget all values…")
        let confirmation = try settingsWidget("settings-forget-confirmation", in: window)
        XCTAssertEqual(gtk_widget_get_visible(confirmation), 0)

        try requestForgetAll(in: window)
        XCTAssertEqual(gtk_widget_get_sensitive(button), 0)
        XCTAssertEqual(labelText(try settingsWidget("settings-forget-confirmation-message", in: window)),
            RememberedValuesStrings.confirmationMessage)
        let cancel = try settingsWidget("settings-cancel-forget-all", in: window)
        XCTAssertEqual(gtk_window_get_focus(mp_window(window)), cancel)
        XCTAssertEqual(gtk_widget_has_css_class(try settingsWidget("settings-confirm-forget-all", in: window),
            "destructive-action"), 1)
        try click("settings-cancel-forget-all", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(confirmation) == 0 })
        XCTAssertEqual(gtk_window_get_focus(mp_window(window)), button)
        XCTAssertEqual(try data.read(at: "values.json"), original)
        XCTAssertEqual(try openFormAfterSettings("Alpha").values["topic"], "Alpha draft")
        environment.pickerModel.escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta draft")
        environment.pickerModel.dismiss()
        _ = try showSettings()
        try requestForgetAll(in: window)
        try click("settings-confirm-forget-all", in: window)
        let message = try settingsWidget("settings-forget-message", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(message) == RememberedValuesStrings.message(for: .forgotten) })
        XCTAssertEqual(gtk_widget_get_visible(confirmation), 0)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(try data.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.dataDirectory.appendingPathComponent("values.json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try openFormAfterSettings("Alpha").values["topic"], "Alpha default")
        environment.pickerModel.escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta default")
        try assertNoDeliveryOrLearning([alpha, beta])
    }

    func testSettingsConfirmationUsesCurrentPickerAfterLibrarySwitch() throws {
        try openPicker()
        let old = environment.pickerModel
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try data.read(at: "values.json")
        let oldFill = try openForm("Alpha")
        mp_entry_set_text(try pickerWidget("fill-field-topic"), "Retired draft")
        try data.write(Data("invalid".utf8), at: "values.json")
        old.forgetSelectedValues()
        XCTAssertEqual(old.forgetValuesError as? LibraryError, .operationFailed)
        try data.writePrivate(original, at: "values.json")
        let window = try showSettings()
        try requestForgetAll(in: window)
        let second = tools.directory.appendingPathComponent("Second")
        try RootedFileStore(root: second).write(
            Data("---\ntitle: New\nfields:\n  topic: {default: New default}\n---\n{{topic}}".utf8), at: "a.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        let current = environment.pickerModel
        XCTAssertTrue(current !== old)
        XCTAssertEqual(try openFormAfterSettings("New").values["topic"], "Remembered")
        mp_entry_set_text(try pickerWidget("fill-field-topic"), "New draft")
        current.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })

        try click("settings-confirm-forget-all", in: window)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.values.rememberedValues(for: alpha)) == [:] })
        XCTAssertEqual(old.forgetValuesError as? LibraryError, .operationFailed, "Do not mutate the retired picker")
        XCTAssertEqual(oldFill.values["topic"], "Retired draft")
        XCTAssertEqual(try showSettings(), window)
        XCTAssertEqual(try openFormAfterSettings("New").values["topic"], "New default")
    }

    func testUnreadableValuesShowTypedFailuresAndRecover() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses file and directory permissions.") }
        try openPicker()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try data.read(at: "values.json")
        try draft("Keep draft", for: "Alpha")
        let url = paths.dataDirectory.appendingPathComponent("values.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.dataDirectory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try click("picker-forget-values", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.forgetValuesError != nil })
        XCTAssertEqual(environment.pickerModel.forgetValuesError as? FileStoreError, .ioFailure)
        XCTAssertEqual(labelText(try pickerWidget("picker-status")),
            RememberedValuesStrings.message(for: .fileStoreFailure(.ioFailure)))
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Keep draft")
        let window = try showSettings()
        // A global reset first tombstones repeat, without reading values.
        // Blocking that write must leave values/drafts intact and repeat off.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.dataDirectory.path)
        try requestForgetAll(in: window)
        try click("settings-confirm-forget-all", in: window)
        let message = try settingsWidget("settings-forget-message", in: window)
        let failure = RememberedValuesStrings.message(for: .libraryFailure(.operationFailed))
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(message) == failure })
        XCTAssertNotEqual(gtk_widget_get_visible(message), 0)
        XCTAssertEqual(environment.pickerModel.forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.repeatModel?.availability == .unavailable(.invalidationFailed) })
        XCTAssertEqual(try openFormAfterSettings("Alpha").values["topic"], "Keep draft")
        _ = try showSettings()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try data.read(at: "values.json"), original)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.dataDirectory.path)

        try requestForgetAll(in: window)
        try click("settings-confirm-forget-all", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(message) == RememberedValuesStrings.message(for: .forgotten) })
        XCTAssertEqual(try data.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        XCTAssertNil(environment.pickerModel.forgetValuesError)
        XCTAssertEqual(try openFormAfterSettings("Alpha").values["topic"], "Alpha default")
    }

    func testDeliveryDisablesPickerForgetAndSettingsReportsRefusal() throws {
        try openPicker()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try data.read(at: "values.json")
        let window = try showSettings()
        try requestForgetAll(in: window)
        let fill = try openFormAfterSettings("Alpha")
        let button = try pickerWidget("picker-forget-values")
        fill.deliver(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.pickerModel.state == .delivering && self.scheduler.delays.contains(Limits.settleDelayLinux)
        })
        defer {
            scheduler.fireAll()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
            XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
        }
        XCTAssertEqual(gtk_widget_is_sensitive(button), 0)
        environment.pickerModel.forgetSelectedValues()
        XCTAssertEqual(environment.pickerModel.forgetValuesError as? LibraryError, .operationFailed)
        let refusal = RememberedValuesStrings.message(for: .deliveryInFlight)
        XCTAssertEqual(labelText(try pickerWidget("picker-status")), refusal)
        try click("settings-confirm-forget-all", in: window)
        let message = try settingsWidget("settings-forget-message", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(message) == refusal })
        XCTAssertEqual(try data.read(at: "values.json"), original)
        XCTAssertEqual(fill.values["topic"], "Remembered")
    }

    func testClosingAndDestroyingSettingsCancelsConfirmationAndIgnoresDetachedConfirm() throws {
        try openPicker()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Kept"])
        let original = try data.read(at: "values.json")
        let window = try showSettings()
        try requestForgetAll(in: window)
        gtk_window_close(mp_window(window))
        XCTAssertEqual(try showSettings(), window)
        let confirmation = try settingsWidget("settings-forget-confirmation", in: window)
        XCTAssertEqual(gtk_widget_get_visible(confirmation), 0)
        try requestForgetAll(in: window)
        let confirm = try settingsWidget("settings-confirm-forget-all", in: window)
        g_object_ref(confirm)
        defer { g_object_unref(confirm) }
        gtk_window_destroy(mp_window(window))
        emitClick(confirm)
        drainUI()
        XCTAssertEqual(try data.read(at: "values.json"), original)
    }

    private func openPicker() throws {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
    }

    private func openForm(_ query: String, mode: DeliveryMode = .copyOnly) throws -> FillModel {
        mp_entry_set_text(try pickerWidget("picker-query"), query)
        environment.pickerModel.use(mode: mode)
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.builtinsResolved })
        return fill
    }

    private func openFormAfterSettings(_ query: String) throws -> FillModel {
        try openPicker()
        return try openForm(query)
    }

    private func draft(_ value: String, for query: String) throws {
        _ = try openForm(query)
        mp_entry_set_text(try pickerWidget("fill-field-topic"), value)
        environment.pickerModel.escape()
        XCTAssertEqual(environment.pickerModel.state, .picker)
    }

    private func identity(_ path: String) throws -> PromptIdentity {
        try XCTUnwrap(environment.pickerModel.results.first { $0.relativePath == path }?.identity)
    }

    private func showSettings() throws -> GTK.Widget {
        environment.showSettings()
        var window: GTK.Widget?
        XCTAssertTrue(GTKTestSupport.spin {
            var node = gtk_application_get_windows(self.application)
            while let current = node {
                if let raw = current.pointee.data {
                    let candidate = mp_window_widget(raw.assumingMemoryBound(to: GtkWindow.self))
                    if gtk_window_get_title(mp_window(candidate)).map(String.init(cString:)) == LinuxStrings.settings,
                       gtk_widget_get_visible(candidate) != 0 {
                        window = candidate
                        return true
                    }
                }
                node = current.pointee.next
            }
            return false
        })
        return try XCTUnwrap(window)
    }

    private func requestForgetAll(in window: GTK.Widget) throws {
        try click("settings-forget-all", in: window)
        let confirmation = try settingsWidget("settings-forget-confirmation", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(confirmation) != 0 })
    }

    private func pickerWidget(_ name: String) throws -> GTK.Widget {
        try settingsWidget(name, in: environment.panel.clipboardOwner)
    }

    private func click(_ name: String, in window: GTK.Widget) throws {
        XCTAssertNotEqual(GTKTestSupport.activate(try settingsWidget(name, in: window)), 0)
    }

    /// Detached buttons cannot finish GTK's activation animation. Emit the
    /// signal synchronously so the stale native callback is actually exercised.
    private func emitClick(_ button: GTK.Widget) {
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, button)
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
    }

    private func labelText(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }

    private func text(in view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(text) }
        return String(cString: text)
    }

    private func assertNoDeliveryOrLearning(_ identities: [PromptIdentity]) throws {
        let clipboard = ForgetClipboardRead()
        GTKClipboard(owner: environment.panel.clipboardOwner).readText { clipboard.store($0) }
        XCTAssertTrue(GTKTestSupport.spin { clipboard.value != nil })
        XCTAssertEqual(clipboard.value, "Keep clipboard")
        let usage = UsageStore(files: data, clock: SystemClock())
        for identity in identities { XCTAssertTrue(try usage.useEvents(for: identity).isEmpty) }
        XCTAssertEqual(notifications.notificationCount, 0)
    }

    private func drainUI() {
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

private final class ForgetControlsScheduler: Scheduler {
    private(set) var delays: [Duration] = []
    private var callbacks: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        callbacks.append(work)
    }
    func fireAll() {
        let pending = callbacks
        callbacks = []
        for work in pending { work() }
    }
}

private final class ForgetClipboardRead: @unchecked Sendable {
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
