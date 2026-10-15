#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxSyncStatusViewTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var notifications: FakePortal!
    private var files: RootedFileStore!
    private var transport: StatusViewTransport!
    private var source: StatusViewSource!
    private var model: SyncStatusModel!
    private var library: LinuxLibraryWindow?
    private var navigation: [SyncStatusAction] = []

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "x11"
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = address
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        transport = StatusViewTransport()
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory
            .appendingPathComponent("MonkeysPaw", isDirectory: true))
        try files.createRoot()
    }

    override func tearDown() {
        transport?.releasePull()
        library?.tearDown()
        if let environment {
            environment.shutdown()
            let done = StatusViewFlag()
            Task.detached { await environment.drainSync(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin { done.value })
        }
        model?.retire()
        if let application { GTKTestSupport.destroy(application) }
        library = nil
        environment = nil
        application = nil
        drain()
        notifications = nil
        files = nil
        model = nil
        source = nil
        transport = nil
        tools = nil
    }

    func testPickerStatusMatrixPreservesTerminalAndSessionHints() throws {
        try bindStatus()
        environment.panel.show()
        try assertMatrix(in: environment.panel.clipboardOwner, prefix: "picker-sync")
        XCTAssertTrue(try label("picker-hint", in: environment.panel.clipboardOwner).contains("terminal paste"))
        XCTAssertTrue(labels(environment.panel.clipboardOwner).contains(LinuxStrings.pickerSession(.otherX11)))
    }

    func testLibraryStatusMatrixIncludesLastSuccessAndCounts() throws {
        try bindStatus()
        library?.show()
        try assertMatrix(in: XCTUnwrap(nativeWindow(LinuxStrings.library)), prefix: "library-sync")
    }

    func testExplicitSyncNowAndAccountIntentsRespectCurrentEligibility() throws {
        try bindStatus()
        environment.panel.show()
        let window = environment.panel.clipboardOwner
        var report = enabledReport()
        source.send(report)
        drain()
        try click("picker-sync-action", in: window)
        XCTAssertEqual(source.syncRequests, 1)
        XCTAssertTrue(navigation.isEmpty)
        report.phase = .resyncing
        source.send(report)
        drain()
        emitClick(try settingsWidget("picker-sync-action", in: window))
        XCTAssertEqual(source.syncRequests, 1)
        report.phase = .idle
        report.needsSignIn = true
        report.enabled = false
        source.send(report)
        drain()
        try click("picker-sync-action", in: window)
        XCTAssertEqual(navigation, [.account])
        XCTAssertEqual(source.syncRequests, 1)
    }

    func testErrorsShowSafeSortedReasonsAndOpenTheirFileInTheEditor() throws {
        try files.write(Data("Repair this prompt\n".utf8), at: "a.md")
        try bindStatus()
        library?.show()
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        let sentinel = UUID().uuidString
        var report = enabledReport()
        report.counts.conflicts = 2
        report.counts.fileErrors = 3
        report.details = [.init(path: "z.md", code: sentinel),
                          .init(path: "a.md", code: PromptIssueCode.invalidYAML.rawValue),
                          .init(path: "b.md", code: "forbidden")]
        source.send(report)
        drain()
        XCTAssertFalse(model.state.showsErrorDetails)
        try click("library-sync-action", in: window)
        XCTAssertTrue(model.state.showsErrorDetails)
        let details = try settingsWidget("library-sync-file-errors", in: window)
        let text = labels(details).joined(separator: "\n")
        XCTAssertFalse(text.contains(sentinel))
        for error in model.state.fileErrors { XCTAssertTrue(text.contains(error.reason)) }
        let paths = descendants(details).filter { mp_is_button($0) != 0 }
            .compactMap { gtk_button_get_label(mp_button($0)).map { String(cString: $0) } }
        XCTAssertEqual(Array(paths.dropFirst()), ["a.md", "b.md", "z.md"])
        let fileButton = try XCTUnwrap(descendants(details).first {
            mp_is_button($0) != 0 && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == "a.md"
        })
        emitClick(fileButton)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == "a.md"
            && self.environment.editorModel.state.status == .idle })
        try click("library-sync-hide-errors", in: window)
        XCTAssertFalse(model.state.showsErrorDetails)
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("library-sync-conflicts", in: window)), 0)
        try click("library-sync-now", in: window)
        XCTAssertEqual(source.syncRequests, 1)
    }

    func testBlockingErrorHasFixedMessageWithoutOfferingAnIneligibleRetry() throws {
        try bindStatus()
        library?.show()
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        var report = enabledReport()
        report.blockingIssue = .invalidProtocol
        source.send(report)
        drain()
        XCTAssertEqual(try label("library-sync-message", in: window), model.state.errorMessage)
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("library-sync-now", in: window)), 0)
        try click("library-sync-action", in: window)
        XCTAssertTrue(labels(try settingsWidget("library-sync-file-errors", in: window)).contains(LinuxSyncStatusStrings.noFileErrors))
        XCTAssertEqual(source.syncRequests, 0)
    }

    func testLongFileErrorPathDoesNotForceLibraryBeyondTheScreen() throws {
        try bindStatus()
        library?.show()
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        let path = (Array(repeating: String(repeating: "p", count: 100), count: 9) + ["prompt.md"]).joined(separator: "/")
        var report = enabledReport()
        report.counts.fileErrors = 1
        report.details = [.init(path: RelativePath(path), code: "forbidden")]
        source.send(report)
        model.showErrorDetails()
        drain()
        let details = try settingsWidget("library-sync-file-errors", in: window)
        let button = try XCTUnwrap(descendants(details).first {
            mp_is_button($0) != 0 && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == path
        })
        var minimum: Int32 = 0
        gtk_widget_measure(button, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        XCTAssertLessThan(minimum, Int32(Limits.panelSize.width))
    }

    func testDisabledPickerOpensAccountInReusableSettingsWindow() throws {
        compose()
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(nativeWindow(LinuxStrings.settings))
        gtk_widget_set_visible(settings, 0)
        try openPicker()
        try click("picker-sync-action", in: environment.panel.clipboardOwner)
        try assertAccountSelected(in: settings)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(nativeWindow(LinuxStrings.settings), settings)
    }

    func testSignInRequiredRoutesLibraryActionToAccountWithoutRetrying() throws {
        compose()
        transport.mode = .unauthorized
        try signIn()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncStatusModel?.state.footer == .needsSignIn })
        let requests = transport.pullRequests
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil })
        try click("library-sync-action", in: XCTUnwrap(nativeWindow(LinuxStrings.library)))
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.settings) != nil })
        try assertAccountSelected(in: XCTUnwrap(nativeWindow(LinuxStrings.settings)))
        XCTAssertEqual(transport.pullRequests, requests)
    }

    func testPickerConflictActionOpensOriginBasedConflictFilter() throws {
        compose()
        transport.mode = .conflicts
        try signIn()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncStatusModel?.state.footer == .hasConflicts })
        XCTAssertEqual(environment.syncStatusModel?.state.footer, .hasConflicts)
        XCTAssertNil(environment.syncStatusModel?.state.blockingIssue)
        try openPicker()
        XCTAssertTrue(try label("picker-sync-summary", in: environment.panel.clipboardOwner).contains("Conflicts: 1"))
        try click("picker-sync-action", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selectedSection == .conflicts })
        XCTAssertEqual(environment.libraryBrowserModel.rows.map(\.relativePath.string), [StatusViewTransport.copyPath])
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testPickerErrorActionOpensLibraryReasonList() throws {
        try files.write(Data("---\nfields: broken\n---\n{{topic}}\n".utf8), at: "broken.md")
        compose()
        try signIn()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncStatusModel?.state.footer == .syncError })
        try openPicker()
        try click("picker-sync-action", in: environment.panel.clipboardOwner)
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil
            && self.environment.syncStatusModel?.state.showsErrorDetails == true })
        drain()
        let details = try settingsWidget("library-sync-file-errors", in: XCTUnwrap(nativeWindow(LinuxStrings.library)))
        let text = labels(details).joined(separator: "\n")
        XCTAssertTrue(descendants(details).contains { mp_is_button($0) != 0
            && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == "broken.md" })
        let errors = try XCTUnwrap(environment.syncStatusModel?.state.fileErrors)
        XCTAssertFalse(errors.isEmpty)
        for error in errors { XCTAssertTrue(text.contains(error.reason)) }
    }

    func testLocalPickerFillAndTerminalDeliveryContinueDuringNetworkOutage() throws {
        try tools.install("xdotool", script: FakeLinuxTools.recordArguments + #"""

            case "$1" in
                getactivewindow) printf '12345\n' ;;
                key) exit 0 ;;
                *) exit 1 ;;
            esac
            """#)
        try tools.install("xprop", script: #"printf 'WM_CLASS(STRING) = "instance", "kitty"\n'"#)
        try files.write(Data(("---\nid: " + StatusViewTransport.original + "\n---\nHello {{topic}}").utf8), at: "a.md")
        compose()
        transport.mode = .offline
        try signIn()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncStatusModel?.state.footer == .offline })
        let success = environment.syncStatusModel?.state.lastSuccess
        try openPicker()
        let window = environment.panel.clipboardOwner
        let query = try settingsWidget("picker-query", in: window)
        mp_entry_set_text(query, "a")
        XCTAssertEqual(environment.pickerModel.results.count, 1)
        XCTAssertTrue(try label("picker-hint", in: window).contains("X11 terminal"))
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Return),
            GdkModifierType(rawValue: GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue)), 0)
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertEqual(fill.preferredMode, .paste(.terminal))
        mp_entry_set_text(try settingsWidget("fill-field-topic", in: window), "offline work")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(try label("picker-hint", in: window).contains("terminal paste"))
        try click("picker-use", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.pasted(.xdotool)) })
        XCTAssertEqual(tools.arguments.last, ["key", "--clearmodifiers", "ctrl+shift+v"])
        let clipboard = StatusViewClipboard()
        GTKClipboard(owner: window).readText { clipboard.set($0) }
        XCTAssertTrue(GTKTestSupport.spin { clipboard.value == "Hello offline work" })
        XCTAssertEqual(environment.syncStatusModel?.state.footer, .offline)
        XCTAssertEqual(environment.syncStatusModel?.state.lastSuccess, success)
    }

    func testHiddenViewsIgnoreQueuedReportsAndReadLatestOnReopen() throws {
        try bindStatus()
        environment.panel.show()
        let panel = environment.panel.clipboardOwner
        let old = try label("picker-sync-summary", in: panel)
        environment.panel.hide()
        var report = enabledReport()
        report.offline = true
        source.send(report)
        drain()
        XCTAssertEqual(try label("picker-sync-summary", in: panel), old)
        environment.panel.show()
        XCTAssertEqual(try label("picker-sync-summary", in: panel), SyncFooter.offline.text)
        environment.panel.hide()
        library?.show()
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        library?.hide()
        XCTAssertTrue(GTKTestSupport.spin { self.library?.isVisible == false })
        report.offline = false
        source.send(report)
        drain()
        XCTAssertEqual(try label("library-sync-summary", in: window), SyncFooter.offline.text)
        library?.show()
        XCTAssertEqual(try label("library-sync-summary", in: window), SyncFooter.idle.text)
    }

    func testRebindAndNativeDestructionFenceLateCallbacksAndKeepOtherObservers() throws {
        try bindStatus()
        environment.panel.show()
        var independent = 0
        let token = model.addObserver { _ in independent += 1 }
        defer { model.removeObserver(token) }
        let oldModel = try XCTUnwrap(model)
        var report = enabledReport()
        report.offline = true
        source.send(report) // Queued before replacement, delivered afterward.
        let replacementSource = StatusViewSource()
        let replacement = SyncStatusModel(sync: replacementSource, mainThread: GLibMainThread())
        defer { replacement.retire() }
        rebindPanel(to: replacement)
        library?.rebind(browser: environment.libraryBrowserModel, editor: environment.editorModel, syncStatus: replacement)
        drain()
        XCTAssertEqual(try label("picker-sync-summary", in: environment.panel.clipboardOwner), SyncFooter.disabled.text)
        XCTAssertEqual(independent, 1)
        library?.show()
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        let summary = try settingsWidget("library-sync-summary", in: window)
        g_object_ref(summary)
        defer { g_object_unref(summary) }
        var writes = 0
        GTK.onNotify(UnsafeMutableRawPointer(summary), "label") { writes += 1 }
        gtk_window_destroy(mp_window(window))
        gtk_window_destroy(mp_window(environment.panel.clipboardOwner))
        replacementSource.send(report)
        oldModel.refresh()
        drain()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(independent, 1)
    }

    func testWorkerReportsWriteGTKOnlyOnMainLoopAndNeverStealFocus() throws {
        try bindStatus()
        environment.panel.show()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        let window = environment.panel.clipboardOwner
        let focus = gtk_window_get_focus(mp_window(window))
        var writes = 0
        let summary = try settingsWidget("picker-sync-summary", in: window)
        GTK.onNotify(UnsafeMutableRawPointer(summary), "label") { XCTAssertTrue(Thread.isMainThread); writes += 1 }
        let done = StatusViewFlag()
        let source = try XCTUnwrap(source)
        Task.detached {
            var report = SyncReport()
            report.enabled = true
            report.offline = true
            source.send(report)
            done.set()
        }
        let deadline = Date().addingTimeInterval(3)
        while !done.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(done.value)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(GTKTestSupport.spin { writes > 0 })
        XCTAssertEqual(gtk_window_get_focus(mp_window(window)), focus)
        XCTAssertTrue(environment.panel.isActiveAndVisible)
        XCTAssertNil(nativeWindow(LinuxStrings.settings))
        XCTAssertFalse(library?.isVisible == true)
    }

    func testHeldHTTPKeepsGLibResponsiveAndDoesNotOpenAnyWindow() throws {
        compose()
        transport.mode = .held
        try signIn()
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeldPull })
        try openPicker()
        let focus = gtk_window_get_focus(mp_window(environment.panel.clipboardOwner))
        var heartbeat = false
        GTK.after(0.01) { heartbeat = true; XCTAssertTrue(Thread.isMainThread) }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat })
        XCTAssertTrue(transport.hasHeldPull)
        transport.mode = .offline
        transport.releasePull()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncStatusModel?.state.footer == .offline })
        drain()
        XCTAssertEqual(gtk_window_get_focus(mp_window(environment.panel.clipboardOwner)), focus)
        XCTAssertTrue(environment.panel.isActiveAndVisible)
        XCTAssertNil(nativeWindow(LinuxStrings.library))
        XCTAssertNil(nativeWindow(LinuxStrings.settings))
        XCTAssertFalse(transport.sentOnMain)
    }

    func testEnvironmentRebindsStatusWithoutStartingLocalAccountWork() throws {
        compose()
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil })
        let old = try XCTUnwrap(environment.syncStatusModel)
        let replacement = tools.directory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        XCTAssertFalse(environment.syncStatusModel === old)
        old.showErrorDetails()
        drain()
        XCTAssertFalse(environment.syncStatusModel?.state.showsErrorDetails == true)
        let window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        XCTAssertEqual(try label("library-sync-summary", in: window), SyncFooter.disabled.text)
        var quit = false
        environment.requestQuit { quit = true }
        XCTAssertTrue(quit, "Rendering status must not start Account's metadata-loading work")
        XCTAssertEqual(transport.pullRequests, 0)
    }

    private func compose() {
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: StatusViewTimer(), syncTransport: transport)
        _ = environment.libraryStatusModel
    }

    private func bindStatus() throws {
        compose()
        source = StatusViewSource()
        model = SyncStatusModel(sync: source, mainThread: GLibMainThread())
        rebindPanel(to: model)
        library = LinuxLibraryWindow(application: application, browser: environment.libraryBrowserModel,
            editor: environment.editorModel, syncStatus: model,
            syncNavigation: { [weak self] in self?.navigation.append($0) }, openFolder: {})
    }

    private func rebindPanel(to model: SyncStatusModel) {
        environment.panel.rebind(picker: environment.pickerModel, session: .otherX11, openSetup: {}, openSettings: {},
            syncStatus: model, syncNavigation: { [weak self] in self?.navigation.append($0) },
            requestedIntent: { _ in }, createPrompt: { _ in })
    }

    private func assertMatrix(in window: GTK.Widget, prefix: String) throws {
        let cases: [(SyncFooter, (inout SyncReport) -> Void)] = [
            (.disabled, { $0.enabled = false }), (.idle, { _ in }),
            (.syncing, { $0.phase = .collecting }), (.resyncing, { $0.phase = .resyncing }),
            (.offline, { $0.offline = true }), (.needsSignIn, { $0.needsSignIn = true; $0.enabled = false }),
            (.hasConflicts, { $0.counts.conflicts = 3 }), (.syncError, { $0.counts.fileErrors = 2 })]
        for (footer, edit) in cases {
            var report = enabledReport()
            report.lastSuccess = Date(timeIntervalSince1970: 42)
            edit(&report)
            source.send(report)
            XCTAssertTrue(GTKTestSupport.spin { self.model.state.footer == footer })
            drain()
            XCTAssertEqual(try label(prefix + "-summary", in: window), LinuxSyncStatusStrings.summary(model.state))
            XCTAssertEqual(try label(prefix + "-last-success", in: window), LinuxSyncStatusStrings.lastSuccess(report.lastSuccess))
            let action = try settingsWidget(prefix + "-action", in: window)
            XCTAssertEqual(gtk_widget_get_visible(action) != 0, model.state.action != .none)
            XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(action))), LinuxSyncStatusStrings.action(model.state.action))
        }
        source.send(enabledReport())
        drain()
        XCTAssertEqual(try label(prefix + "-last-success", in: window), LinuxSyncStatusStrings.lastSuccess(nil))
    }

    private func signIn() throws {
        let account = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !account.state.isBusy })
        var password = "test-password"
        account.login(server: "https://sync.example.test", username: "person", password: &password, deviceName: "Linux")
        XCTAssertTrue(GTKTestSupport.spin { account.state.enabled })
    }

    private func openPicker() throws {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
    }

    private func assertAccountSelected(in window: GTK.Widget) throws {
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) != 0 })
        let notebook = try settingsWidget("settings-tabs", in: window)
        let account = try settingsWidget("settings-account-page", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_mapped(account) != 0 })
        XCTAssertEqual(gtk_notebook_get_current_page(mp_notebook(notebook)), gtk_notebook_page_num(mp_notebook(notebook), account))
    }

    private func enabledReport() -> SyncReport { var value = SyncReport(); value.enabled = true; return value }
    private func label(_ name: String, in window: GTK.Widget) throws -> String {
        String(cString: gtk_label_get_text(mp_label(try settingsWidget(name, in: window))))
    }
    private func click(_ name: String, in window: GTK.Widget) throws {
        let button = try settingsWidget(name, in: window)
        XCTAssertNotEqual(gtk_widget_get_visible(button), 0)
        XCTAssertNotEqual(gtk_widget_get_sensitive(button), 0)
        emitClick(button)
        drain()
    }
    private func emitClick(_ button: GTK.Widget) {
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, button)
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
    }
    private func nativeWindow(_ title: String) -> GTK.Widget? {
        let windows = gtk_window_get_toplevels()
        for index in 0..<g_list_model_get_n_items(windows) {
            guard let object = g_list_model_get_item(windows, index) else { continue }
            let widget = object.assumingMemoryBound(to: GtkWidget.self)
            g_object_unref(object)
            if gtk_window_get_title(mp_window(widget)).map({ String(cString: $0) }) == title { return widget }
        }
        return nil
    }
    private func descendants(_ widget: GTK.Widget) -> [GTK.Widget] {
        var result = [widget]
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += descendants(current); child = gtk_widget_get_next_sibling(current) }
        return result
    }
    private func labels(_ widget: GTK.Widget) -> [String] {
        descendants(widget).filter { g_type_check_instance_is_a(UnsafeMutableRawPointer($0)
            .assumingMemoryBound(to: GTypeInstance.self), gtk_label_get_type()) != 0 }
            .map { String(cString: gtk_label_get_text(mp_label($0))) }
    }
    private func drain() { for _ in 0..<100 { _ = g_main_context_iteration(nil, 0) } }
}

private final class StatusViewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private final class StatusViewClipboard {
    private(set) var value: String?
    func set(_ value: String?) { self.value = value }
}

private final class StatusViewTimer: Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if delay < Limits.syncDebounce { GTK.after(delay.timeInterval, work) }
    }
}

private final class StatusViewSource: SyncStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = SyncReport()
    private var observers: [UUID: (SyncReport) -> Void] = [:]
    private var requests = 0
    var report: SyncReport { locked { stored } }
    var syncRequests: Int { locked { requests } }
    func observe(_ observer: @escaping (SyncReport) -> Void) -> UUID {
        locked { let id = UUID(); observers[id] = observer; return id }
    }
    func removeObserver(_ id: UUID) { locked { observers[id] = nil } }
    func syncNow() { locked { requests += 1 } }
    func send(_ report: SyncReport) {
        let callbacks = locked { stored = report; return Array(observers.values) }
        for callback in callbacks { callback(report) }
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}

private final class StatusViewTransport: HTTPTransporting, @unchecked Sendable {
    enum Mode { case normal, offline, unauthorized, conflicts, held }
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let original = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    static let copyPath = "Elsewhere/copy.md"
    private let lock = NSLock()
    private var storedMode: Mode = .normal
    private var held: CheckedContinuation<HTTPResponse, Error>?
    private var pulls = 0
    private var mainRequest = false
    var mode: Mode { get { locked { storedMode } } set { locked { storedMode = newValue } } }
    var hasHeldPull: Bool { locked { held != nil } }
    var pullRequests: Int { locked { pulls } }
    var sentOnMain: Bool { locked { mainRequest } }
    private let timestamp = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User { .init(id: Self.user, username: "person", displayName: nil,
        accountKind: .member, createdAt: timestamp, disabledAt: nil) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { mainRequest = mainRequest || Thread.isMainThread }
        if request.url.path.hasSuffix("/login") {
            return try response(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
        }
        if request.url.path.hasSuffix("/me") {
            return try response(SyncAPI.MeResponse(user: user, groups: [], devices: [.init(id: Self.device,
                name: "Linux", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
        }
        if request.url.path.hasSuffix("/sync/pull") {
            locked { pulls += 1 }
            if mode == .held {
                return try await withCheckedThrowingContinuation { continuation in locked { held = continuation } }
            }
            return try pullResponse()
        }
        if request.method == .get, request.url.lastPathComponent == Self.original {
            return try response(SyncAPI.Prompt(id: Self.original, rev: 1, scope: .user,
                path: "original.md", content: "---\nid: " + Self.original + "\n---\nOriginal\n"))
        }
        if request.method == .put { return try response(SyncAPI.WriteResponse(rev: 1, seq: 1)) }
        throw HTTPTransportError.invalidRequest
    }

    func releasePull() {
        let pending = locked { let value = held; held = nil; return value }
        guard let pending else { return }
        do { pending.resume(returning: try pullResponse()) }
        catch { pending.resume(throwing: HTTPTransportError.networkFailure) }
    }

    private func pullResponse() throws -> HTTPResponse {
        switch mode {
        case .offline: throw HTTPTransportError.networkFailure
        case .unauthorized:
            return HTTPResponse(statusCode: 401, body: try JSONEncoder().encode(SyncAPI.ErrorResponse.failure(.unauthorized)))
        case .normal, .held, .conflicts:
            let items: [SyncAPI.FeedItem] = mode == .conflicts ? [
                .upsert(seq: 1, prompt: .init(id: Self.original, rev: 1, path: "original.md",
                    content: "---\nid: " + Self.original + "\n---\nOriginal\n")),
                .upsert(seq: 1, prompt: .init(id: Self.copyID, rev: 1, path: Self.copyPath,
                    content: "---\nid: " + Self.copyID + "\nx-monkeyspaw-conflict-of: " + Self.original + "\n---\nCopy\n"))] : []
            return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
                .init(identity: .user(userID: Self.user), mode: .snapshot, head: items.isEmpty ? 0 : 1, cursor: "status-cursor",
                      hasMore: false, items: items)], removed: []))
        }
    }
    private func response<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}
#endif
