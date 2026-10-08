#if os(Linux)
import CGtk
import Foundation
import XCTest

/// A separate GDBus connection exporting real portal wire signatures. No
/// transport code or codec is reused here, and no display is initialized.
final class FakePortal {
    enum Timing { case beforeReply, afterReply, manual }
    enum Handle { case predicted, different }

    final class Call {
        let sender: String
        let interface: String
        let method: String
        let token: String
        let expectedPath: String
        let path: String
        let parameters: OpaquePointer
        var invocation: OpaquePointer?

        init(sender: String, interface: String, method: String, token: String,
             path: String, parameters: OpaquePointer, invocation: OpaquePointer) {
            self.sender = sender
            self.interface = interface
            self.method = method
            self.token = token
            expectedPath = "/org/freedesktop/portal/desktop/request/"
                + sender.dropFirst().replacingOccurrences(of: ".", with: "_") + "/" + token
            self.path = path
            self.parameters = g_variant_ref(parameters)!
            self.invocation = invocation
        }

        deinit {
            g_variant_unref(parameters)
            if let invocation { g_object_unref(UnsafeMutableRawPointer(invocation)) }
        }

        var signature: String { String(cString: g_variant_get_type_string(parameters)) }

        func option(_ name: String) -> OpaquePointer? {
            let count = g_variant_n_children(parameters)
            let options = g_variant_get_child_value(parameters, count - 1)!
            defer { g_variant_unref(options) }
            return g_variant_lookup_value(options, name, nil)
        }
    }

    private final class WeakBox {
        weak var portal: FakePortal?
        init(_ portal: FakePortal) { self.portal = portal }
    }

    private final class ConnectionBox {
        var connection: OpaquePointer?
        var finished = false
    }

    static let busName = "org.freedesktop.portal.Desktop"
    static let successBody = """
        (uint32 0, {'session_handle': <'/org/freedesktop/portal/desktop/session/mock'>,
        'devices': <uint32 1>, 'restore_token': <'fixture-restore'>,
        'shortcuts': <[('toggle', {'description': <'Open picker'>,
        'trigger_description': <'Ctrl+Alt+P'>})]>})
        """

    var timing: Timing = .afterReply
    var handle: Handle = .predicted
    var responseBody = successBody
    var methodError: String?
    var replyBody: String?
    private(set) var calls: [Call] = []
    private(set) var closedPaths: [String] = []
    private(set) var departedNames: [String] = []
    private(set) var hasName = false

    private var connection: OpaquePointer?
    private var node: UnsafeMutablePointer<GDBusNodeInfo>?
    private var registrations: [guint] = []
    private var nameOwner: guint = 0
    private var nameSubscription: guint = 0

    static func requirePrivateBus() throws -> String {
        guard ProcessInfo.processInfo.environment["MONKEYSPAW_REQUIRE_PORTAL_BUS"] == "1" else {
            throw XCTSkip("Run with MONKEYSPAW_REQUIRE_PORTAL_BUS=1 under dbus-run-session.")
        }
        return try XCTUnwrap(ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
                             "The required private portal bus is missing.")
    }

    init(address: String) throws {
        let box = ConnectionBox()
        let flags = GDBusConnectionFlags(rawValue:
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        g_dbus_connection_new_for_address(address, flags, nil, nil, { _, result, data in
            guard let result, let data else { return }
            let box = Unmanaged<ConnectionBox>.fromOpaque(data).takeRetainedValue()
            // Do not expose native error bodies in test diagnostics either.
            box.connection = g_dbus_connection_new_for_address_finish(result, nil)
            box.finished = true
        }, Unmanaged.passRetained(box).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { box.finished }, "Fake portal connection timed out.")
        connection = try XCTUnwrap(box.connection)
        g_dbus_connection_set_exit_on_close(connection, 0)
        node = try XCTUnwrap(g_dbus_node_info_new_for_xml(Self.xml, nil))
        do {
            for name in ["org.freedesktop.portal.GlobalShortcuts", "org.freedesktop.portal.RemoteDesktop"] {
                try register(path: "/org/freedesktop/portal/desktop", interface: name)
            }
            observeDepartures()
        } catch {
            shutdown()
            throw error
        }
    }

    deinit { shutdown() }

    func ownName() throws {
        let connection = try XCTUnwrap(connection)
        nameOwner = g_bus_own_name_on_connection(connection, Self.busName, G_BUS_NAME_OWNER_FLAGS_NONE,
            { _, _, data in
                guard let data else { return }
                Unmanaged<WeakBox>.fromOpaque(data).takeUnretainedValue().portal?.hasName = true
            }, nil, Unmanaged.passRetained(WeakBox(self)).toOpaque(), Self.releaseBox)
        XCTAssertTrue(GTKTestSupport.spin { self.hasName }, "Fake portal could not own its bus name.")
        guard hasName else { throw NSError(domain: "FakePortal", code: 1) }
    }

    func dropName() {
        guard nameOwner != 0 else { return }
        g_bus_unown_name(nameOwner)
        nameOwner = 0
        hasName = false
    }

    func shutdown() {
        guard let connection else { return }
        dropName()
        if nameSubscription != 0 {
            g_dbus_connection_signal_unsubscribe(connection, nameSubscription)
            nameSubscription = 0
        }
        for registration in registrations { g_dbus_connection_unregister_object(connection, registration) }
        registrations.removeAll()
        calls.removeAll()
        g_dbus_connection_close(connection, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(connection))
        self.connection = nil
        if let node { g_dbus_node_info_unref(node); self.node = nil }
    }

    func respond(_ call: Call, body: String? = nil, path: String? = nil) {
        guard let connection else { return }
        let value = Self.variant(body ?? responseBody)
        defer { g_variant_unref(value) }
        XCTAssertNotEqual(g_dbus_connection_emit_signal(connection, call.sender, path ?? call.path,
            "org.freedesktop.portal.Request", "Response", value, nil), 0)
    }

    func reply(_ call: Call) {
        guard let connection, let invocation = call.invocation else { return }
        call.invocation = nil
        if let methodError {
            g_dbus_method_invocation_return_dbus_error(invocation, methodError, "Fixture error")
            return
        }
        if let replyBody {
            // Raw replies exercise a malicious/malformed method signature without
            // GDBus's server-side introspection check rejecting the fixture first.
            let message = g_dbus_message_new_method_reply(g_dbus_method_invocation_get_message(invocation))!
            let value = Self.variant(replyBody)
            g_dbus_message_set_body(message, value)
            g_variant_unref(value)
            XCTAssertNotEqual(g_dbus_connection_send_message(connection, message,
                G_DBUS_SEND_MESSAGE_FLAGS_NONE, nil, nil), 0)
            g_object_unref(UnsafeMutableRawPointer(message))
            g_object_unref(UnsafeMutableRawPointer(invocation))
            return
        }
        var children: [OpaquePointer?] = [g_variant_new_object_path(call.path)]
        let value = children.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, 1) }
        g_dbus_method_invocation_return_value(invocation, value)
    }

    private func receive(sender: String, path: String, interface: String, method: String,
                         parameters: OpaquePointer, invocation: OpaquePointer) {
        if method == "Close" {
            closedPaths.append(path)
            g_dbus_method_invocation_return_value(invocation, nil)
            return
        }
        let options = g_variant_get_child_value(parameters, g_variant_n_children(parameters) - 1)!
        let tokenValue = g_variant_lookup_value(options, "handle_token", nil)
        defer {
            g_variant_unref(options)
            if let tokenValue { g_variant_unref(tokenValue) }
        }
        guard let tokenValue, String(cString: g_variant_get_type_string(tokenValue)) == "s" else {
            g_dbus_method_invocation_return_dbus_error(invocation,
                "org.freedesktop.DBus.Error.InvalidArgs", "Missing fixture request token")
            return
        }
        let token = String(cString: g_variant_get_string(tokenValue, nil))
        let suffix = handle == .predicted ? token : "legacy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let requestPath = "/org/freedesktop/portal/desktop/request/"
            + sender.dropFirst().replacingOccurrences(of: ".", with: "_") + "/" + suffix
        let call = Call(sender: sender, interface: interface, method: method, token: token,
                        path: requestPath, parameters: parameters, invocation: invocation)
        calls.append(call)
        try! register(path: call.path, interface: "org.freedesktop.portal.Request")
        if call.path != call.expectedPath {
            try! register(path: call.expectedPath, interface: "org.freedesktop.portal.Request")
        }
        switch timing {
        case .beforeReply: respond(call); reply(call)
        case .afterReply: reply(call); respond(call)
        case .manual: break
        }
    }

    private static let releaseBox: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<WeakBox>.fromOpaque(data).release()
    }

    private func register(path: String, interface: String) throws {
        let connection = try XCTUnwrap(connection)
        let info = try XCTUnwrap(g_dbus_node_info_lookup_interface(node, interface))
        var table = GDBusInterfaceVTable()
        table.method_call = { _, sender, path, interface, method, parameters, invocation, data in
            guard let sender, let path, let interface, let method, let parameters, let invocation,
                  let data else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(data).takeUnretainedValue()
            box.portal?.receive(sender: String(cString: sender), path: String(cString: path),
                interface: String(cString: interface), method: String(cString: method),
                parameters: parameters, invocation: invocation)
        }
        let data = Unmanaged.passRetained(WeakBox(self)).toOpaque()
        let registration = g_dbus_connection_register_object(connection, path, info, &table,
            data, Self.releaseBox, nil)
        guard registration != 0 else {
            Unmanaged<WeakBox>.fromOpaque(data).release()
            throw NSError(domain: "FakePortal", code: 2)
        }
        registrations.append(registration)
    }

    private func observeDepartures() {
        nameSubscription = g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus",
            "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", nil,
            G_DBUS_SIGNAL_FLAGS_NONE, { _, _, _, _, _, parameters, data in
                guard let parameters, let data else { return }
                let name = g_variant_get_child_value(parameters, 0)!
                let newOwner = g_variant_get_child_value(parameters, 2)!
                defer { g_variant_unref(name); g_variant_unref(newOwner) }
                if String(cString: g_variant_get_string(newOwner, nil)).isEmpty {
                    Unmanaged<WeakBox>.fromOpaque(data).takeUnretainedValue().portal?
                        .departedNames.append(String(cString: g_variant_get_string(name, nil)))
                }
            }, Unmanaged.passRetained(WeakBox(self)).toOpaque(), Self.releaseBox)
    }

    static func variant(_ text: String) -> OpaquePointer {
        // All callers supply fixed test data. Never print a parser error body.
        g_variant_parse(nil, text, nil, nil, nil)!
    }

    // Signatures from the linked xdg-desktop-portal API docs. These fake methods
    // only test encoding and Request semantics; they create no real sessions.
    private static let xml = """
        <node>
          <interface name='org.freedesktop.portal.GlobalShortcuts'>
            <method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='BindShortcuts'><arg type='o' direction='in'/><arg type='a(sa{sv})' direction='in'/>
              <arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='ListShortcuts'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/>
              <arg type='o' direction='out'/></method>
          </interface>
          <interface name='org.freedesktop.portal.RemoteDesktop'>
            <method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='SelectDevices'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/>
              <arg type='o' direction='out'/></method>
            <method name='Start'><arg type='o' direction='in'/><arg type='s' direction='in'/>
              <arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
          </interface>
          <interface name='org.freedesktop.portal.Request'>
            <method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal>
          </interface>
        </node>
        """
}
#endif
