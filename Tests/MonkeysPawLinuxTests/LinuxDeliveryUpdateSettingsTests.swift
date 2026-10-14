#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxDeliveryUpdateSettingsTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var portal: FakePortal!
    private var environment: LinuxEnvironment!
    private var paths: LinuxPaths!
    private var transport: SettingsUpdateTransport!
    private var scheduler: SettingsDelayScheduler!
    private var clipboard: SettingsRestoreClipboard!
    private var focus: SettingsDeliveryFocus!
    private var opened: [URL] = []
    private var openingOutcome = ReleasePageOpenOutcome.opened

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        try portal.ownName()
        try portal.ownNotifications()
        tools = try PortalSessionTestSupport.tools()
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "GNOME"
        transport = SettingsUpdateTransport()
        scheduler = SettingsDelayScheduler()
        clipboard = SettingsRestoreClipboard()
        focus = SettingsDeliveryFocus()
        compose()
    }

    override func tearDown() {
        transport?.release()
        environment?.shutdown()
        environment = nil
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        drain()
        portal?.shutdown()
        portal = nil
        tools = nil
        transport = nil
        scheduler = nil
        clipboard = nil
        focus = nil
    }

    func testDefaultAutomaticAndExplicitChordLabelsAndSessionLimits() throws {
        for (desktop, type, sandbox, session) in [
            ("GNOME", "x11", false, DesktopSession.gnomeX11),
            ("GNOME", "wayland", false, .gnomeWayland),
            ("GNOME", "wayland", true, .flatpak(host: .gnomeWayland)),
        ] {
            tools.environment["XDG_CURRENT_DESKTOP"] = desktop
            tools.environment["XDG_SESSION_TYPE"] = type
            tools.environment["FLATPAK_ID"] = sandbox ? AppIdentity.linuxAppID : nil
            compose()
            environment.settingsModel.setLinuxDefaultPasteChord(.standard)
            let window = try showSettings()
            let chord = try control("settings-default-chord", in: window)
            XCTAssertEqual(gtk_combo_box_get_active(mp_combo_box(chord)), 0)
            let title = try XCTUnwrap(gtk_combo_box_text_get_active_text(mp_combo_box_text(chord)))
            XCTAssertEqual(String(cString: title), DeliverySettingsStrings.standardChord)
            g_free(title)
            XCTAssertEqual(text(try control("settings-chord-explanation", in: window)), DeliverySettingsStrings.chordExplanation(for: session))
            XCTAssertEqual(text(try control("settings-explicit-chords", in: window)), LinuxSettingsDeliveryStrings.explicitChoices)
            let target = DeliveryTarget.linux(session: session, x11WindowClass: "konsole")
            XCTAssertEqual(TerminalPolicy.recommendedChord(for: target, session: session), type == "x11" && !sandbox ? .terminal : .standard)
            gtk_combo_box_set_active(mp_combo_box(chord), 1)
            XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.deliveryPreferences.linuxDefaultPasteChord == .terminal })
            XCTAssertEqual(TerminalPolicy.recommendedChord(for: nil, session: session,
                defaultChord: environment.settingsModel.deliveryPreferences.linuxDefaultPasteChord), .terminal)
        }
        XCTAssertEqual(transport.count, 0)
    }

    func testDeliveryAndUpdatePreferencesPersistTogetherAcrossReconstruction() throws {
        let window = try showSettings()
        gtk_combo_box_set_active(mp_combo_box(try control("settings-default-chord", in: window)), 1)
        gtk_check_button_set_active(mp_check_button(try control("settings-restore-clipboard", in: window)), 1)
        gtk_check_button_set_active(mp_check_button(try control("settings-automatic-updates", in: window)), 0)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.settingsModel.deliveryPreferences == DeliveryPreferences(linuxDefaultPasteChord: .terminal, clipboardRestore: .previousText)
                && self.environment.settingsModel.automaticUpdateChecks == .disabled
        })
        environment.settingsModel.markSetupPresented()
        compose()
        let reopened = try showSettings()
        XCTAssertEqual(gtk_combo_box_get_active(mp_combo_box(try control("settings-default-chord", in: reopened))), 1)
        XCTAssertNotEqual(gtk_check_button_get_active(mp_check_button(try control("settings-restore-clipboard", in: reopened))), 0)
        XCTAssertEqual(gtk_check_button_get_active(mp_check_button(try control("settings-automatic-updates", in: reopened))), 0)
        XCTAssertTrue(environment.settingsModel.firstRun.setupPresented)
        XCTAssertEqual(transport.count, 0)
    }

    func testPreferenceWriteFailuresShowErrorsAndRestoreCommittedControls() throws {
        let window = try showSettings()
        let config = try RootedFileStore(root: paths.configDirectory)
        environment.settingsModel.markSetupPresented()
        try config.delete(at: "settings.json")
        try FileManager.default.createDirectory(at: paths.configDirectory.appendingPathComponent("settings.json"), withIntermediateDirectories: false)
        gtk_combo_box_set_active(mp_combo_box(try control("settings-default-chord", in: window)), 1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.deliverySettingsModel.state.settingsError != nil })
        let deliveryError = try control("settings-delivery-error", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(deliveryError) != 0 })
        XCTAssertEqual(gtk_combo_box_get_active(mp_combo_box(try control("settings-default-chord", in: window))), 0)
        gtk_check_button_set_active(mp_check_button(try control("settings-automatic-updates", in: window)), 0)
        let updateError = try control("settings-update-error", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(updateError) != 0 })
        XCTAssertEqual(environment.settingsModel.automaticUpdateChecks, .enabled)
        XCTAssertNotEqual(gtk_check_button_get_active(mp_check_button(try control("settings-automatic-updates", in: window))), 0)
        XCTAssertEqual(transport.count, 0)
    }

    func testReadOnlySettingsDisablePreferenceControlsAndKeepBytes() throws {
        let config = try RootedFileStore(root: paths.configDirectory)
        let bytes = Data("{\"version\":999}".utf8)
        try config.write(bytes, at: "settings.json")
        compose()
        let window = try showSettings()
        for name in ["settings-default-chord", "settings-restore-clipboard", "settings-automatic-updates"] {
            XCTAssertEqual(gtk_widget_get_sensitive(try control(name, in: window)), 0)
        }
        for name in ["settings-delivery-error", "settings-update-error"] {
            let label = try control(name, in: window)
            XCTAssertNotEqual(gtk_widget_get_visible(label), 0)
            XCTAssertEqual(text(label), GeneralSettingsStrings.settingsError(.futureVersion(999)))
        }
        environment.updateService.startAutomaticChecks() // Explicitly exercise the fail-closed runtime policy with fake HTTP.
        drainUpdate()
        XCTAssertEqual(transport.count, 0)
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
    }

    func testSetupAndTestPasteActionsForwardOnceAndHiddenButtonsDoNothing() throws {
        let window = try showSettings()
        let setup = try control("settings-delivery-open-setup", in: window)
        var setupCalls = 0
        environment.deliverySettingsModel.onOpenSetup = { setupCalls += 1 }
        emitClick(setup)
        XCTAssertTrue(GTKTestSupport.spin { setupCalls == 1 })
        let test = try control("settings-test-paste", in: window)
        emitClick(test)
        emitClick(test)
        XCTAssertTrue(GTKTestSupport.spin {
            if case .tested = self.environment.deliverySettingsModel.state.test { return true }
            return false
        })
        XCTAssertEqual(clipboard.writes, PasteLadder.backends(for: .gnomeWayland).count)
        XCTAssertEqual(clipboard.snapshots, 0)
        XCTAssertFalse(text(try control("settings-delivery-report", in: window)).isEmpty)
        gtk_window_close(mp_window(window))
        emitClick(setup)
        emitClick(test)
        drain()
        XCTAssertEqual(setupCalls, 1)
        XCTAssertEqual(clipboard.writes, PasteLadder.backends(for: .gnomeWayland).count)
        XCTAssertNil(environment.deliverySettingsModel.onChange)
        XCTAssertEqual(try showSettings(), window)
        emitClick(setup)
        XCTAssertTrue(GTKTestSupport.spin { setupCalls == 2 })
    }

    func testDeliverySetupOpensTheReusableSetupWindow() throws {
        let window = try showSettings()
        for _ in 0..<2 {
            emitClick(try control("settings-delivery-open-setup", in: window))
            XCTAssertTrue(GTKTestSupport.spin { self.windows(LinuxStrings.setup).contains { gtk_widget_get_visible($0) != 0 } })
            XCTAssertEqual(windows(LinuxStrings.setup).count, 1)
            gtk_window_close(mp_window(try XCTUnwrap(windows(LinuxStrings.setup).first)))
        }
        XCTAssertEqual(transport.count, 0)
    }

    func testRestoreDisableCancelsPendingRestoreWithoutAnotherSnapshot() throws {
        let window = try showSettings()
        let restore = try control("settings-restore-clipboard", in: window)
        gtk_check_button_set_active(mp_check_button(restore), 1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.deliveryPreferences.clipboardRestore == .previousText })
        gtk_window_close(mp_window(window))
        try deliver()
        XCTAssertTrue(GTKTestSupport.spin { self.scheduler.restores.count == 1 })
        XCTAssertEqual(clipboard.snapshots, 1)
        _ = try showSettings()
        gtk_check_button_set_active(mp_check_button(restore), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.deliveryPreferences.clipboardRestore == .off })
        drain()
        scheduler.fireRestores()
        drain()
        XCTAssertEqual(clipboard.restored, 0)
        gtk_window_close(mp_window(window))
        try deliver()
        XCTAssertEqual(clipboard.snapshots, 1)
    }

    func testRepeatUsesAutomaticX11TerminalPolicyInsteadOfSavedDefault() throws {
        tools.environment["XDG_SESSION_TYPE"] = "x11"
        focus.target = .linux(session: .gnomeX11, x11WindowClass: "Konsole")
        compose()
        try deliver()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.repeatModel?.availability == .ready })
        let count = portal.ordinaryCalls.count
        environment.activateRepeat()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.repeatModel?.result != nil })
        XCTAssertEqual(environment.settingsModel.deliveryPreferences.linuxDefaultPasteChord, .standard)
        XCTAssertEqual(portal.ordinaryCalls.dropFirst(count).map { portal.keys($0).0 },
            [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
    }

    func testManualUpdateWhileOffShowsVersionAndInvokesOpenURIDriverOnlyOnRequest() throws {
        environment.settingsModel.setAutomaticUpdateChecks(.disabled)
        let window = try showSettings()
        XCTAssertEqual(text(try control("settings-update-version", in: window)), "Current version: 1.0.0-beta.2")
        XCTAssertTrue(opened.isEmpty)
        try checkNow(in: window)
        XCTAssertEqual(transport.count, 1)
        XCTAssertEqual(transport.requests.first?.headers["User-Agent"], "MonkeysPaw/1.0.0-beta.2")
        XCTAssertEqual(text(try control("settings-update-result", in: window)), "Update available: 1.0.0.")
        XCTAssertNotEqual(text(try control("settings-update-last-checked", in: window)), "Last successful check: never")
        XCTAssertTrue(opened.isEmpty)
        emitClick(try control("settings-view-release", in: window))
        XCTAssertTrue(GTKTestSupport.spin { self.opened.count == 1 })
        XCTAssertEqual(opened.first?.absoluteString, "https://github.com/L-K-M/MonkeysPaw/releases/tag/v1.0.0")
        openingOutcome = .failed
        emitClick(try control("settings-view-release", in: window))
        let error = try control("settings-update-open-error", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(error) != 0 })
        XCTAssertEqual(text(error), LinuxSettingsUpdateStrings.openingFailed)
        XCTAssertEqual(transport.count, 1)
    }

    func testUpdateErrorsAndNoReleaseAreNeverReportedAsUpToDate() throws {
        environment.settingsModel.setAutomaticUpdateChecks(.disabled)
        let window = try showSettings()
        for (reply, expected) in [
            (Result<HTTPResponse, HTTPTransportError>.failure(.networkFailure), "could not connect"),
            (.success(HTTPResponse(statusCode: 200, body: Data("{}".utf8))), "invalid release response"),
            (.success(HTTPResponse(statusCode: 500, body: Data())), "HTTP 500"),
            (.success(HTTPResponse(statusCode: 404, body: Data())), "No stable release"),
        ] {
            transport.reply = reply
            try checkNow(in: window)
            let result = text(try control("settings-update-result", in: window))
            XCTAssertTrue(result.contains(expected), result)
            XCTAssertFalse(result.contains("up to date"))
            XCTAssertEqual(gtk_widget_get_sensitive(try control("settings-view-release", in: window)), 0)
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testRateLimitStateAndCorruptHistoryAreVisible() throws {
        environment.settingsModel.setAutomaticUpdateChecks(.disabled)
        try RootedFileStore(root: paths.dataDirectory).write(Data("broken".utf8), at: "update-state.json")
        let window = try showSettings()
        let history = try control("settings-update-state-error", in: window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(history) != 0 })
        try checkNow(in: window)
        XCTAssertNotEqual(gtk_widget_get_visible(history), 0)
        XCTAssertEqual(try RootedFileStore(root: paths.dataDirectory).read(at: "update-state.json"), Data("broken".utf8))
        transport.reply = .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "60"], body: Data()))
        try checkNow(in: window)
        XCTAssertTrue(text(try control("settings-update-result", in: window)).contains("HTTP 429"))
        let count = transport.count
        emitClick(try control("settings-check-updates", in: window))
        drainUpdate()
        XCTAssertEqual(transport.count, count)
    }

    func testMissingAndInvalidVersionDisableManualAndAutomaticTraffic() throws {
        for version in [nil, "1.invalid"] {
            compose(version: version)
            let window = try showSettings()
            let check = try control("settings-check-updates", in: window)
            XCTAssertTrue(GTKTestSupport.spin { self.environment.updateSettingsModel.state.update != nil })
            XCTAssertEqual(gtk_widget_get_sensitive(check), 0)
            emitClick(check)
            environment.updateService.startAutomaticChecks()
            drainUpdate()
            XCTAssertEqual(transport.count, 0)
            XCTAssertTrue(text(try control("settings-update-result", in: window)).contains("unavailable"))
        }
    }

    func testXCTestStartupAndReopeningSendZeroRequestsEvenWithPackagedVersion() throws {
        environment.start()
        let window = try showSettings()
        for _ in 0..<3 {
            gtk_window_close(mp_window(window))
            XCTAssertNil(environment.updateSettingsModel.onChange)
            XCTAssertNil(environment.deliverySettingsModel.onChange)
            XCTAssertEqual(try showSettings(), window)
        }
        drainUpdate()
        XCTAssertEqual(transport.count, 0)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(tools.log.contains { $0.hasPrefix("set ") })
    }

    func testHiddenWindowDetachesCallbacksAndManualWorkSurvivesCloseAndLibraryReplacement() throws {
        environment.settingsModel.setAutomaticUpdateChecks(.disabled)
        let window = try showSettings()
        let result = try control("settings-update-result", in: window)
        transport.hold = true
        emitClick(try control("settings-check-updates", in: window))
        XCTAssertTrue(GTKTestSupport.spin { self.transport.count == 1 && self.environment.updateSettingsModel.state.update?.isChecking == true })
        let oldPicker = environment.pickerModel
        let newRoot = tools.directory.appendingPathComponent("next")
        try RootedFileStore(root: newRoot).write(Data("body".utf8), at: "prompt.md")
        XCTAssertEqual(environment.switchLibrary(to: newRoot), .switched)
        XCTAssertFalse(environment.pickerModel === oldPicker)
        gtk_window_close(mp_window(window))
        let hiddenText = text(result)
        transport.release()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.updateSettingsModel.state.update?.result == .updateAvailable(ReleaseVersion("1.0.0")!) })
        XCTAssertEqual(text(result), hiddenText)
        XCTAssertEqual(try showSettings(), window)
        XCTAssertEqual(text(result), "Update available: 1.0.0.")
        XCTAssertEqual(transport.count, 1)
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, newRoot.path)
    }

    func testAutomaticOffThenEnableUsesOneRequestAndShutdownRetiresHeldManualWork() throws {
        environment.settingsModel.setAutomaticUpdateChecks(.disabled)
        let window = try showSettings()
        environment.updateService.startAutomaticChecks()
        drainUpdate()
        XCTAssertEqual(transport.count, 0)
        gtk_check_button_set_active(mp_check_button(try control("settings-automatic-updates", in: window)), 1)
        XCTAssertTrue(GTKTestSupport.spin { self.transport.count == 1 && self.environment.updateSettingsModel.state.update?.lastSuccessfulCheck != nil })
        gtk_check_button_set_active(mp_check_button(try control("settings-automatic-updates", in: window)), 0)
        drainUpdate()
        XCTAssertEqual(transport.count, 1)
        transport.hold = true
        emitClick(try control("settings-check-updates", in: window))
        XCTAssertTrue(GTKTestSupport.spin { self.transport.count == 2 })
        let model = environment.updateSettingsModel
        let before = model.state
        environment.shutdown()
        transport.release()
        model.checkNow()
        model.viewRelease()
        model.setAutomaticUpdateChecks(.enabled)
        drainUpdate()
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(transport.count, 2)
        XCTAssertTrue(opened.isEmpty)
    }

    func testDestroyedPagesRejectDetachedControlsAndLateReports() throws {
        let window = try showSettings()
        let check = try control("settings-check-updates", in: window)
        let setup = try control("settings-delivery-open-setup", in: window)
        for button in [check, setup] { g_object_ref(button) }
        defer { for button in [check, setup] { g_object_unref(button) } }
        gtk_window_destroy(mp_window(window))
        emitClick(check)
        emitClick(setup)
        environment.updateSettingsModel.checkNow()
        environment.deliverySettingsModel.runSelfTest()
        drainUpdate()
        XCTAssertEqual(transport.count, 0)
        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertTrue(windows(LinuxStrings.setup).isEmpty)
    }

    private func compose(version: String? = "1.0.0-beta.2") {
        environment?.shutdown()
        environment = nil
        drain()
        while let list = gtk_application_get_windows(application), let data = list.pointee.data {
            gtk_window_destroy(data.assumingMemoryBound(to: GtkWindow.self))
        }
        paths = LinuxPaths(environment: tools.environment)
        let opener = GTKReleasePageOpener { [weak self] url, done in
            XCTAssertTrue(Thread.isMainThread)
            self?.opened.append(url)
            done(self?.openingOutcome ?? .failed)
        }
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: scheduler, focusTracker: focus, assistantTransport: transport, clipboard: clipboard,
            updateVersion: version, releasePage: opener)
    }

    private func showSettings() throws -> GTK.Widget {
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.windows(LinuxStrings.settings).contains { gtk_widget_get_visible($0) != 0 } })
        let window = try XCTUnwrap(windows(LinuxStrings.settings).first)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.updateSettingsModel.state.update != nil })
        return window
    }

    private func deliver() throws {
        let root = paths.documentsDirectory.appendingPathComponent("MonkeysPaw")
        try RootedFileStore(root: root).write(Data("body".utf8), at: "prompt.md")
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .picker })
        environment.pickerModel.use(mode: .paste(.standard))
        XCTAssertTrue(GTKTestSupport.spin {
            if case .done = self.environment.pickerModel.state { return true }
            return false
        })
    }

    private func checkNow(in window: GTK.Widget) throws {
        let count = transport.count
        let model = environment.updateSettingsModel
        let render = model.onChange
        var began = false
        model.onChange = { [weak model] in
            render?()
            if model?.state.update?.isChecking == true { began = true }
        }
        defer { model.onChange = render }
        emitClick(try control("settings-check-updates", in: window))
        XCTAssertTrue(GTKTestSupport.spin { began && self.transport.count == count + 1 && model.state.update?.isChecking == false })
    }

    private func drainUpdate() {
        var done = false
        environment.updateSettingsModel.refresh()
        let service = environment.updateService
        // Status reads serialize after preceding policy/check/stop work.
        let model = environment.updateSettingsModel
        model.refresh()
        GTK.after(0.1) { withExtendedLifetime(service) { done = true } }
        XCTAssertTrue(GTKTestSupport.spin { done })
        drain()
    }

    private func drain() {
        var done = false
        GTK.onMainLoop { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }

    private func control(_ name: String, in window: GTK.Widget) throws -> GTK.Widget { try settingsWidget(name, in: window) }
    private func text(_ label: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(label))) }

    private func emitClick(_ button: GTK.Widget) {
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, UnsafeMutableRawPointer(button))
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
    }

    private func windows(_ title: String) -> [GTK.Widget] {
        var result: [GTK.Widget] = []
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map({ String(cString: $0) }) == title { result.append(mp_window_widget(window)) }
            }
            node = current.pointee.next
        }
        return result
    }


}

private final class SettingsUpdateTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private var pending: CheckedContinuation<HTTPResponse, Error>?
    private var storedReply: Result<HTTPResponse, HTTPTransportError> = .success(HTTPResponse(statusCode: 200,
        body: Data("{\"tag_name\":\"v1.0.0\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://evil.example\"}".utf8)))
    private var held = false
    var count: Int { lock.withLock { recorded.count } }
    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var hold: Bool { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
    var reply: Result<HTTPResponse, HTTPTransportError> {
        get { lock.withLock { storedReply } }
        set { lock.withLock { storedReply = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertFalse(Thread.isMainThread)
        return try await withCheckedThrowingContinuation { continuation in
            let reply: Result<HTTPResponse, HTTPTransportError>? = lock.withLock {
                recorded.append(request)
                if held { pending = continuation; return nil }
                return storedReply
            }
            if let reply { continuation.resume(with: reply.mapError { $0 as Error }) }
        }
    }

    func release() {
        let (continuation, reply) = lock.withLock {
            let continuation = pending
            pending = nil
            held = false
            return (continuation, storedReply)
        }
        continuation?.resume(with: reply.mapError { $0 as Error })
    }
}

private final class SettingsDelayScheduler: Scheduler {
    var restores: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if delay == Limits.clipboardRestoreDelay { restores.append(work) }
        else { GTK.onMainLoop(work) }
    }
    func fireRestores() { let work = restores; restores.removeAll(); work.forEach { $0() } }
}

private final class SettingsDeliveryFocus: FocusTracker {
    var target = DeliveryTarget.linux(session: .gnomeWayland, x11WindowClass: nil)
    func captureTarget() -> DeliveryTarget? { target }
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) { completion(.unconfirmed) }
}

private final class SettingsRestoreClipboard: ClipboardRestoring {
    private final class Revision: ClipboardRevision {}
    private final class Ownership: ClipboardWriteOwnership {}
    private final class Read: ClipboardSnapshotRead { func cancel() {} }
    var writes = 0
    var snapshots = 0
    var restored = 0
    func writeText(_ text: String) { writes += 1 }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
    func snapshotText(budget: Duration, byteLimit: Int, completion: @escaping (ClipboardTextSnapshot?) -> Void) -> ClipboardSnapshotRead {
        snapshots += 1
        completion(ClipboardTextSnapshot(text: "previous", revision: Revision()))
        return Read()
    }
    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership? { writes += 1; return Ownership() }
    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) { restored += 1 }
}
#endif
