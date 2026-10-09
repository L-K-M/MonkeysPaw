#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

/// A real service on a separate private-bus connection. Replies are literal
/// fixtures, independent of the production sequence encoder and policy.
final class FakeKGlobalAccel {
    final class Call {
        let sender: String
        let method: String
        let parameters: OpaquePointer
        let noAutoStart: Bool
        var invocation: OpaquePointer?

        init(sender: String, method: String, parameters: OpaquePointer, invocation: OpaquePointer) {
            self.sender = sender
            self.method = method
            self.parameters = g_variant_ref(parameters)!
            noAutoStart = g_dbus_message_get_flags(g_dbus_method_invocation_get_message(invocation)).rawValue
                & G_DBUS_MESSAGE_FLAGS_NO_AUTO_START.rawValue != 0
            self.invocation = invocation
        }

        deinit {
            g_variant_unref(parameters)
            if let invocation { g_object_unref(UnsafeMutableRawPointer(invocation)) }
        }

        var signature: String { String(cString: g_variant_get_type_string(parameters)) }

        func text(_ index: Int) -> String {
            let value = g_variant_get_child_value(parameters, UInt(index))!
            defer { g_variant_unref(value) }
            let raw = g_variant_print(value, 1)!
            defer { g_free(raw) }
            return String(cString: raw)
        }
    }

    private final class Box {
        weak var service: FakeKGlobalAccel?
        init(_ service: FakeKGlobalAccel) { self.service = service }
    }

    static let busName = "org.kde.kglobalaccel"
    static let componentPath = "/component/fixture_returned_path_42"
    var savedKeys = "@a(ai) [([201326672],)]" // Qt Ctrl+Alt+P
    var available = true
    var heldMethods: Set<String> = []
    var replies: [String: String] = [:]
    var rawReplies: [String: String] = [:]
    var errors: Set<String> = []
    private(set) var calls: [Call] = []
    private(set) var present = false
    private(set) var registered = false
    private(set) var hasName = false
    private var connection: OpaquePointer?
    private var node: UnsafeMutablePointer<GDBusNodeInfo>?
    private var registrations: [guint] = []
    private var name: guint = 0

    init(address: String) throws {
        final class Result { var connection: OpaquePointer?; var done = false }
        let result = Result()
        let flags = GDBusConnectionFlags(rawValue:
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        g_dbus_connection_new_for_address(address, flags, nil, nil, { _, reply, data in
            guard let reply, let data else { return }
            let result = Unmanaged<Result>.fromOpaque(data).takeRetainedValue()
            result.connection = g_dbus_connection_new_for_address_finish(reply, nil)
            result.done = true
        }, Unmanaged.passRetained(result).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { result.done })
        connection = try XCTUnwrap(result.connection)
        g_dbus_connection_set_exit_on_close(connection, 0)
        node = try XCTUnwrap(g_dbus_node_info_new_for_xml(Self.xml, nil))
        for (path, interface) in [("/kglobalaccel", "org.kde.KGlobalAccel"),
                                  (Self.componentPath, "org.kde.kglobalaccel.Component")] {
            var table = GDBusInterfaceVTable()
            table.method_call = { _, sender, _, _, method, parameters, invocation, data in
                guard let sender, let method, let parameters, let invocation, let data else { return }
                Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().service?.receive(
                    sender: String(cString: sender), method: String(cString: method),
                    parameters: parameters, invocation: invocation)
            }
            let info = try XCTUnwrap(g_dbus_node_info_lookup_interface(node, interface))
            registrations.append(g_dbus_connection_register_object(connection, path, info, &table,
                Unmanaged.passRetained(Box(self)).toOpaque(), { data in
                    if let data { Unmanaged<Box>.fromOpaque(data).release() }
                }, nil))
            XCTAssertNotEqual(registrations.last, 0)
        }
    }

    func ownName() throws {
        name = g_bus_own_name_on_connection(connection, Self.busName, G_BUS_NAME_OWNER_FLAGS_NONE,
            { _, _, data in
                if let data { Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().service?.hasName = true }
            }, { _, _, data in
                if let data { Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().service?.hasName = false }
            }, Unmanaged.passRetained(Box(self)).toOpaque(), { data in
                if let data { Unmanaged<Box>.fromOpaque(data).release() }
            })
        XCTAssertTrue(GTKTestSupport.spin { self.hasName })
    }

    func dropName() {
        if name != 0 { g_bus_unown_name(name); name = 0 }
        hasName = false
    }

    func shutdown() {
        dropName()
        guard let connection else { return }
        for registration in registrations { g_dbus_connection_unregister_object(connection, registration) }
        registrations.removeAll()
        for call in calls where call.invocation != nil {
            g_dbus_method_invocation_return_dbus_error(call.invocation,
                "org.freedesktop.DBus.Error.Failed", "Fixture stopped")
            call.invocation = nil
        }
        g_dbus_connection_close(connection, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(connection))
        self.connection = nil
        if let node { g_dbus_node_info_unref(node); self.node = nil }
    }

    deinit { shutdown() }

    func emit(_ member: String = "globalShortcutReleased", body: String = "('ch.lkmc.monkeyspaw', 'toggle', int64 7)",
              path: String = componentPath, connection other: OpaquePointer? = nil) {
        let value = Self.variant(body)
        defer { g_variant_unref(value) }
        g_dbus_connection_emit_signal(other ?? connection, nil, path,
            member == "yourShortcutsChanged" ? "org.kde.KGlobalAccel" : "org.kde.kglobalaccel.Component",
            member, value, nil)
    }

    func change(_ keys: String) {
        savedKeys = keys
        emit("yourShortcutsChanged", body: "(['ch.lkmc.monkeyspaw', 'toggle', 'Monkey’s Paw', 'Open picker'], \(keys))",
             path: "/kglobalaccel")
    }

    func reply(_ call: Call, body: String? = nil) {
        guard let invocation = call.invocation else { return }
        call.invocation = nil
        if errors.contains(call.method) {
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", "Fixture failure")
            return
        }
        if let raw = rawReplies[call.method], let connection {
            let message = g_dbus_message_new_method_reply(g_dbus_method_invocation_get_message(invocation))!
            let value = Self.variant(raw)
            g_dbus_message_set_body(message, value)
            g_variant_unref(value)
            XCTAssertNotEqual(g_dbus_connection_send_message(connection, message, G_DBUS_SEND_MESSAGE_FLAGS_NONE, nil, nil), 0)
            g_object_unref(UnsafeMutableRawPointer(message))
            g_object_unref(UnsafeMutableRawPointer(invocation))
            return
        }
        let value: String
        switch call.method {
        case "getComponent": value = "(objectpath '\(Self.componentPath)',)"
        case "shortcutKeys", "setShortcutKeys": value = "(\(savedKeys),)"
        case "globalShortcutAvailable": value = available ? "(true,)" : "(false,)"
        default: value = "()"
        }
        g_dbus_method_invocation_return_value(invocation, Self.variant(body ?? replies[call.method] ?? value))
    }

    private func receive(sender: String, method: String, parameters: OpaquePointer, invocation: OpaquePointer) {
        let call = Call(sender: sender, method: method, parameters: parameters, invocation: invocation)
        calls.append(call)
        switch method {
        case "doRegister": registered = true
        case "setShortcutKeys":
            let flags = g_variant_get_child_value(parameters, 2)!
            defer { g_variant_unref(flags) }
            if g_variant_get_uint32(flags) & 2 != 0 { present = true }
        case "setInactive": present = false
        default: break
        }
        if !heldMethods.contains(method) { reply(call) }
    }

    static func variant(_ literal: String) -> OpaquePointer {
        g_variant_parse(nil, literal, nil, nil, nil)!
    }

    // Literal consumed declarations from KDE/kglobalaccel revision
    // be418d995b5422cccb29572844919df22ffabc5f, src/org.kde.KGlobalAccel.xml
    // and src/org.kde.kglobalaccel.Component.xml. Not generated by the driver.
    private static let xml = """
        <node>
          <interface name="org.kde.KGlobalAccel">
            <method name="getComponent">
              <arg type="o" direction="out"/>
              <arg name="componentUnique" type="s" direction="in"/>
            </method>
            <method name="setInactive"><arg name="actionId" type="as" direction="in"/></method>
            <method name="doRegister"><arg name="actionId" type="as" direction="in"/></method>
            <signal name="yourShortcutsChanged">
              <arg name="actionId" type="as" direction="out"/>
              <arg name="newKeys" type="a(ai)" direction="out"/>
              <annotation name="org.qtproject.QtDBus.QtTypeName.Out1" value="QList&lt;QKeySequence&gt;"/>
            </signal>
            <method name="shortcutKeys">
              <arg type="a(ai)" direction="out"/>
              <annotation name="org.qtproject.QtDBus.QtTypeName.Out0" value="QList&lt;QKeySequence&gt;"/>
              <arg name="actionId" type="as" direction="in"/>
            </method>
            <method name="setShortcutKeys">
              <arg type="a(ai)" direction="out"/>
              <annotation name="org.qtproject.QtDBus.QtTypeName.Out0" value="QList&lt;QKeySequence&gt;"/>
              <arg name="actionId" type="as" direction="in"/>
              <arg name="keys" type="a(ai)" direction="in"/>
              <annotation name="org.qtproject.QtDBus.QtTypeName.In1" value="QList&lt;QKeySequence&gt;"/>
              <arg name="flags" type="u" direction="in"/>
            </method>
            <method name="globalShortcutAvailable">
              <arg type="b" direction="out"/>
              <arg name="key" type="(ai)" direction="in"/>
              <annotation name="org.qtproject.QtDBus.QtTypeName.In0" value="QKeySequence"/>
              <arg name="component" type="s" direction="in"/>
            </method>
          </interface>
          <interface name="org.kde.kglobalaccel.Component">
            <signal name="globalShortcutPressed">
              <arg name="componentUnique" type="s" direction="out"/>
              <arg name="actionUnique" type="s" direction="out"/>
              <arg name="timestamp" type="x" direction="out"/>
            </signal>
            <signal name="globalShortcutRepeated">
              <arg name="componentUnique" type="s" direction="out"/>
              <arg name="actionUnique" type="s" direction="out"/>
              <arg name="timestamp" type="x" direction="out"/>
            </signal>
            <signal name="globalShortcutReleased">
              <arg name="componentUnique" type="s" direction="out"/>
              <arg name="actionUnique" type="s" direction="out"/>
              <arg name="timestamp" type="x" direction="out"/>
            </signal>
          </interface>
        </node>
        """
}
#endif
