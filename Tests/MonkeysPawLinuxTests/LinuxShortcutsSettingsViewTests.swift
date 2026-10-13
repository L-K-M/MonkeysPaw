#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxShortcutsSettingsViewTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var view: LinuxSettingsWindow!
    private var window: GTK.Widget!
    private var backend: SettingsHotkeyBackend!
    private var probe: SettingsSetupProbe!
    private var model: ShortcutsSettingsModel!
    private var setupModel: SetupModel!

    override func setUpWithError() throws {
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        environment = LinuxEnvironment(application: application, environment: [
            "HOME": tools.directory.path, "PATH": tools.directory.path,
            "XDG_CONFIG_HOME": tools.directory.path, "XDG_DATA_HOME": tools.directory.path,
        ])
        let main = GLibMainThread()
        let ports = SettingsViewPorts()
        let scheduler = GLibScheduler()
        backend = SettingsHotkeyBackend()
        probe = SettingsSetupProbe(backend: backend)
        let shortcuts = ShortcutService(backend: backend, scheduler: scheduler, mainThread: main)
        let delivery = DeliveryService(panel: ports, focus: ports, clipboard: ports, injectors: [],
            notifier: ports, session: ports, scheduler: scheduler, mainThread: main,
            failureCache: SessionPasteFailureCache())
        let selfTest = SelfTest(target: ports, delivery: delivery, session: ports, scheduler: scheduler, mainThread: main)
        let setup = SetupService(probe: probe, session: ports, shortcuts: shortcuts, selfTest: selfTest, mainThread: main)
        setupModel = SetupModel(setup: setup)
        model = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
        shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        view = LinuxSettingsWindow(application: application, general: environment.generalSettingsModel,
            shortcuts: model, rememberedValues: environment.rememberedValuesSettingsModel,
            makeAssistant: { nil },
            chooser: SettingsFolderChooser(), openSetup: { XCTFail("Unexpected Setup intent") })
        view.show()
        XCTAssertTrue(GTKTestSupport.spin { self.model.togglePicker.registration != nil })
        let windows = try XCTUnwrap(gtk_application_get_windows(application))
        let raw = try XCTUnwrap(windows.pointee.data)
        window = mp_window_widget(raw.assumingMemoryBound(to: GtkWindow.self))
        XCTAssertEqual(String(cString: gtk_window_get_title(mp_window(window))), LinuxStrings.settings)
        gtk_notebook_set_current_page(mp_notebook(try widget("settings-tabs")), 1)
    }

    override func tearDown() {
        environment?.shutdown()
        if let application { GTKTestSupport.destroy(application) }
        view = nil
        model = nil
        setupModel = nil
        environment = nil
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
        application = nil
        tools = nil
    }

    func testSystemSettingsActionRendersBackendFactsAndRequiresActualActivationToVerify() throws {
        XCTAssertEqual(model.togglePicker.changePath, .systemSettings(action: .hotkey))
        XCTAssertEqual(try text("settings-toggle-binding"), "Ctrl+K, Ctrl+P; Alt+F9")
        let registration = try text("settings-toggle-registration")
        XCTAssertTrue(registration.contains("KDE global shortcut"))
        XCTAssertTrue(registration.contains("Registered"))
        XCTAssertTrue(registration.contains("Ctrl+K, Ctrl+P; Alt+F9"))
        XCTAssertEqual(gtk_button_get_label(mp_button(try widget("settings-change-shortcut"))).map(String.init(cString:)),
            LinuxStrings.configureShortcuts)
        try click("settings-change-shortcut")
        XCTAssertTrue(GTKTestSupport.spin { self.probe.fixes == [.hotkey] })
        XCTAssertEqual(model.togglePicker.verification, .notStarted)
        XCTAssertEqual(try text("settings-toggle-verification"), LinuxStrings.shortcutVerification(.notStarted))

        try click("settings-verify-shortcut")
        XCTAssertTrue(GTKTestSupport.spin { self.model.togglePicker.verification == .waiting })
        XCTAssertEqual(try text("settings-toggle-verification"), LinuxStrings.shortcutVerification(.waiting))
        backend.fire?()
        XCTAssertTrue(GTKTestSupport.spin { self.model.togglePicker.verification == .verified })
        XCTAssertEqual(try text("settings-toggle-verification"), LinuxStrings.shortcutVerification(.verified))
        XCTAssertEqual(setupModel.rows.first { $0.kind == .hotkey }?.status, .ok)
        XCTAssertEqual(try text("settings-repeat-binding"), SetupStrings.unboundShortcut)
        XCTAssertEqual(model.repeatLast.changePath, .unavailable)
    }

    func testSetupActionUsesModelRouteAndSharesUpdatesWithSetup() throws {
        try refresh(.globalShortcutsPortal, status: .needsAction, detail: "Allow the shortcut in Setup",
            configuration: .attachPortal)
        XCTAssertEqual(model.togglePicker.changePath, .setup(.hotkey))
        XCTAssertEqual(try text("settings-toggle-binding"), LinuxStrings.unknown)
        XCTAssertTrue(try text("settings-toggle-registration").contains("Allow the shortcut in Setup"))
        XCTAssertEqual(gtk_button_get_label(mp_button(try widget("settings-change-shortcut"))).map(String.init(cString:)),
            LinuxStrings.setupShortcut)
        try click("settings-change-shortcut")
        XCTAssertTrue(GTKTestSupport.spin { self.probe.fixes == [.hotkey] })
        XCTAssertEqual(model.togglePicker.verification, .notStarted)
        try refresh(.globalShortcutsPortal, status: .registered, detail: "User-selected key", configuration: .systemSettings)
        XCTAssertEqual(try text("settings-toggle-binding"), "User-selected key")
        XCTAssertEqual(setupModel.rows.first { $0.kind == .hotkey }?.registration, model.togglePicker.registration)
    }

    func testManualAndSystemGuidanceRenderInstructionsWithoutRunningAConfigureAction() throws {
        let instructions = "Bind gapplication action ch.lkmc.monkeyspaw toggle in your desktop's settings."
        try refresh(.manual, status: .needsAction, detail: instructions)
        XCTAssertEqual(model.togglePicker.changePath, .manualInstructions(instructions))
        XCTAssertEqual(try text("settings-shortcut-instructions"), instructions)
        try click("settings-change-shortcut")
        XCTAssertTrue(GTKTestSupport.spin { self.model.instructions == instructions })
        XCTAssertTrue(probe.fixes.isEmpty)
        XCTAssertEqual(try text("settings-shortcut-instructions"), instructions)
        model.setAccelerator("Ctrl+Alt+E")
        XCTAssertTrue(GTKTestSupport.spin { self.model.error == .unavailable })
        XCTAssertEqual(try text("settings-shortcut-error"), LinuxStrings.shortcutError(.unavailable))
        XCTAssertNotEqual(gtk_widget_get_visible(try widget("settings-shortcut-error")), 0)

        try refresh(.globalShortcutsPortal, status: .registered, detail: "User-selected key")
        XCTAssertEqual(model.togglePicker.changePath, .systemSettingsGuidance(SetupStrings.kdeShortcut))
        XCTAssertEqual(try text("settings-shortcut-instructions"), SetupStrings.kdeShortcut)
        XCTAssertEqual(gtk_widget_get_visible(try widget("settings-shortcut-error")), 0)
        try click("settings-change-shortcut")
        XCTAssertTrue(GTKTestSupport.spin { self.model.instructions == SetupStrings.kdeShortcut })
        XCTAssertTrue(probe.fixes.isEmpty)
    }

    func testUnboundAndFailedRegistrationsDisableVerificationAndKeepFailureDetail() throws {
        for status in [RegistrationStatus.unbound, .failed] {
            let detail = "Choose a free key; your suggested key is already used."
            try refresh(.kglobalaccel, status: status, detail: detail, configuration: .systemSettings)
            XCTAssertEqual(gtk_widget_get_sensitive(try widget("settings-verify-shortcut")), 0)
            XCTAssertTrue(try text("settings-toggle-registration").contains(detail))
            XCTAssertEqual(model.togglePicker.verification, .notStarted)
        }
    }

    func testInAppChangePathHasNoLinuxRecorderOrChangeAction() throws {
        try refresh(.carbon, status: .registered, detail: "Synthetic unreachable mechanism")
        XCTAssertEqual(model.togglePicker.changePath, .inApp)
        XCTAssertEqual(gtk_widget_get_visible(try widget("settings-change-shortcut")), 0)
        func containsEntry(_ widget: GTK.Widget) -> Bool {
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_entry_get_type()) != 0 { return true }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if containsEntry(current) { return true }
                child = gtk_widget_get_next_sibling(current)
            }
            return false
        }
        let tabs = try widget("settings-tabs")
        let shortcutsPage = try XCTUnwrap(gtk_notebook_get_nth_page(mp_notebook(tabs), 1))
        XCTAssertFalse(containsEntry(shortcutsPage))
        XCTAssertTrue(probe.fixes.isEmpty)
    }

    private func refresh(_ mechanism: HotkeyMechanism, status: RegistrationStatus, detail: String,
                         configuration: HotkeyConfiguration? = nil) throws {
        backend.registration = HotkeyRegistration(mechanism: mechanism, status: status, detail: detail, configuration: configuration)
        setupModel.refresh()
        XCTAssertTrue(GTKTestSupport.spin { self.model.togglePicker.registration == self.backend.registration })
    }

    private func widget(_ name: String) throws -> GTK.Widget { try settingsWidget(name, in: window) }
    private func text(_ name: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try widget(name)))) }
    private func click(_ name: String) throws { XCTAssertNotEqual(gtk_widget_activate(try widget(name)), 0) }
}

private final class SettingsHotkeyBackend: HotkeyBackend {
    var registration = HotkeyRegistration(mechanism: .kglobalaccel, status: .registered,
        detail: "Ctrl+K, Ctrl+P; Alt+F9", configuration: .systemSettings)
    var mechanism: HotkeyMechanism { registration.mechanism }
    var fire: (() -> Void)?
    let unboundRepeat = HotkeyRegistration(mechanism: .kglobalaccel, status: .unbound,
        detail: SetupStrings.unboundShortcut, configuration: .unavailable)
    func register(_ action: HotkeyAction, accelerator: Accelerator?, onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker, accelerator != nil else { return unboundRepeat }
        fire = onFire
        return registration
    }
    func unregister(_ registration: HotkeyRegistration) {}
}

private final class SettingsSetupProbe: SetupProbe {
    private let backend: SettingsHotkeyBackend
    private(set) var fixes: [SetupRow.Kind] = []
    init(backend: SettingsHotkeyBackend) { self.backend = backend }
    func accessibilityStatus() -> SetupStatus { .notApplicable }
    func portalStatus() -> SetupStatus { .notApplicable }
    func ydotoolStatus() -> SetupStatus { .notApplicable }
    func kdeStatus() -> SetupStatus { .needsAction(fix: SetupStrings.kdeShortcut) }
    func hotkeyRegistration(for action: HotkeyAction) -> HotkeyRegistration {
        action == .togglePicker ? backend.registration : backend.unboundRepeat
    }
    func performFix(for kind: SetupRow.Kind, action: HotkeyAction, done: @escaping () -> Void) { fixes.append(kind); done() }
}

/// Shortcuts never uses delivery ports. Fail if the view accidentally does.
private final class SettingsViewPorts: PanelWindow, FocusTracker, Clipboard, Notifier, SessionProbe, SelfTestTarget {
    func show() { XCTFail("Unexpected delivery") }
    func hideForDelivery() { XCTFail("Unexpected delivery") }
    func hide() { XCTFail("Unexpected delivery") }
    func captureTarget() -> DeliveryTarget? { XCTFail("Unexpected delivery"); return nil }
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) { XCTFail("Unexpected delivery") }
    func writeText(_ text: String) { XCTFail("Unexpected clipboard write") }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { XCTFail("Unexpected clipboard read") }
    func copied() { XCTFail("Unexpected delivery") }
    func pressPaste(chord: PasteChord, reason: CopyReason) { XCTFail("Unexpected delivery") }
    func currentSession() -> DesktopSession { .kdeWayland }
    func present(fieldExpecting text: String) { XCTFail("Unexpected self-test") }
    func readBack() -> String? { XCTFail("Unexpected self-test"); return nil }
    func close() { XCTFail("Unexpected self-test") }
}
#endif
