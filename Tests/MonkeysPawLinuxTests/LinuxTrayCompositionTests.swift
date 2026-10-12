#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxTrayCompositionTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var watcher: FakeStatusNotifierWatcher!
    private var environment: LinuxEnvironment!
    private var launchedURLs: [URL] = []
    private var quitRequests = 0

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        watcher = try FakeStatusNotifierWatcher(address: address)
        tools = try FakeLinuxTools()
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = address
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        compose()
        environment.settingsModel.markSetupPresented()
        environment.settingsModel.completeLibraryFolderStep()
        environment.settingsModel.markSeedsOffered()
        let quit = g_simple_action_new(ActionName.quit.rawValue, nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(quit)) { [weak self] in self?.quitRequests += 1 }
        g_action_map_add_action(mp_action_map(application), mp_action(quit))
        g_object_unref(UnsafeMutableRawPointer(quit))
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        watcher?.shutdown()
        watcher = nil
        tools = nil
        launchedURLs = []
        quitRequests = 0
        drain()
    }

    func testStartupRegistersOneItemWithTheComposedMenu() throws {
        try start()
        environment.start()
        drain()
        XCTAssertEqual(watcher.registrations.count, 1)
        XCTAssertEqual(try rows(), [
            Row(id: 1, label: "Show Picker", enabled: true),
            Row(id: 2, label: environment.libraryStatusModel.menuLabel, enabled: true),
            Row(id: 3, label: "Settings…", enabled: true),
            Row(id: 4, label: "Setup…", enabled: true),
            Row(id: 5, label: "Quit", enabled: true),
        ])
        XCTAssertEqual(environment.libraryStatusModel.menuLabel, "Open Library")
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertTrue(visibleWindows().isEmpty)
    }

    func testLeftClickAndShowPickerToggleWithoutVerifyingTheShortcut() throws {
        let portal = try FakePortal(address: FakePortal.requirePrivateBus())
        portal.behavior = .sessions
        try portal.ownName()
        defer { portal.shutdown() }
        try start()
        let shortcuts = environment.shortcutsSettingsModel
        shortcuts.beginVerification()
        XCTAssertTrue(GTKTestSupport.spin { shortcuts.togglePicker.verification == .waiting })
        let propertiesReply = watcher.call(path: "/StatusNotifierItem", interface: "org.freedesktop.DBus.Properties",
            method: "GetAll", body: "('org.kde.StatusNotifierItem',)")
        let properties = g_variant_get_child_value(try XCTUnwrap(propertiesReply.value), 0)!
        defer { g_variant_unref(properties) }
        let isMenu = try XCTUnwrap(g_variant_lookup_value(properties, "ItemIsMenu", nil))
        defer { g_variant_unref(isMenu) }
        XCTAssertEqual(g_variant_get_boolean(isMenu), 0,
            "The item must advertise primary activation for hosts to route left click to Activate.")

        let reply = watcher.call(path: "/StatusNotifierItem", interface: "org.kde.StatusNotifierItem",
            method: "Activate", body: "(0, 0)")
        XCTAssertFalse(reply.failed)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        try click(1)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        try click(1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(shortcuts.togglePicker.verification, .waiting)
    }

    func testSettingsOpensAndReusesTheExistingWindowAfterDismissingPicker() throws {
        try start()
        try click(1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        try click(3)
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        g_action_group_activate_action(mp_action_group(application), ActionName.settings.rawValue, nil)
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.settings), settings)
        gtk_window_close(mp_window(settings))
        try click(3)
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.settings), settings)
    }

    func testSetupOpensAndReusesSetupWithoutReopeningCompletedOnboarding() throws {
        try start()
        try click(1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        try click(4)
        let setup = try visibleWindow(titled: LinuxStrings.setup)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        gtk_window_close(mp_window(setup))
        drain()
        try click(4)
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.setup), setup)
        XCTAssertFalse(visibleWindows().contains { title(of: $0) == LinuxStrings.onboarding })
    }

    func testOpenLibraryRevealsTheCurrentFolderIncludingAfterASwitch() throws {
        try start()
        try click(2)
        XCTAssertTrue(GTKTestSupport.spin { self.launchedURLs.count == 1 })
        let initial = URL(fileURLWithPath: environment.generalSettingsModel.state.activeLibraryPath, isDirectory: true)
        XCTAssertEqual(launchedURLs, [initial])
        let replacement = try library("Replacement")
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        drain()
        try click(2)
        XCTAssertTrue(GTKTestSupport.spin { self.launchedURLs.count == 2 })
        XCTAssertEqual(launchedURLs.last, replacement)
    }

    func testUnavailableStartupDisablesLibraryAndSuccessfulSwitchRestoresIt() throws {
        environment.settingsModel.setLibraryFolder(tools.directory.appendingPathComponent("Missing").path)
        try start()
        let status = environment.libraryStatusModel
        XCTAssertEqual(status.state, .unavailableAtStartup)
        XCTAssertEqual(try rows().first { $0.id == 2 }, Row(id: 2, label: status.menuLabel, enabled: false))
        XCTAssertEqual(status.menuLabel, "Library unavailable")
        try click(2)
        drain()
        XCTAssertTrue(launchedURLs.isEmpty)
        let replacement = try library("Recovered")
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        XCTAssertTrue(GTKTestSupport.spin { status.state == .available })
        XCTAssertTrue(environment.libraryStatusModel === status)
        XCTAssertEqual(try rows().first { $0.id == 2 }, Row(id: 2, label: status.menuLabel, enabled: true))
        try click(2)
        XCTAssertTrue(GTKTestSupport.spin { self.launchedURLs == [replacement] })
        XCTAssertTrue(watcher.signals.contains { $0.name == "ItemsPropertiesUpdated" })
    }

    func testRuntimeLossUpdatesTheRowAndSuccessfulSwitchRestoresIt() throws {
        try start()
        let status = environment.libraryStatusModel
        let initial = URL(fileURLWithPath: environment.generalSettingsModel.state.activeLibraryPath, isDirectory: true)
        try FileManager.default.removeItem(at: initial)
        XCTAssertTrue(GTKTestSupport.spin { status.state == .lostWhileRunning })
        XCTAssertEqual(try rows().first { $0.id == 2 }, Row(id: 2, label: "Library unavailable", enabled: false))
        try click(2)
        drain()
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.switchLibrary(to: try library("AfterLoss")), .switched)
        XCTAssertTrue(GTKTestSupport.spin { status.state == .available })
        XCTAssertEqual(try rows().first { $0.id == 2 }, Row(id: 2, label: "Open Library", enabled: true))
    }

    func testQuitRequestsTheExistingApplicationAction() throws {
        try start()
        try click(5)
        XCTAssertTrue(GTKTestSupport.spin { self.quitRequests == 1 })
    }

    func testTrayPresentationActionsPreserveDeliveryAndWorkAfterItCompletes() throws {
        let notifications = try FakePortal(address: FakePortal.requirePrivateBus())
        try notifications.ownNotifications()
        defer { notifications.shutdown() }
        let scheduler = TrayScheduler()
        compose(scheduler: scheduler)
        let path = environment.generalSettingsModel.state.activeLibraryPath
        try RootedFileStore(root: URL(fileURLWithPath: path, isDirectory: true))
            .write(Data("Tray delivery".utf8), at: "tray.md")
        try start()
        try click(1)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        let picker = environment.pickerModel
        picker.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin {
            picker.state == .delivering && scheduler.delays.contains(Limits.settleDelayLinux)
        })
        for id: Int32 in [1, 2, 3, 4] { try click(id) }
        drain()
        XCTAssertEqual(picker.state, .delivering)
        XCTAssertTrue(visibleWindows().isEmpty)
        XCTAssertTrue(launchedURLs.isEmpty)
        scheduler.fireAll()
        XCTAssertTrue(GTKTestSupport.spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { notifications.notificationCount == 1 })
        try click(4)
        _ = try visibleWindow(titled: LinuxStrings.setup)
    }

    func testNoWatcherLeavesExistingEntryPointsUsableWithoutAFallbackWindow() throws {
        tools.environment["XDG_CURRENT_DESKTOP"] = "GNOME"
        compose()
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.hasOwner(FakeStatusNotifierWatcher.itemName) })
        drain()
        XCTAssertTrue(watcher.registrations.isEmpty)
        XCTAssertFalse(watcher.hasOwner("org.kde.StatusNotifierWatcher"))
        XCTAssertTrue(visibleWindows().isEmpty)
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        g_action_group_activate_action(mp_action_group(application), ActionName.settings.rawValue, nil)
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        XCTAssertFalse(environment.panel.isVisible)
        gtk_window_close(mp_window(settings))
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        let button = try settingsWidget("picker-settings", in: environment.panel.clipboardOwner)
        XCTAssertNotEqual(gtk_widget_activate(button), 0)
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.settings), settings)
        XCTAssertTrue(watcher.registrations.isEmpty)
    }

    func testShutdownUnexportsAndCannotRestartOrRegisterWithALaterWatcher() throws {
        try start()
        let sender = try XCTUnwrap(watcher.registrations.first?.sender)
        let status = environment.libraryStatusModel
        environment.shutdown()
        environment.shutdown()
        status.libraryReplaced(available: false)
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { !self.watcher.hasOwner(FakeStatusNotifierWatcher.itemName) })
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(0, -1, @as [])", destination: sender).failed)
        XCTAssertTrue(watcher.call(path: "/StatusNotifierItem", interface: "org.freedesktop.DBus.Properties",
            method: "GetAll", body: "('org.kde.StatusNotifierItem',)", destination: sender).failed)
        watcher.dropName()
        try watcher.ownName()
        drain()
        XCTAssertEqual(watcher.registrations.count, 1)
        XCTAssertTrue(visibleWindows().isEmpty)
    }

    private func start() throws {
        try watcher.ownName()
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.count == 1 }, "Startup did not register a tray item.")
        guard watcher.registrations.count == 1 else { throw NSError(domain: "LinuxTrayCompositionTests", code: 1) }
    }

    private func compose(scheduler: Scheduler? = nil) {
        environment?.shutdown()
        environment = nil
        drain()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: scheduler, libraryAvailabilityNotifier: TrayNotifications(),
            launchURI: { [weak self] in self?.launchedURLs.append($0) })
        MonkeysPawLinuxApp.installSettingsAction(application: application, environment: environment)
    }

    private func click(_ id: Int32) throws {
        let reply = watcher.call(method: "Event", body: "(\(id), 'clicked', <0>, uint32 0)")
        XCTAssertFalse(reply.failed)
        guard !reply.failed else { throw NSError(domain: "LinuxTrayCompositionTests", code: 2) }
    }

    private struct Row: Equatable {
        let id: Int32
        let label: String
        let enabled: Bool
    }

    private func rows() throws -> [Row] {
        let reply = watcher.call(method: "GetLayout", body: "(0, -1, @as [])")
        let value = try XCTUnwrap(reply.value)
        let root = g_variant_get_child_value(value, 1)!
        let children = g_variant_get_child_value(root, 2)!
        defer { g_variant_unref(root); g_variant_unref(children) }
        return try (0..<g_variant_n_children(children)).map { index in
            let wrapper = g_variant_get_child_value(children, index)!
            let row = g_variant_get_variant(wrapper)!
            let id = g_variant_get_child_value(row, 0)!
            let properties = g_variant_get_child_value(row, 1)!
            defer { g_variant_unref(wrapper); g_variant_unref(row); g_variant_unref(id); g_variant_unref(properties) }
            let label = try XCTUnwrap(g_variant_lookup_value(properties, "label", nil))
            let enabled = try XCTUnwrap(g_variant_lookup_value(properties, "enabled", nil))
            defer { g_variant_unref(label); g_variant_unref(enabled) }
            return Row(id: g_variant_get_int32(id), label: String(cString: g_variant_get_string(label, nil)),
                enabled: g_variant_get_boolean(enabled) != 0)
        }
    }

    private func library(_ name: String) throws -> URL {
        let directory = tools.directory.appendingPathComponent(name, isDirectory: true)
        try RootedFileStore(root: directory).createRoot()
        return directory
    }

    private func visibleWindows() -> [GTK.Widget] {
        var windows: [GTK.Widget] = []
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data {
                let widget = mp_window_widget(data.assumingMemoryBound(to: GtkWindow.self))!
                if gtk_widget_get_visible(widget) != 0 { windows.append(widget) }
            }
            node = current.pointee.next
        }
        return windows
    }

    private func title(of widget: GTK.Widget) -> String? {
        gtk_window_get_title(mp_window(widget)).map { String(cString: $0) }
    }

    private func visibleWindow(titled title: String) throws -> GTK.Widget {
        XCTAssertTrue(GTKTestSupport.spin { self.visibleWindows().contains { self.title(of: $0) == title } })
        return try XCTUnwrap(visibleWindows().first { self.title(of: $0) == title })
    }

    private func drain() {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        _ = GTKTestSupport.spin { ContinuousClock.now >= deadline }
    }
}

private final class TrayNotifications: LibraryAvailabilityNotifier {
    func libraryUnavailable() {}
}

private final class TrayScheduler: Scheduler {
    private(set) var delays: [Duration] = []
    private var pending: [() -> Void] = []

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        pending.append(work)
    }

    func fireAll() {
        let callbacks = pending
        pending = []
        callbacks.forEach { $0() }
    }
}
#endif
