#if os(Linux)
import CGtk
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxKDECompositionTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var service: FakeKGlobalAccel!
    private var portal: FakePortal!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        service = try FakeKGlobalAccel(address: address)
        try service.ownName()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        try portal.ownName()
        try portal.ownNotifications()
        tools = try PortalSessionTestSupport.tools()
        tools.environment["XDG_CURRENT_DESKTOP"] = "KDE"
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    override func tearDown() {
        environment?.shutdown()
        if service?.present == true { XCTAssertTrue(GTKTestSupport.spin { !self.service.present }) }
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        service?.shutdown()
        service = nil
        portal?.shutdown()
        portal = nil
        tools = nil
    }

    private func row(_ kind: SetupRow.Kind) -> SetupRow? {
        environment.setupModel.rows.first { $0.kind == kind }
    }

    private func start() {
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin {
            self.row(.hotkey)?.registration?.status == .registered && self.portal.propertyCalls.count >= 2
        })
    }

    func testNativeKDESelectionReachesSetup() throws {
        start()
        let row = try XCTUnwrap(row(.hotkey))
        XCTAssertEqual(row.registration?.mechanism, .kglobalaccel)
        XCTAssertTrue(GTKTestSupport.spin { service.present })
        XCTAssertEqual(row.registration?.detail, "Ctrl+Alt+P")
        XCTAssertEqual(row.registration?.configuration, .systemSettings)
        XCTAssertEqual(self.row(.kde)?.status, .ok)
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertFalse(portal.propertyCalls.contains { $0.interface == "org.freedesktop.portal.GlobalShortcuts" })
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testKDEX11AlsoSelectsTheNativeDriver() {
        tools.environment["XDG_SESSION_TYPE"] = "x11"
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment)
        start()
        XCTAssertEqual(environment.setupModel.session, .kdeX11)
        XCTAssertEqual(row(.hotkey)?.registration?.mechanism, .kglobalaccel)
    }

    func testManualColdToggleCannotVerifyAndReleaseUsesServiceDebounce() {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.environment.panel.clipboardOwner) != 0 })
        start()
        environment.setupModel.beginHotkeyVerification()
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.environment.panel.clipboardOwner) == 0 })
        XCTAssertNotEqual(row(.hotkey)?.status, .ok)
        service.emit("globalShortcutPressed")
        service.emit("globalShortcutRepeated")
        service.emit()
        service.emit() // Same burst: ShortcutService debounces the second toggle.
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.status == .ok })
        var completed = false
        GTK.after(Limits.toggleDebounce.timeInterval) { completed = true }
        XCTAssertTrue(GTKTestSupport.spin { completed })
        XCTAssertNotEqual(gtk_widget_get_visible(environment.panel.clipboardOwner), 0)
        service.change("@a(ai) []")
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .unbound })
        XCTAssertNotEqual(row(.hotkey)?.status, .ok)
    }

    func testVerifiedConflictRemainsActionableAndFixRechecksNativeState() {
        start()
        environment.setupModel.beginHotkeyVerification()
        service.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.status == .ok })
        service.available = false
        service.change("@a(ai) [([67108933],)]")
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.detail.contains("conflicts") == true })
        XCTAssertNotEqual(row(.hotkey)?.status, .ok)
        XCTAssertNotEqual(row(.kde)?.status, .ok)
        service.available = true
        let count = service.calls.count
        environment.setupModel.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin {
            self.service.calls.count > count && self.row(.hotkey)?.registration?.status == .registered
        })
        XCTAssertEqual(row(.hotkey)?.registration?.detail, "Ctrl+E")
        XCTAssertEqual(service.calls.filter { $0.method == "doRegister" }.count, 1)
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testSetupKDEFixRetriesFailureAndHealthyConfigurationHasAnIntent() {
        service.errors = ["getComponent"]
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .failed })
        XCTAssertFalse(row(.kde)?.status == .needsAction(fix: SetupStrings.kdeShortcut + " (Added in M1d)"))
        service.errors.removeAll()
        environment.setupModel.fix(.kde)
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .registered })
        environment.setupModel.beginHotkeyVerification()
        service.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.status == .ok })
        let count = service.calls.filter { $0.method == "shortcutKeys" }.count
        environment.setupModel.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin { self.service.calls.filter { $0.method == "shortcutKeys" }.count > count })
    }

    func testKDEDiagnosticsDoNotAskForConsentAndKeepLadderOrder() {
        var report: SelfTestReport?
        environment.runSelfTest { report = $0 }
        XCTAssertTrue(GTKTestSupport.spin(until: { report != nil }, timeout: .seconds(4)))
        XCTAssertEqual(report?.session, .kdeWayland)
        XCTAssertEqual(report?.results.map(\.backend), [.ydotool, .remoteDesktopPortal])
        XCTAssertEqual(report?.results.last?.status, .failed(.backendUnavailable))
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testFlatpakOnKDEKeepsTheExistingPortalPath() {
        environment.shutdown()
        tools.environment["FLATPAK_ID"] = AppIdentity.linuxAppID
        environment = LinuxEnvironment(application: application, environment: tools.environment)
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.mechanism == .globalShortcutsPortal })
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(environment.setupModel.session, .flatpak(host: .kdeWayland))
    }
}
#endif
