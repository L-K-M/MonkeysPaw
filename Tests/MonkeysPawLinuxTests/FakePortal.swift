#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

/// A separate GDBus connection exporting real portal wire signatures. No
/// transport code or codec is reused here, and no display is initialized.
final class FakePortal {
    enum Timing { case beforeReply, afterReply, manual }
    enum Handle { case predicted, different }
    enum Behavior { case requestsOnly, sessions }
    enum DeferredReply { case method, response }

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
            for index in 0..<g_variant_n_children(parameters) {
                let child = g_variant_get_child_value(parameters, index)!
                defer { g_variant_unref(child) }
                if String(cString: g_variant_get_type_string(child)) == "a{sv}" {
                    return g_variant_lookup_value(child, name, nil)
                }
            }
            return nil
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

    var behavior: Behavior = .requestsOnly
    var versions: [String: UInt32] = ["org.freedesktop.portal.GlobalShortcuts": 2,
                                    "org.freedesktop.portal.RemoteDesktop": 2]
    var availableDevices: UInt32 = 1
    var grantedDevices: UInt32 = 1
    var restoredShortcuts = "@a(sa{sv}) []"
    var boundShortcuts = "[('toggle', {'trigger_description': <'Ctrl+Alt+P'>})]"
    var replacementTokens = ["rotation-one", "rotation-two"]
    var responses: [String: String] = [:]
    var handleCall: ((Call) -> Bool)?
    // Optional coupled KDE daemon: Create loads stored actions before Bind,
    // and Bind removes omitted component actions, as in Plasma 6.3.
    var kde: FakeKGlobalAccel?
    var closeError = false
    var holdSessionClose = false
    private var heldCloses: [OpaquePointer] = []
    private(set) var ordinaryCalls: [Call] = []
    private(set) var propertyCalls: [(sender: String, interface: String, name: String)] = []
    private(set) var sessionOwners: [String: String] = [:]
    private var starts = 0
    private var timers: [UUID: guint] = [:]
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
    private var notificationOwner: guint = 0
    private var notificationsReady = false
    private(set) var notificationCount = 0
    private var nameSubscription: guint = 0

    static func requirePrivateBus() throws -> String {
        guard ProcessInfo.processInfo.environment["MONKEYSPAW_REQUIRE_PORTAL_BUS"] == "1" else {
            throw XCTSkip("Run with MONKEYSPAW_REQUIRE_PORTAL_BUS=1 under dbus-run-session.")
        }
        return try XCTUnwrap(ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
                             "The required private portal bus is missing.")
    }

    init(address: String, globalShortcuts: UInt32? = 2, remoteDesktop: UInt32? = 2) throws {
        versions = [:]
        if let globalShortcuts { versions["org.freedesktop.portal.GlobalShortcuts"] = globalShortcuts }
        if let remoteDesktop { versions["org.freedesktop.portal.RemoteDesktop"] = remoteDesktop }
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
            for name in versions.keys {
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

    func ownNotifications() throws {
        try register(path: "/org/freedesktop/Notifications", interface: "org.freedesktop.Notifications")
        notificationOwner = g_bus_own_name_on_connection(connection, "org.freedesktop.Notifications",
            G_BUS_NAME_OWNER_FLAGS_NONE, { _, _, data in
                guard let data else { return }
                Unmanaged<WeakBox>.fromOpaque(data).takeUnretainedValue().portal?.notificationsReady = true
            }, nil, Unmanaged.passRetained(WeakBox(self)).toOpaque(), Self.releaseBox)
        XCTAssertTrue(GTKTestSupport.spin { self.notificationsReady })
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
        if notificationOwner != 0 { g_bus_unown_name(notificationOwner); notificationOwner = 0 }
        for timer in timers.values { g_source_remove(timer) }
        timers.removeAll()
        handleCall = nil
        for invocation in heldCloses {
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", "Fixture stopped")
        }
        heldCloses.removeAll()
        if nameSubscription != 0 {
            g_dbus_connection_signal_unsubscribe(connection, nameSubscription)
            nameSubscription = 0
        }
        for registration in registrations { g_dbus_connection_unregister_object(connection, registration) }
        registrations.removeAll()
        calls.removeAll()
        ordinaryCalls.removeAll()
        if g_dbus_connection_is_closed(connection) == 0 {
            let receipt = ConnectionBox()
            g_dbus_connection_flush(connection, nil, { source, result, data in
                guard let source, let result, let data else { return }
                let receipt = Unmanaged<ConnectionBox>.fromOpaque(data).takeRetainedValue()
                _ = g_dbus_connection_flush_finish(mp_dbus_connection(source), result, nil)
                receipt.finished = true
            }, Unmanaged.passRetained(receipt).toOpaque())
            XCTAssertTrue(GTKTestSupport.spin { receipt.finished })
        }
        g_dbus_connection_close(connection, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(connection))
        self.connection = nil
        if let node { g_dbus_node_info_unref(node); self.node = nil }
    }

    func deferReply(_ call: Call, kind: DeferredReply, after seconds: Double) {
        let id = UUID()
        timers[id] = GTK.after(seconds) { [weak self] in
            guard let self else { return }
            self.timers.removeValue(forKey: id)
            switch kind {
            case .method: self.reply(call)
            case .response: self.respond(call)
            }
        }
    }

    func respond(_ call: Call, body: String? = nil, path: String? = nil) {
        guard let connection else { return }
        let value = Self.variant(body ?? responses[call.method] ?? (behavior == .sessions ? sessionResponse(call) : responseBody))
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
        if ["ConfigureShortcuts", "NotifyKeyboardKeysym"].contains(call.method) {
            g_dbus_method_invocation_return_value(invocation, nil)
            return
        }
        var children: [OpaquePointer?] = [g_variant_new_object_path(call.path)]
        let value = children.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, 1) }
        g_dbus_method_invocation_return_value(invocation, value)
    }

    func emit(member: String, body: String, path: String = "/org/freedesktop/portal/desktop") {
        guard let connection else { return }
        let parameters = Self.variant(body)
        defer { g_variant_unref(parameters) }
        let interface = member == "Closed" ? "org.freedesktop.portal.Session"
            : "org.freedesktop.portal.GlobalShortcuts"
        XCTAssertNotEqual(g_dbus_connection_emit_signal(connection, nil, path, interface,
            member, parameters, nil), 0)
    }

    func keys(_ call: Call) -> (Int32, UInt32) {
        let key = g_variant_get_child_value(call.parameters, 2)!
        let state = g_variant_get_child_value(call.parameters, 3)!
        defer { g_variant_unref(key); g_variant_unref(state) }
        return (g_variant_get_int32(key), g_variant_get_uint32(state))
    }

    func text(_ call: Call, index: UInt) -> String {
        let value = g_variant_get_child_value(call.parameters, index)!
        defer { g_variant_unref(value) }
        return String(cString: g_variant_get_string(value, nil))
    }

    private func sessionResponse(_ call: Call) -> String {
        switch call.method {
        case "CreateSession":
            if call.interface == "org.freedesktop.portal.GlobalShortcuts" { kde?.portalCreate() }
            let value = call.option("session_handle_token")!
            defer { g_variant_unref(value) }
            let session = "/org/freedesktop/portal/desktop/session/"
                + call.sender.dropFirst().replacingOccurrences(of: ".", with: "_") + "/"
                + String(cString: g_variant_get_string(value, nil))
            if sessionOwners[session] == nil {
                sessionOwners[session] = call.sender
                try! register(path: session, interface: "org.freedesktop.portal.Session")
            }
            return "(uint32 0, {'session_handle': <'\(session)'>})"
        case "ListShortcuts":
            if let kde, kde.componentExists {
                let actions = kde.actionNames.map { "('\($0)', {'trigger_description': <'\(kde.hasBinding ? "Saved KDE choice" : "")'>})" }
                return "(uint32 0, {'shortcuts': <@a(sa{sv}) [\(actions.joined(separator: ","))]>})"
            }
            return "(uint32 0, {'shortcuts': <\(restoredShortcuts)>})"
        case "BindShortcuts":
            if let kde {
                let actions = g_variant_get_child_value(call.parameters, 1)!
                defer { g_variant_unref(actions) }
                var preferred: String?
                let ids = (0..<g_variant_n_children(actions)).map { index -> String in
                    let entry = g_variant_get_child_value(actions, index)!
                    let id = g_variant_get_child_value(entry, 0)!
                    let properties = g_variant_get_child_value(entry, 1)!
                    defer { g_variant_unref(entry); g_variant_unref(id); g_variant_unref(properties) }
                    if let trigger = g_variant_lookup_value(properties, "preferred_trigger", nil) {
                        preferred = String(cString: g_variant_get_string(trigger, nil))
                        g_variant_unref(trigger)
                    }
                    return String(cString: g_variant_get_string(id, nil))
                }
                kde.portalBind(ids, preferred: preferred)
                return "(uint32 0, {'shortcuts': <[('toggle', {'trigger_description': <'\(kde.hasBinding ? "Saved KDE choice" : "")'>})]>})"
            }
            return "(uint32 0, {'shortcuts': <\(boundShortcuts)>})"
        case "Start":
            let token = replacementTokens[min(starts, replacementTokens.count - 1)]
            starts += 1
            return "(uint32 0, {'devices': <uint32 \(grantedDevices)>, 'restore_token': <'\(token)'>})"
        default: return "(uint32 0, @a{sv} {})"
        }
    }

    private func receive(sender: String, path: String, interface: String, method: String,
                         parameters: OpaquePointer, invocation: OpaquePointer) {
        if interface == "org.freedesktop.Notifications" {
            let body: String
            switch method {
            case "Notify": notificationCount += 1; body = "(uint32 1,)"
            case "GetCapabilities": body = "(['body'],)"
            case "GetServerInformation": body = "('Fixture', 'Fixture', '1', '1.2')"
            default: body = "()"
            }
            g_dbus_method_invocation_return_value(invocation, Self.variant(body))
            return
        }
        if method == "Close" {
            closedPaths.append(path)
            if sessionOwners[path] != nil {
                if holdSessionClose { heldCloses.append(invocation); return }
                if closeError {
                    g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", "Fixture close failed")
                    return
                }
                kde?.portalClose()
            }
            g_dbus_method_invocation_return_value(invocation, nil)
            return
        }
        if behavior == .sessions, method != "CreateSession" {
            let session = g_variant_get_child_value(parameters, 0)!
            defer { g_variant_unref(session) }
            let handle = String(cString: g_variant_get_string(session, nil))
            guard sessionOwners[handle] == sender else {
                g_dbus_method_invocation_return_dbus_error(invocation,
                    "org.freedesktop.portal.Error.NotAllowed", "Different session owner")
                return
            }
        }
        if ["ConfigureShortcuts", "NotifyKeyboardKeysym"].contains(method) {
            let call = Call(sender: sender, interface: interface, method: method, token: "",
                            path: path, parameters: parameters, invocation: invocation)
            ordinaryCalls.append(call)
            if handleCall?(call) == true { return }
            reply(call)
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
        if handleCall?(call) == true { return }
        switch timing {
        case .beforeReply: respond(call); reply(call)
        case .afterReply: reply(call); respond(call)
        case .manual: break
        }
    }

    func releaseSessionCloses() {
        let invocations = heldCloses
        heldCloses.removeAll()
        for invocation in invocations {
            kde?.portalClose()
            g_dbus_method_invocation_return_value(invocation, nil)
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
        table.get_property = { _, sender, _, interface, name, _, data in
            guard let sender, let interface, let name, let data,
                  let portal = Unmanaged<WeakBox>.fromOpaque(data).takeUnretainedValue().portal else { return nil }
            let interfaceName = String(cString: interface)
            let property = String(cString: name)
            portal.propertyCalls.append((String(cString: sender), interfaceName, property))
            return g_variant_new_uint32(property == "version"
                ? (portal.versions[interfaceName] ?? 0) : portal.availableDevices)
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
    // enforce session ownership on the real bus without desktop consent UI.
    private static let xml = """
        <node>
          <interface name='org.freedesktop.Notifications'>
            <method name='Notify'><arg type='s' direction='in'/><arg type='u' direction='in'/>
              <arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/>
              <arg type='as' direction='in'/><arg type='a{sv}' direction='in'/><arg type='i' direction='in'/>
              <arg type='u' direction='out'/></method>
            <method name='GetCapabilities'><arg type='as' direction='out'/></method>
            <method name='GetServerInformation'><arg type='s' direction='out'/><arg type='s' direction='out'/>
              <arg type='s' direction='out'/><arg type='s' direction='out'/></method>
            <method name='CloseNotification'><arg type='u' direction='in'/></method>
          </interface>
          <interface name='org.freedesktop.portal.GlobalShortcuts'>
            <property name='version' type='u' access='read'/>
            <method name='ConfigureShortcuts'><arg type='o' direction='in'/><arg type='s' direction='in'/>
              <arg type='a{sv}' direction='in'/></method>
            <signal name='Activated'><arg type='o'/><arg type='s'/><arg type='t'/><arg type='a{sv}'/></signal>
            <signal name='Deactivated'><arg type='o'/><arg type='s'/><arg type='t'/><arg type='a{sv}'/></signal>
            <signal name='ShortcutsChanged'><arg type='o'/><arg type='a(sa{sv})'/></signal>
            <method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='BindShortcuts'><arg type='o' direction='in'/><arg type='a(sa{sv})' direction='in'/>
              <arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='ListShortcuts'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/>
              <arg type='o' direction='out'/></method>
          </interface>
          <interface name='org.freedesktop.portal.RemoteDesktop'>
            <property name='version' type='u' access='read'/>
            <property name='AvailableDeviceTypes' type='u' access='read'/>
            <method name='NotifyKeyboardKeysym'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/>
              <arg type='i' direction='in'/><arg type='u' direction='in'/></method>
            <method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
            <method name='SelectDevices'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/>
              <arg type='o' direction='out'/></method>
            <method name='Start'><arg type='o' direction='in'/><arg type='s' direction='in'/>
              <arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>
          </interface>
          <interface name='org.freedesktop.portal.Session'>
            <method name='Close'/><signal name='Closed'><arg type='a{sv}'/></signal>
          </interface>
          <interface name='org.freedesktop.portal.Request'>
            <method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal>
          </interface>
        </node>
        """
}
#endif
