#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class KGlobalAccelHotkeyTests: XCTestCase {
    private var service: FakeKGlobalAccel!
    private var backend: KGlobalAccelHotkeyBackend!
    private var fires = 0
    private var address = ""

    override func setUpWithError() throws {
        address = try FakePortal.requirePrivateBus()
        service = try FakeKGlobalAccel(address: address)
        try service.ownName()
    }

    override func tearDown() {
        backend?.shutdown()
        if service?.present == true, service?.hasName == true {
            XCTAssertTrue(GTKTestSupport.spin { !self.service.present })
        }
        backend = nil
        service?.shutdown()
        service = nil
    }

    private func start(budget: Duration = Limits.kglobalaccelTimeout) {
        backend = KGlobalAccelHotkeyBackend(busAddress: address, callBudget: budget)
        let registration = backend.register(.togglePicker, accelerator: Accelerator.defaultBinding(for: .togglePicker)!) { [weak self] in
            self?.fires += 1
        }
        XCTAssertEqual(registration.mechanism, .kglobalaccel)
    }

    private func ready(_ status: RegistrationStatus = .registered) {
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == status }, backend.currentRegistration.detail)
    }

    private func configure() {
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
    }

    /// A valid edit follows the test signals on the service connection. Its
    /// completed availability round trip proves earlier signals were dispatched.
    private func barrier() {
        let count = service.calls.filter { $0.method == "globalShortcutAvailable" }.count
        service.change(service.savedKeys)
        XCTAssertTrue(GTKTestSupport.spin {
            self.service.calls.filter { $0.method == "globalShortcutAvailable" }.count > count
                && self.backend.currentRegistration.status != .needsAction
        })
    }

    private func assertKeys(_ call: FakeKGlobalAccel.Call, _ literal: String, file: StaticString = #filePath, line: UInt = #line) {
        let value = g_variant_get_child_value(call.parameters, 1)!
        let expected = g_variant_ref_sink(FakeKGlobalAccel.variant(literal))!
        defer { g_variant_unref(value); g_variant_unref(expected) }
        XCTAssertNotEqual(g_variant_equal(UnsafeRawPointer(value), UnsafeRawPointer(expected)), 0, file: file, line: line)
    }

    func testAuthoritativeV2ShapesAndOneOwnedActionLifetime() throws {
        start()
        ready()
        let id = backend.currentRegistration.id
        let calls = service.calls
        guard calls.count == 6 else { return XCTFail("Native registration did not complete") }
        XCTAssertEqual(calls.map(\.method), ["doRegister", "getComponent", "shortcutKeys", "setShortcutKeys", "setShortcutKeys", "globalShortcutAvailable"])
        XCTAssertEqual(calls.map(\.signature), ["(as)", "(s)", "(as)", "(asa(ai)u)", "(asa(ai)u)", "((ai)s)"])
        XCTAssertEqual(Set(calls.map(\.sender)).count, 1)
        let action = g_variant_get_child_value(calls[0].parameters, 0)!
        defer { g_variant_unref(action) }
        XCTAssertEqual((0..<g_variant_n_children(action)).map { index -> String in
            let value = g_variant_get_child_value(action, index)!
            defer { g_variant_unref(value) }
            return String(cString: g_variant_get_string(value, nil))
        }, ["ch.lkmc.monkeyspaw", "toggle", "Monkey's Paw", "Open picker"])
        XCTAssertEqual(calls[1].text(0), "'ch.lkmc.monkeyspaw'")
        XCTAssertEqual(calls[3].text(2), "uint32 2")
        XCTAssertEqual(calls[4].text(2), "uint32 8")
        assertKeys(calls[3], "@a(ai) [([201326672],)]")
        assertKeys(calls[4], "@a(ai) [([201326672],)]")
        XCTAssertEqual(calls[5].text(1), "'ch.lkmc.monkeyspaw'")
        XCTAssertEqual(backend.currentRegistration.detail, "Ctrl+Alt+P")
        XCTAssertEqual(backend.currentRegistration.configuration, .systemSettings)
        let repeatRegistration = backend.register(.repeatLast, accelerator: try Accelerator("Alt+R")) { XCTFail("Repeat must stay unbound") }
        XCTAssertEqual(repeatRegistration.status, .unbound)
        backend.unregister(repeatRegistration)
        XCTAssertTrue(service.present)
        service.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        XCTAssertEqual(backend.currentRegistration.id, id)
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.service.present })
        XCTAssertEqual(service.calls.filter { $0.method == "setInactive" }.count, 1)
        XCTAssertEqual(service.calls.last?.sender, calls[0].sender)
        XCTAssertEqual(service.calls.last?.noAutoStart, true)
        XCTAssertEqual(service.savedKeys, "@a(ai) [([201326672],)]")
        backend.shutdown()
    }

    func testSavedMultiChordAlternativesAndZerosArePreserved() {
        service.savedKeys = "@a(ai) [([67108939, 67108931, 0, 0],), ([201326672],)]"
        start()
        ready()
        assertKeys(service.calls[3], service.savedKeys)
        XCTAssertEqual(backend.currentRegistration.detail, "Ctrl+K, Ctrl+C / Ctrl+Alt+P")
        let availability = service.calls.filter { $0.method == "globalShortcutAvailable" }
        XCTAssertEqual(availability.count, 2)
        XCTAssertEqual(availability.first?.text(0), "([67108939, 67108931, 0, 0],)")
        service.change("@a(ai) [([218103812],)]") // Qt Ctrl+Alt+Return
        ready()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.detail == "Ctrl+Alt+Return" })
        XCTAssertEqual(service.calls.filter { $0.method == "doRegister" }.count, 1)
    }

    func testFreshAndDeliberatelyUnboundStayUnbound() {
        for literal in ["@a(ai) []", "@a(ai) [(@ai [],), ([0, 0, 0, 0],)]"] {
            service.savedKeys = literal
            start()
            ready(.unbound)
            let active = service.calls.last { $0.method == "setShortcutKeys" && $0.text(2) == "uint32 2" }!
            assertKeys(active, literal)
            service.emit()
            barrier()
            XCTAssertEqual(fires, 0)
            XCTAssertTrue(backend.currentRegistration.detail.contains("No shortcut assigned"))
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.service.present })
        }
    }

    func testConflictNeverStealsAndConfigurationRechecksActualKeys() {
        service.available = false
        start()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.detail.contains("conflicts") })
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        service.emit()
        configure()
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(service.calls.filter { $0.method == "doRegister" }.count, 1)
        XCTAssertEqual(service.calls.filter { $0.method == "setShortcutKeys" }.count, 2)
        XCTAssertTrue(service.calls.allSatisfy { ["doRegister", "getComponent", "shortcutKeys", "setShortcutKeys", "globalShortcutAvailable"].contains($0.method) })
        service.available = true
        configure()
        ready()
        service.change("@a(ai) []")
        ready(.unbound)
        service.available = false
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .unbound)
        XCTAssertTrue(backend.currentRegistration.detail.contains("used by another"))
        service.available = true
        service.change("@a(ai) [([67108933],)]")
        ready()
        XCTAssertEqual(backend.currentRegistration.detail, "Ctrl+E")
    }

    func testReleaseOnlyAndOwnerPathActionPayloadFiltering() throws {
        start()
        ready()
        let foreign = try FakeKGlobalAccel(address: address)
        defer { foreign.shutdown() }
        foreign.emit()
        service.emit("globalShortcutPressed")
        service.emit("globalShortcutRepeated")
        service.emit(path: "/component/ch_lkmc_monkeyspaw")
        service.emit(body: "('other.component', 'toggle', int64 7)")
        service.emit(body: "('ch.lkmc.monkeyspaw.desktop', 'toggle', int64 7)")
        service.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 7)")
        service.emit(body: "('ch.lkmc.monkeyspaw', 'toggle', uint64 7)")
        service.emit(body: "('ch.lkmc.monkeyspaw', 'toggle', int32 7)")
        service.emit(body: "('ch.lkmc.monkeyspaw', 'toggle')")
        barrier()
        XCTAssertEqual(fires, 0)
        XCTAssertFalse(backend.fire(.togglePicker))
        service.emit(body: "('ch.lkmc.monkeyspaw', 'toggle', int64 -9223372036854775808)")
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        service.emit(body: "('ch.lkmc.monkeyspaw', 'toggle', int64 9223372036854775807)")
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 2 })
    }

    func testLiveChangeFilteringAndUnbindingRemoveReadiness() {
        start()
        ready()
        let id = backend.currentRegistration.id
        service.emit("yourShortcutsChanged", body: "(['ch.lkmc.monkeyspaw', 'repeat', 'Paw', 'Repeat'], @a(ai) [])", path: "/kglobalaccel")
        service.emit("yourShortcutsChanged", body: "(['ch.lkmc.monkeyspaw', 'toggle'], @a(ai) [])", path: "/kglobalaccel")
        service.emit("yourShortcutsChanged", body: "(['ch.lkmc.monkeyspaw', 'toggle', 'Paw', 'Open'], @ai [])", path: "/kglobalaccel")
        barrier()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        service.change("@a(ai) []")
        ready(.unbound)
        service.emit()
        barrier()
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(backend.currentRegistration.id, id)
    }

    func testOwnerLossNeedsExplicitRetryAndOldOwnerCannotActivate() throws {
        start()
        ready()
        let id = backend.currentRegistration.id
        service.dropName()
        ready(.failed)
        service.emit()
        let replacement = try FakeKGlobalAccel(address: address)
        defer { replacement.shutdown() }
        try replacement.ownName()
        configure()
        ready()
        XCTAssertEqual(backend.currentRegistration.id, id)
        XCTAssertEqual(service.calls.filter { $0.method == "setInactive" }.count, 0)
        service.emit()
        replacement.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !replacement.present })
        XCTAssertEqual(replacement.calls.filter { $0.method == "setInactive" }.count, 1)
    }

    func testDeadlineRetryAndLateRepliesCompleteExactlyOnce() {
        service.heldMethods = ["getComponent"]
        start(budget: .milliseconds(100))
        var completions = 0
        backend.configure { completions += 1 }
        backend.configure { completions += 1 }
        ready(.failed)
        XCTAssertEqual(completions, 2)
        let late = service.calls.first { $0.method == "getComponent" }!
        service.heldMethods.removeAll()
        configure()
        ready()
        service.reply(late)
        barrier()
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(service.calls.filter { $0.method == "setShortcutKeys" }.count, 2)
        service.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
    }

    func testLiveEditsWinOverStaleReadsAndConflictProbes() throws {
        start()
        ready()
        service.heldMethods = ["shortcutKeys"]
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.service.calls.last?.method == "shortcutKeys" })
        let read = try XCTUnwrap(service.calls.last)
        service.change("@a(ai) []")
        service.reply(read, body: "(@a(ai) [([201326672],)],)")
        ready(.unbound)
        XCTAssertEqual(completions, 1)
        service.heldMethods = ["globalShortcutAvailable"]
        service.change("@a(ai) [([67108931],)]")
        XCTAssertTrue(GTKTestSupport.spin { self.service.calls.last?.method == "globalShortcutAvailable" && self.backend.currentRegistration.status == .needsAction })
        let probe = try XCTUnwrap(service.calls.last)
        service.change("@a(ai) []")
        service.heldMethods.removeAll()
        service.reply(probe, body: "(false,)")
        ready(.unbound)
        XCTAssertFalse(backend.currentRegistration.detail.contains("used by another"))
        XCTAssertEqual(completions, 1)
    }

    func testOwnerLossDuringRegistrationPreventsLateActivation() throws {
        service.heldMethods = ["getComponent"]
        start()
        XCTAssertTrue(GTKTestSupport.spin { self.service.calls.last?.method == "getComponent" })
        let late = try XCTUnwrap(service.calls.last)
        var completions = 0
        backend.configure { completions += 1 }
        service.dropName()
        ready(.failed)
        XCTAssertEqual(completions, 1)
        service.reply(late)
        let replacement = try FakeKGlobalAccel(address: address)
        defer { replacement.shutdown() }
        try replacement.ownName()
        configure()
        ready()
        XCTAssertEqual(service.calls.filter { $0.method == "setShortcutKeys" }.count, 0)
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !replacement.present })
        XCTAssertEqual(completions, 1)
    }

    func testMissingDaemonRetryAndExpiredStartOwnNoAction() throws {
        service.dropName()
        start()
        ready(.failed)
        backend.shutdown()
        XCTAssertTrue(service.calls.isEmpty)
        try service.ownName()
        start(budget: .zero)
        ready(.failed)
        backend.shutdown()
        XCTAssertTrue(service.calls.isEmpty)
        start()
        ready()
    }

    func testShutdownWhileActivationReplyPendingCannotReactivate() {
        service.heldMethods = ["setShortcutKeys"]
        start()
        XCTAssertTrue(GTKTestSupport.spin { self.service.present })
        var completions = 0
        backend.configure { completions += 1 }
        let late = service.calls.first { $0.method == "setShortcutKeys" }!
        backend.shutdown()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(GTKTestSupport.spin { !self.service.present })
        service.reply(late)
        service.emit()
        XCTAssertEqual(service.calls.filter { $0.method == "setShortcutKeys" }.count, 1)
        XCTAssertEqual(service.calls.filter { $0.method == "setInactive" }.count, 1)
        XCTAssertEqual(fires, 0)
        backend.configure { completions += 1 }
        XCTAssertEqual(completions, 2)
    }

    func testBusLossAndShutdownBeforeConnectAreSafe() throws {
        let daemon = try PrivatePortalDaemon()
        let isolated = try FakeKGlobalAccel(address: daemon.address)
        defer { isolated.shutdown(); daemon.stop() }
        try isolated.ownName()
        address = daemon.address
        start()
        ready()
        daemon.stop()
        ready(.failed)
        backend.shutdown()
        backend = KGlobalAccelHotkeyBackend(busAddress: address)
        _ = backend.register(.togglePicker, accelerator: Accelerator.defaultBinding(for: .togglePicker)!) { XCTFail("Late release") }
        backend.shutdown()
        var done = 0
        backend.configure { done += 1 }
        XCTAssertEqual(done, 1)
    }

    func testMalformedAndOversizedAssignmentsFailBoundedly() {
        for literal in ["@a(ai) [([1, 2, 3, 4, 5],)]",
                        "@a(ai) [" + Array(repeating: "([1],)", count: 17).joined(separator: ",") + "]"] {
            service.savedKeys = literal
            start()
            ready(.failed)
            XCTAssertFalse(service.present)
            backend.shutdown()
        }
    }

    func testWrongReplyTypesAndOversizedPayloadAreRejected() {
        for (method, reply) in [("getComponent", "('not-an-object-path',)"), ("shortcutKeys", "(@ai [1],)"),
                                ("shortcutKeys", "(@a(ai) [" + Array(repeating: "([1],)", count: 14_000).joined(separator: ",") + "],)")] {
            service.rawReplies = [method: reply]
            start()
            ready(.failed)
            XCTAssertEqual(service.calls.filter { $0.method == "setShortcutKeys" }.count, 0)
            backend.shutdown()
        }
    }

    func testSharedConnectionIsRetainedButNotClosed() {
        final class Result { var connection: OpaquePointer?; var done = false }
        let result = Result()
        g_bus_get(G_BUS_TYPE_SESSION, nil, { _, reply, data in
            guard let reply, let data else { return }
            let result = Unmanaged<Result>.fromOpaque(data).takeRetainedValue()
            result.connection = g_bus_get_finish(reply, nil)
            result.done = true
        }, Unmanaged.passRetained(result).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { result.done })
        guard let shared = result.connection else { return XCTFail("Missing shared bus") }
        defer { g_object_unref(UnsafeMutableRawPointer(shared)) }
        backend = KGlobalAccelHotkeyBackend(busAddress: nil)
        _ = backend.register(.togglePicker, accelerator: Accelerator.defaultBinding(for: .togglePicker)!) { [weak self] in self?.fires += 1 }
        ready()
        XCTAssertEqual(service.calls.first?.sender, String(cString: g_dbus_connection_get_unique_name(shared)))
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.service.present })
        XCTAssertEqual(g_dbus_connection_is_closed(shared), 0)
        service.emit()
        // A bus round trip drains cancellation/late signal work on GLib.
        g_dbus_connection_flush(shared, nil, { source, reply, data in
            guard let source, let reply, let data else { return }
            _ = g_dbus_connection_flush_finish(mp_dbus_connection(source), reply, nil)
            Unmanaged<Result>.fromOpaque(data).takeRetainedValue().done = true
        }, Unmanaged.passRetained(result).toOpaque())
        result.done = false
        XCTAssertTrue(GTKTestSupport.spin { result.done })
        XCTAssertEqual(fires, 0)
    }

    func testQtTranslationUsesCombinedKeys() throws {
        for (text, expected): (String, Int32) in [("Ctrl+Alt+P", 0x0c000050), ("Super+Shift+F24", 0x13000047),
                                                ("CmdOrCtrl+Return", 0x05000004), ("Alt+Plus", 0x0800002b)] {
            XCTAssertEqual(KGlobalAccelWire.translate(try Accelerator(text)).sequences, [[expected]])
        }
    }
}
#endif
