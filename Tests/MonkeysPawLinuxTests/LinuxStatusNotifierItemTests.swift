#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class LinuxStatusNotifierItemTests: XCTestCase {
    private var address: String!
    private var watcher: FakeStatusNotifierWatcher!
    private var item: LinuxStatusNotifierItem!
    private var activated: [Int32] = []
    private var availability: [Bool] = []
    private var toggles = 0

    override func setUpWithError() throws {
        address = try FakePortal.requirePrivateBus()
        watcher = try FakeStatusNotifierWatcher(address: address)
        item = makeItem(address: address)
        item.setEntries([
            entry(1, "Show picker"), entry(2, "Settings…"), entry(3, "Setup…"),
            entry(4, "Library unavailable", enabled: false), entry(5, "Quit"),
        ])
    }

    override func tearDown() {
        item?.stop()
        item = nil
        watcher?.shutdown()
        watcher = nil
        drain()
    }

    private func makeItem(address: String?) -> LinuxStatusNotifierItem {
        let item = LinuxStatusNotifierItem(busAddress: address) { [weak self] in
            self?.assertMainLoop()
            self?.toggles += 1
        }
        item.onAvailabilityChange = { [weak self] available in
            self?.assertMainLoop()
            self?.availability.append(available)
        }
        return item
    }

    private func entry(_ id: Int32, _ label: String, enabled: Bool = true) -> StatusNotifierEntry {
        StatusNotifierEntry(id: id, label: label, enabled: enabled) { [weak self] in
            self?.assertMainLoop()
            self?.activated.append(id)
        }
    }

    private func assertMainLoop(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Thread.isMainThread, file: file, line: line)
        XCTAssertNotEqual(g_main_context_is_owner(g_main_context_default()), 0, file: file, line: line)
    }

    private func drain(_ duration: Duration = .milliseconds(40)) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        _ = GTKTestSupport.spin { ContinuousClock.now >= deadline }
    }

    private func start() throws {
        try watcher.ownName()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.item.isAvailable && self.availability == [true] })
        XCTAssertEqual(watcher.registrations.count, 1)
    }

    private func value(_ result: FakeStatusNotifierWatcher.Reply) throws -> OpaquePointer {
        XCTAssertFalse(result.failed)
        return try XCTUnwrap(result.value)
    }

    private func child(_ parent: OpaquePointer, _ index: UInt) -> OpaquePointer {
        g_variant_get_child_value(parent, index)!
    }

    private func string(_ parent: OpaquePointer, _ index: UInt) -> String {
        let value = child(parent, index)
        defer { g_variant_unref(value) }
        return String(cString: g_variant_get_string(value, nil))
    }

    private struct Row: Equatable {
        let id: Int32
        let label: String
        let enabled: Bool
    }

    private func rows(_ reply: OpaquePointer) throws -> [Row] {
        XCTAssertEqual(String(cString: g_variant_get_type_string(reply)), "(u(ia{sv}av))")
        let root = child(reply, 1)
        let id = child(root, 0)
        let children = child(root, 2)
        defer { g_variant_unref(root); g_variant_unref(id); g_variant_unref(children) }
        XCTAssertEqual(g_variant_get_int32(id), 0)
        return try (0..<g_variant_n_children(children)).map { index in
            let wrapper = child(children, index)
            let row = g_variant_get_variant(wrapper)!
            let id = child(row, 0)
            let properties = child(row, 1)
            defer { g_variant_unref(wrapper); g_variant_unref(row); g_variant_unref(id); g_variant_unref(properties) }
            let label = try XCTUnwrap(g_variant_lookup_value(properties, "label", nil))
            let enabled = try XCTUnwrap(g_variant_lookup_value(properties, "enabled", nil))
            defer { g_variant_unref(label); g_variant_unref(enabled) }
            return Row(id: g_variant_get_int32(id), label: String(cString: g_variant_get_string(label, nil)),
                       enabled: g_variant_get_boolean(enabled) != 0)
        }
    }

    func testRegistersOnlyOnceWithExistingWatcher() throws {
        try start()
        item.start()
        drain()
        let registration = try XCTUnwrap(watcher.registrations.first)
        XCTAssertTrue(registration.sender.hasPrefix(":"))
        XCTAssertEqual(registration.service, FakeStatusNotifierWatcher.itemName)
        XCTAssertTrue(registration.noAutoStart)
        XCTAssertEqual(watcher.registrations.count, 1)
    }

    func testAbsentWatcherStaysUnavailableAndRegistersWhenItAppears() throws {
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.hasOwner(FakeStatusNotifierWatcher.itemName) })
        drain()
        XCTAssertFalse(item.isAvailable)
        XCTAssertTrue(availability.isEmpty)
        XCTAssertTrue(watcher.registrations.isEmpty)
        XCTAssertFalse(watcher.hasOwner("org.kde.StatusNotifierWatcher"))
        try watcher.ownName()
        XCTAssertTrue(GTKTestSupport.spin { self.item.isAvailable && self.availability == [true] })
        XCTAssertEqual(watcher.registrations.count, 1)
    }

    func testWatcherRestartRegistersWithNewOwner() throws {
        try start()
        watcher.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.availability == [true, false] })
        XCTAssertFalse(item.isAvailable)
        watcher = try FakeStatusNotifierWatcher(address: address)
        try watcher.ownName()
        XCTAssertTrue(GTKTestSupport.spin { self.availability == [true, false, true] })
        XCTAssertEqual(watcher.registrations.map(\.service), [FakeStatusNotifierWatcher.itemName])
    }

    func testAvailabilityRequiresSuccessfulRegistration() throws {
        watcher.holdRegistration = true
        try watcher.ownName()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.count == 1 })
        XCTAssertFalse(item.isAvailable)
        watcher.releaseRegistrations()
        XCTAssertTrue(GTKTestSupport.spin { self.item.isAvailable })
    }

    func testRejectedRegistrationDoesNotClaimAvailability() throws {
        watcher.rejectRegistration = true
        try watcher.ownName()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.count == 1 })
        drain()
        XCTAssertFalse(item.isAvailable)
        XCTAssertTrue(availability.isEmpty)
    }

    func testLateOldWatcherReplyCannotRestoreAvailability() throws {
        watcher.holdRegistration = true
        try watcher.ownName()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.count == 1 })
        watcher.dropName()
        XCTAssertTrue(GTKTestSupport.spin { !self.watcher.hasOwner("org.kde.StatusNotifierWatcher") })
        drain()
        watcher.releaseRegistrations()
        drain()
        XCTAssertFalse(item.isAvailable)
        watcher.holdRegistration = false
        try watcher.ownName()
        XCTAssertTrue(GTKTestSupport.spin { self.item.isAvailable })
        XCTAssertEqual(watcher.registrations.count, 2)
    }

    func testPropertiesHaveInstalledIdentityIconAndMenu() throws {
        try start()
        let reply = watcher.call(path: "/StatusNotifierItem", interface: "org.freedesktop.DBus.Properties",
                                 method: "GetAll", body: "('org.kde.StatusNotifierItem',)")
        let properties = child(try value(reply), 0)
        defer { g_variant_unref(properties) }
        for (key, expected) in [("Category", "ApplicationStatus"), ("Id", "ch.lkmc.monkeyspaw"),
                                ("Title", "Monkey's Paw"), ("Status", "Active"),
                                ("IconName", "ch.lkmc.monkeyspaw"), ("Menu", "/Menu")] {
            let property = try XCTUnwrap(g_variant_lookup_value(properties, key, nil))
            defer { g_variant_unref(property) }
            XCTAssertEqual(String(cString: g_variant_get_string(property, nil)), expected)
        }
        let isMenu = try XCTUnwrap(g_variant_lookup_value(properties, "ItemIsMenu", nil))
        let tooltip = try XCTUnwrap(g_variant_lookup_value(properties, "ToolTip", nil))
        defer { g_variant_unref(isMenu); g_variant_unref(tooltip) }
        XCTAssertNotEqual(g_variant_get_boolean(isMenu), 0)
        XCTAssertEqual(String(cString: g_variant_get_type_string(tooltip)), "(sa(iiay)ss)")
        XCTAssertEqual(string(tooltip, 0), "ch.lkmc.monkeyspaw")
        XCTAssertEqual(string(tooltip, 2), "Monkey's Paw")
    }

    func testLayoutContainsOrderedEntriesAndDisabledStatus() throws {
        try start()
        let reply = watcher.call(method: "GetLayout", body: "(0, -1, @as [])")
        XCTAssertEqual(try rows(value(reply)), [
            Row(id: 1, label: "Show picker", enabled: true), Row(id: 2, label: "Settings…", enabled: true),
            Row(id: 3, label: "Setup…", enabled: true), Row(id: 4, label: "Library unavailable", enabled: false),
            Row(id: 5, label: "Quit", enabled: true),
        ])
        let about = watcher.call(method: "AboutToShow", body: "(0,)")
        let update = child(try value(about), 0)
        defer { g_variant_unref(update) }
        XCTAssertEqual(g_variant_get_boolean(update), 0)
    }

    func testLayoutHonorsDepthParentAndPropertyFilter() throws {
        try start()
        let shallow = watcher.call(method: "GetLayout", body: "(0, 0, @as [])")
        XCTAssertTrue(try rows(value(shallow)).isEmpty)
        let leaf = watcher.call(method: "GetLayout", body: "(2, -1, ['label'])")
        let layout = child(try value(leaf), 1)
        let properties = child(layout, 1)
        let children = child(layout, 2)
        defer { g_variant_unref(layout); g_variant_unref(properties); g_variant_unref(children) }
        XCTAssertEqual(g_variant_n_children(properties), 1)
        XCTAssertEqual(g_variant_n_children(children), 0)
        let label = try XCTUnwrap(g_variant_lookup_value(properties, "label", nil))
        defer { g_variant_unref(label) }
        XCTAssertEqual(String(cString: g_variant_get_string(label, nil)), "Settings…")
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(999, -1, @as [])").failed)
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(0, -2, @as [])").failed)
    }

    func testGroupPropertiesFiltersNamesAndSkipsUnknownIDs() throws {
        try start()
        let reply = watcher.call(method: "GetGroupProperties", body: "([2, 4, 999], ['enabled'])")
        let groups = child(try value(reply), 0)
        defer { g_variant_unref(groups) }
        XCTAssertEqual(String(cString: g_variant_get_type_string(groups)), "a(ia{sv})")
        XCTAssertEqual(g_variant_n_children(groups), 2)
        for (index, expected) in [(UInt(0), true), (UInt(1), false)] {
            let row = child(groups, index)
            let properties = child(row, 1)
            defer { g_variant_unref(row); g_variant_unref(properties) }
            XCTAssertEqual(g_variant_n_children(properties), 1)
            let enabled = try XCTUnwrap(g_variant_lookup_value(properties, "enabled", nil))
            defer { g_variant_unref(enabled) }
            XCTAssertEqual(g_variant_get_boolean(enabled) != 0, expected)
        }
    }

    func testClickedEventInvokesOnlyEnabledMatchingAction() throws {
        try start()
        XCTAssertFalse(watcher.call(method: "Event", body: "(2, 'clicked', <0>, uint32 0)").failed)
        XCTAssertTrue(GTKTestSupport.spin { self.activated == [2] })
        XCTAssertFalse(watcher.call(method: "Event", body: "(4, 'clicked', <0>, uint32 0)").failed)
        XCTAssertFalse(watcher.call(method: "Event", body: "(3, 'hovered', <0>, uint32 0)").failed)
        XCTAssertTrue(watcher.call(method: "Event", body: "(999, 'clicked', <0>, uint32 0)").failed)
        drain()
        XCTAssertEqual(activated, [2])
        XCTAssertEqual(toggles, 0)
    }

    func testSetEntriesUpdatesLayoutAndEmitsBothSignals() throws {
        try start()
        let initial = watcher.call(method: "GetLayout", body: "(0, -1, @as [])")
        let oldRevision = child(try value(initial), 0)
        defer { g_variant_unref(oldRevision) }
        item.setEntries([entry(1, "Picker's \\ menu\n日本語"), entry(2, "Settings…", enabled: false), entry(6, "Quit")])
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.signals.count == 2 })
        let signal = try XCTUnwrap(watcher.signals.first { $0.name == "LayoutUpdated" })
        XCTAssertEqual(String(cString: g_variant_get_type_string(signal.value)), "(ui)")
        let signaledRevision = child(signal.value, 0)
        let parent = child(signal.value, 1)
        defer { g_variant_unref(signaledRevision); g_variant_unref(parent) }
        XCTAssertEqual(g_variant_get_int32(parent), 0)
        XCTAssertEqual(g_variant_get_uint32(signaledRevision), g_variant_get_uint32(oldRevision) + 1)
        let updated = watcher.call(method: "GetLayout", body: "(0, -1, @as [])")
        XCTAssertEqual(try rows(value(updated)), [Row(id: 1, label: "Picker's \\ menu\n日本語", enabled: true),
            Row(id: 2, label: "Settings…", enabled: false), Row(id: 6, label: "Quit", enabled: true)])
        let updatedRevision = child(try value(updated), 0)
        defer { g_variant_unref(updatedRevision) }
        XCTAssertEqual(g_variant_get_uint32(updatedRevision), g_variant_get_uint32(signaledRevision))
        let propertiesSignal = try XCTUnwrap(watcher.signals.first { $0.name == "ItemsPropertiesUpdated" })
        XCTAssertEqual(String(cString: g_variant_get_type_string(propertiesSignal.value)), "(a(ia{sv})a(ias))")
        let changed = child(propertiesSignal.value, 0)
        let removed = child(propertiesSignal.value, 1)
        defer { g_variant_unref(changed); g_variant_unref(removed) }
        XCTAssertEqual(g_variant_n_children(changed), 2)
        XCTAssertEqual(g_variant_n_children(removed), 0)
        let settings = child(changed, 1)
        let settingsID = child(settings, 0)
        let settingsProperties = child(settings, 1)
        defer { g_variant_unref(settings); g_variant_unref(settingsID); g_variant_unref(settingsProperties) }
        XCTAssertEqual(g_variant_get_int32(settingsID), 2)
        let enabled = try XCTUnwrap(g_variant_lookup_value(settingsProperties, "enabled", nil))
        defer { g_variant_unref(enabled) }
        XCTAssertEqual(g_variant_get_boolean(enabled), 0)
        XCTAssertFalse(watcher.call(method: "Event", body: "(2, 'clicked', <0>, uint32 0)").failed)
        XCTAssertTrue(watcher.call(method: "Event", body: "(5, 'clicked', <0>, uint32 0)").failed)
        drain()
        XCTAssertTrue(activated.isEmpty)
    }

    func testActivateCallsToggleOnMainLoop() throws {
        try start()
        let reply = watcher.call(path: "/StatusNotifierItem", interface: "org.kde.StatusNotifierItem",
                                 method: "Activate", body: "(100, 200)")
        XCTAssertFalse(reply.failed)
        XCTAssertTrue(GTKTestSupport.spin { self.toggles == 1 })
        XCTAssertTrue(activated.isEmpty)
    }

    func testStopUnexportsReleasesNameAndStopsWatching() throws {
        try start()
        item.activate()
        item.stop()
        item.stop()
        XCTAssertFalse(item.isAvailable)
        XCTAssertTrue(GTKTestSupport.spin { !self.watcher.hasOwner(FakeStatusNotifierWatcher.itemName) })
        let sender = try XCTUnwrap(watcher.registrations.first?.sender)
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(0, -1, @as [])", destination: sender).failed)
        watcher.dropName()
        drain()
        try watcher.ownName()
        drain()
        XCTAssertEqual(watcher.registrations.count, 1)
        XCTAssertEqual(availability, [true, false])
        XCTAssertEqual(toggles, 0)
    }

    func testStopWhileConnectingAndRestartIgnoresRetiredAttempt() throws {
        try watcher.ownName()
        item.start()
        item.stop()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.item.isAvailable })
        XCTAssertEqual(watcher.registrations.count, 1)
    }

    func testStopWhileRegisteringIgnoresLateReply() throws {
        watcher.holdRegistration = true
        try watcher.ownName()
        item.start()
        XCTAssertTrue(GTKTestSupport.spin { self.watcher.registrations.count == 1 })
        item.stop()
        watcher.releaseRegistrations()
        drain()
        XCTAssertFalse(item.isAvailable)
        XCTAssertTrue(availability.isEmpty)
    }

    func testSharedConnectionFallbackReleasesItemWithoutClosingBus() throws {
        // GIO caches a weak reference. Hold GTK's peer ownership explicitly;
        // with no other consumer the last unref may legitimately close the bus.
        let shared = try XCTUnwrap(g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil))
        defer { g_object_unref(UnsafeMutableRawPointer(shared)) }
        item = makeItem(address: nil)
        try start()
        let sender = try XCTUnwrap(watcher.registrations.first?.sender)
        item.stop()
        XCTAssertTrue(GTKTestSupport.spin { !self.watcher.hasOwner(FakeStatusNotifierWatcher.itemName) })
        XCTAssertTrue(watcher.hasOwner(sender), "The shared GIO connection must remain open.")
        let reply = watcher.call(path: "/StatusNotifierItem", interface: "org.kde.StatusNotifierItem",
                                 method: "Activate", body: "(0, 0)", destination: sender)
        XCTAssertTrue(reply.failed)
        XCTAssertTrue(watcher.call(method: "GetLayout", body: "(0, -1, @as [])", destination: sender).failed)
    }

    func testStopWithQueuedPropertyReadsReturnsErrorsWithoutWarnings() throws {
        let shared = try XCTUnwrap(g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil))
        defer { g_object_unref(UnsafeMutableRawPointer(shared)) }
        item = makeItem(address: nil)
        try start()
        let itemProperty = watcher.send(path: "/StatusNotifierItem", interface: "org.freedesktop.DBus.Properties",
                                        method: "Get", body: "('org.kde.StatusNotifierItem', 'Title')")
        let menuProperty = watcher.send(interface: "org.freedesktop.DBus.Properties", method: "Get",
                                        body: "('com.canonical.dbusmenu', 'Version')")
        // Let GIO's worker queue incoming reads without dispatching the UI loop.
        Thread.sleep(forTimeInterval: 0.05)
        item.stop()
        XCTAssertTrue(GTKTestSupport.spin { itemProperty.done && menuProperty.done })
        XCTAssertTrue(itemProperty.failed)
        XCTAssertTrue(menuProperty.failed)
        XCTAssertEqual(toggles, 0)
    }

    func testBusLossClearsAvailabilityAndAllowsCleanStop() throws {
        let daemon = try PrivatePortalDaemon()
        defer { daemon.stop() }
        watcher.shutdown()
        watcher = try FakeStatusNotifierWatcher(address: daemon.address)
        item = makeItem(address: daemon.address)
        try start()

        daemon.stop()
        XCTAssertTrue(GTKTestSupport.spin { self.availability == [true, false] })
        XCTAssertFalse(item.isAvailable)
        item.stop()
        watcher.shutdown()
        drain()
        XCTAssertEqual(availability, [true, false])
    }
}
#endif
