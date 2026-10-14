#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

/// A separate private-bus connection, with literal watcher XML and independent
/// menu decoding. It doubles as the host that reads and clicks the exported item.
final class FakeStatusNotifierWatcher {
    final class Reply {
        var value: OpaquePointer?
        var failed = false
        var done = false
        deinit { if let value { g_variant_unref(value) } }
    }

    struct Registration {
        let sender: String
        let service: String
        let noAutoStart: Bool
    }

    final class Signal {
        let name: String
        let value: OpaquePointer
        init(name: String, value: OpaquePointer) {
            self.name = name
            self.value = g_variant_ref(value)!
        }
        deinit { g_variant_unref(value) }
    }

    private final class Box {
        weak var owner: FakeStatusNotifierWatcher?
        init(_ owner: FakeStatusNotifierWatcher) { self.owner = owner }
    }

    private final class ConnectionReply {
        var connection: OpaquePointer?
        var done = false
    }

    static let itemName = "ch.lkmc.monkeyspaw.StatusNotifierItem-\(ProcessInfo.processInfo.processIdentifier)-1"
    private(set) var registrations: [Registration] = []
    private(set) var signals: [Signal] = []
    private(set) var hasName = false
    var holdRegistration = false
    var rejectRegistration = false
    private var held: [OpaquePointer] = []
    private var connection: OpaquePointer?
    private var exportID: guint = 0
    private var nameOwner: guint = 0
    private var subscription: guint = 0

    init(address: String) throws {
        let result = ConnectionReply()
        let flags = GDBusConnectionFlags(rawValue:
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        g_dbus_connection_new_for_address(address, flags, nil, nil, { _, reply, data in
            guard let reply, let data else { return }
            let result = Unmanaged<ConnectionReply>.fromOpaque(data).takeRetainedValue()
            result.connection = g_dbus_connection_new_for_address_finish(reply, nil)
            result.done = true
        }, Unmanaged.passRetained(result).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { result.done })
        connection = try XCTUnwrap(result.connection)
        g_dbus_connection_set_exit_on_close(connection, 0)
        let node = try XCTUnwrap(g_dbus_node_info_new_for_xml("""
            <node><interface name='org.kde.StatusNotifierWatcher'>
              <method name='RegisterStatusNotifierItem'><arg type='s' direction='in'/></method>
            </interface></node>
            """, nil))
        defer { g_dbus_node_info_unref(node) }
        var table = GDBusInterfaceVTable()
        table.method_call = { _, sender, _, _, _, parameters, invocation, data in
            guard let sender, let parameters, let invocation, let data,
                  let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().owner else { return }
            let service = g_variant_get_child_value(parameters, 0)!
            defer { g_variant_unref(service) }
            let flags = g_dbus_message_get_flags(g_dbus_method_invocation_get_message(invocation))
            owner.registrations.append(Registration(sender: String(cString: sender),
                service: String(cString: g_variant_get_string(service, nil)),
                noAutoStart: flags.rawValue & G_DBUS_MESSAGE_FLAGS_NO_AUTO_START.rawValue != 0))
            if owner.holdRegistration {
                owner.held.append(invocation)
            } else if owner.rejectRegistration {
                g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", "Fixture rejection")
            } else {
                g_dbus_method_invocation_return_value(invocation, nil)
            }
        }
        exportID = g_dbus_connection_register_object(connection, "/StatusNotifierWatcher",
            g_dbus_node_info_lookup_interface(node, "org.kde.StatusNotifierWatcher"), &table,
            Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox, nil)
        XCTAssertNotEqual(exportID, 0)
        subscription = g_dbus_connection_signal_subscribe(connection, nil, "com.canonical.dbusmenu", nil,
            "/Menu", nil, G_DBUS_SIGNAL_FLAGS_NONE, { _, _, _, _, name, value, data in
                guard let name, let value, let data else { return }
                Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().owner?.signals.append(
                    Signal(name: String(cString: name), value: value))
            }, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox)
    }

    deinit { shutdown() }

    func ownName() throws {
        nameOwner = g_bus_own_name_on_connection(connection, "org.kde.StatusNotifierWatcher",
            G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, { _, _, data in
                if let data { Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().owner?.hasName = true }
            }, nil, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox)
        XCTAssertTrue(GTKTestSupport.spin { self.hasName })
        guard hasName else { throw NSError(domain: "FakeStatusNotifierWatcher", code: 1) }
    }

    func dropName() {
        if nameOwner != 0 { g_bus_unown_name(nameOwner); nameOwner = 0 }
        hasName = false
    }

    func releaseRegistrations() {
        let invocations = held
        held.removeAll()
        for invocation in invocations { g_dbus_method_invocation_return_value(invocation, nil) }
    }

    func shutdown() {
        guard let connection else { return }
        dropName()
        releaseRegistrations()
        if subscription != 0 { g_dbus_connection_signal_unsubscribe(connection, subscription); subscription = 0 }
        if exportID != 0 { g_dbus_connection_unregister_object(connection, exportID); exportID = 0 }
        g_dbus_connection_close(connection, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(connection))
        self.connection = nil
        signals.removeAll()
    }

    func call(path: String = "/Menu", interface: String = "com.canonical.dbusmenu", method: String,
              body: String, destination: String = itemName) -> Reply {
        let result = send(path: path, interface: interface, method: method, body: body, destination: destination)
        XCTAssertTrue(GTKTestSupport.spin { result.done }, "Tray method call did not complete.")
        return result
    }

    func send(path: String = "/Menu", interface: String = "com.canonical.dbusmenu", method: String,
              body: String, destination: String = itemName) -> Reply {
        let result = Reply()
        let parameters = Self.variant(body)
        // parse returns a non-floating ref; call retains its own copy.
        defer { g_variant_unref(parameters) }
        g_dbus_connection_call(connection, destination, path, interface, method, parameters, nil,
            G_DBUS_CALL_FLAGS_NO_AUTO_START, 1_000, nil, { source, reply, data in
                guard let source, let reply, let data else { return }
                let result = Unmanaged<Reply>.fromOpaque(data).takeRetainedValue()
                result.value = g_dbus_connection_call_finish(mp_dbus_connection(source), reply, nil)
                result.failed = result.value == nil
                result.done = true
            }, Unmanaged.passRetained(result).toOpaque())
        return result
    }

    func hasOwner(_ name: String) -> Bool {
        let result = call(path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", method: "NameHasOwner",
                          body: "('\(name)',)", destination: "org.freedesktop.DBus")
        guard let value = result.value else { return false }
        let child = g_variant_get_child_value(value, 0)!
        defer { g_variant_unref(child) }
        return g_variant_get_boolean(child) != 0
    }

    func namesOwned(by peer: String) throws -> Set<String> {
        let result = call(path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", method: "ListNames",
                          body: "()", destination: "org.freedesktop.DBus")
        let names = g_variant_get_child_value(try XCTUnwrap(result.value), 0)!
        defer { g_variant_unref(names) }
        var owned: Set<String> = []
        for index in 0..<g_variant_n_children(names) {
            let name = g_variant_get_child_value(names, index)!
            defer { g_variant_unref(name) }
            let spelling = String(cString: g_variant_get_string(name, nil))
            let reply = call(path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", method: "GetNameOwner",
                             body: "('\(spelling)',)", destination: "org.freedesktop.DBus")
            let owner = g_variant_get_child_value(try XCTUnwrap(reply.value), 0)!
            defer { g_variant_unref(owner) }
            if String(cString: g_variant_get_string(owner, nil)) == peer { owned.insert(spelling) }
        }
        return owned
    }

    static func variant(_ text: String) -> OpaquePointer {
        // Fixed fixture literals only. Native error bodies never enter logs.
        g_variant_parse(nil, text, nil, nil, nil)!
    }

    private static let releaseBox: GDestroyNotify = { data in
        if let data { Unmanaged<Box>.fromOpaque(data).release() }
    }
}
#endif
