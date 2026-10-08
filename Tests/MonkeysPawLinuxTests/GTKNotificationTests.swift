#if os(Linux)
import CGtk
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

/// A private-bus notification daemon verifies the real GNotification payload.
final class GTKNotificationTests: XCTestCase {
    private final class Calls {
        var bodies: [String] = []
        var ready = false
    }

    func testDeliveryNotificationsHaveNoFocusActions() throws {
        try GTKTestSupport.requireDisplay()
        let connection = try XCTUnwrap(g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil))
        defer { g_object_unref(UnsafeMutableRawPointer(connection)) }
        let info = try XCTUnwrap(g_dbus_node_info_new_for_xml(Self.interfaceXML, nil))
        defer { g_dbus_node_info_unref(info) }
        let calls = Calls()
        let data = Unmanaged.passUnretained(calls).toOpaque()
        var table = GDBusInterfaceVTable()
        table.method_call = { _, _, _, _, method, parameters, invocation, data in
            guard let method, let parameters, let invocation, let data else { return }
            let calls = Unmanaged<Calls>.fromOpaque(data).takeUnretainedValue()
            let response: String
            switch String(cString: method) {
            case "Notify":
                let actions = g_variant_get_child_value(parameters, 5)!
                let title = g_variant_get_child_value(parameters, 3)!
                let body = g_variant_get_child_value(parameters, 4)!
                XCTAssertEqual(g_variant_n_children(actions), 0)
                XCTAssertEqual(String(cString: g_variant_get_string(title, nil)), AppIdentity.displayName)
                calls.bodies.append(String(cString: g_variant_get_string(body, nil)))
                g_variant_unref(actions)
                g_variant_unref(title)
                g_variant_unref(body)
                response = "(uint32 1,)"
            case "GetCapabilities": response = "(['body', 'actions'],)"
            case "GetServerInformation": response = "('Test', 'Test', '1', '1.2')"
            default: response = "()"
            }
            g_dbus_method_invocation_return_value(invocation, g_variant_parse(nil, response, nil, nil, nil))
        }
        let object = g_dbus_connection_register_object(connection, "/org/freedesktop/Notifications",
            g_dbus_node_info_lookup_interface(info, "org.freedesktop.Notifications"), &table, data, nil, nil)
        XCTAssertNotEqual(object, 0)
        defer { g_dbus_connection_unregister_object(connection, object) }

        let owner = g_bus_own_name_on_connection(connection, "org.freedesktop.Notifications",
            G_BUS_NAME_OWNER_FLAGS_NONE, { _, _, data in
                guard let data else { return }
                Unmanaged<Calls>.fromOpaque(data).takeUnretainedValue().ready = true
            }, nil, data, nil)
        defer { g_bus_unown_name(owner) }
        XCTAssertTrue(GTKTestSupport.spin { calls.ready })

        let application = try XCTUnwrap(gtk_application_new("ch.lkmc.monkeyspaw.tests.notifications", G_APPLICATION_NON_UNIQUE))
        defer { GTKTestSupport.destroy(application) }
        XCTAssertNotEqual(g_application_register(mp_gapp(application), nil, nil), 0)
        let notifier = GTKNotifier(application: application,
            session: LinuxSessionProbe(environment: ["DISPLAY": ":0"], flatpakInfoExists: false))
        notifier.copied()
        notifier.pressPaste(chord: .terminal, reason: .requested)
        XCTAssertTrue(GTKTestSupport.spin { calls.bodies.count == 2 })
        XCTAssertEqual(calls.bodies, [DeliveryStrings.copied, DeliveryStrings.pressControlShiftV])
    }

    private static let interfaceXML = """
        <node><interface name="org.freedesktop.Notifications">
        <method name="Notify">
          <arg type="s" direction="in"/><arg type="u" direction="in"/>
          <arg type="s" direction="in"/><arg type="s" direction="in"/>
          <arg type="s" direction="in"/><arg type="as" direction="in"/>
          <arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
          <arg type="u" direction="out"/>
        </method>
        <method name="GetCapabilities"><arg type="as" direction="out"/></method>
        <method name="GetServerInformation">
          <arg type="s" direction="out"/><arg type="s" direction="out"/>
          <arg type="s" direction="out"/><arg type="s" direction="out"/>
        </method>
        <method name="CloseNotification"><arg type="u" direction="in"/></method>
        </interface></node>
        """
}
#endif
