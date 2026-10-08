#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPortalCompositionTests: XCTestCase {
    private var portal: FakePortal!
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var environment: LinuxEnvironment!
    private var tools: FakeLinuxTools!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        try portal.ownName()
        try portal.ownNotifications()
        tools = try PortalSessionTestSupport.tools()
        tools.environment["XDG_CURRENT_DESKTOP"] = "GNOME"
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        portal?.shutdown()
        portal = nil
        tools = nil
    }

    private func row(_ kind: SetupRow.Kind) -> SetupRow? {
        environment.setupModel.rows.first { $0.kind == kind }
    }

    private func start() {
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration != nil && self.portal.propertyCalls.count >= 3 })
    }

    func testServiceStartupOnlyProbesAndSetupOwnsConsentAndVerification() throws {
        start()
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
        XCTAssertEqual(row(.hotkey)?.registration?.mechanism, .globalShortcutsPortal)
        XCTAssertNotEqual(row(.portal)?.status, .ok)
        environment.setupModel.fix(.portal)
        XCTAssertTrue(GTKTestSupport.spin { self.row(.portal)?.status == .ok })
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "SelectDevices", "Start"])
        environment.setupModel.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .registered })
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        environment.setupModel.beginHotkeyVerification()
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.environment.panel.clipboardOwner) != 0 })
        XCTAssertNotEqual(row(.hotkey)?.status, .ok)
        let shortcutSession = try XCTUnwrap(portal.sessionOwners.first { $0.key.hasSuffix(PortalHotkeyBackend.sessionToken) }?.key)
        portal.emit(member: "Activated", body: "(objectpath '\(shortcutSession)', 'toggle', uint64 1, {'activation_token': <'native-fixture'>})")
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.status == .ok })
        XCTAssertEqual(row(.hotkey)?.registration?.configuration, .systemSettings)
        environment.setupModel.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.ordinaryCalls.contains { $0.method == "ConfigureShortcuts" } })
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: shortcutSession)
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .failed })
        XCTAssertNotEqual(row(.hotkey)?.status, .ok)
    }

    func testSelfTestDoesNotStartConsentAndReportsPerBackendFailure() {
        var report: SelfTestReport?
        environment.runSelfTest { report = $0 }
        XCTAssertTrue(GTKTestSupport.spin(until: { report != nil }, timeout: .seconds(4)))
        XCTAssertEqual(report?.session, .gnomeWayland)
        XCTAssertEqual(report?.results.map(\.backend), [.remoteDesktopPortal, .ydotool])
        XCTAssertEqual(report?.results.first?.status, .failed(.backendUnavailable))
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testPanelIntentUsesRealPortalInjectorAndFailureCacheFallsThrough() {
        start()
        environment.panelModel.confirm(mode: .paste(.terminal))
        XCTAssertTrue(GTKTestSupport.spin { self.portal.ordinaryCalls.filter { $0.method == "NotifyKeyboardKeysym" }.count == 6 })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panelModel.state == .done(.pasted(.remoteDesktopPortal)) })
        XCTAssertEqual(portal.ordinaryCalls.map { portal.keys($0).0 }, [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
        XCTAssertTrue(tools.arguments.isEmpty)
        environment.panelModel.show()
        portal.methodError = "org.freedesktop.portal.Error.Failed"
        environment.panelModel.confirm(mode: .paste(.standard))
        XCTAssertTrue(GTKTestSupport.spin { if case .done = self.environment.panelModel.state { return true }; return false })
        let calls = portal.ordinaryCalls.count
        environment.panelModel.show()
        environment.panelModel.confirm(mode: .paste(.standard))
        XCTAssertTrue(GTKTestSupport.spin { if case .done = self.environment.panelModel.state { return true }; return false })
        XCTAssertEqual(portal.ordinaryCalls.count, calls)
        guard case .done(.copiedOnly(.backendsFailed(let failures))) = environment.panelModel.state else {
            return XCTFail("Expected copy fallback")
        }
        XCTAssertEqual(failures.map(\.backend), [.remoteDesktopPortal, .ydotool])
        // Delivery completes before GNotification's asynchronous acknowledgement.
        // Do not disconnect the fake daemon while its native call is pending.
        XCTAssertTrue(GTKTestSupport.spin { self.portal.notificationCount == 2 })
    }

    func testUnsupportedGnomeServiceDoesNotInstallUntilSetupIntent() {
        portal.versions[PortalInterface.globalShortcuts.rawValue] = 0
        start()
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.mechanism == .gnomeCustomKeybinding })
        XCTAssertTrue(tools.arguments.isEmpty)
        environment.setupModel.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin { self.row(.hotkey)?.registration?.status == .registered })
        XCTAssertTrue(tools.arguments.contains { $0.first == "set" })
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testFlatpakUsesPortalOnlyAndPreservesHostIdentity() {
        environment.shutdown()
        tools.environment["FLATPAK_ID"] = AppIdentity.linuxAppID
        environment = LinuxEnvironment(application: application, environment: tools.environment)
        start()
        environment.panelModel.confirm(mode: .paste(.standard))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panelModel.state == .done(.pasted(.remoteDesktopPortal)) })
        XCTAssertEqual(environment.setupModel.session, .flatpak(host: .gnomeWayland))
        XCTAssertEqual(row(.ydotool)?.status, .notApplicable)
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testNativeX11IdentifierIsHexadecimalAndNoWindowUsesEmptyParent() throws {
        let native = PortalWindow(application: application)
        var identifier: String?
        native.parent { identifier = $0.identifier; $0.close() }
        XCTAssertEqual(identifier, "")
        let window = try XCTUnwrap(gtk_application_window_new(application))
        gtk_window_present(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_mapped(window) != 0 })
        let raw = try XCTUnwrap(mp_portal_x11_parent(mp_window(window)))
        defer { g_free(raw) }
        let text = String(cString: raw)
        XCTAssertTrue(text.hasPrefix("x11:"))
        XCTAssertNotNil(UInt64(text.dropFirst(4), radix: 16))
    }
}
#endif
