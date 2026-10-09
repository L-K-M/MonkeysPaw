#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

enum PortalSessionTestSupport {
    static func tools(settingsHook: String = "") throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = try FakePortal.requirePrivateBus()
        tools.environment["XDG_DATA_HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.path
        try tools.install("gsettings", script: """
            \(FakeLinuxTools.recordArguments)
            \(settingsHook)
            case "$1:$3" in
                list-schemas:) printf '%s\\n' 'org.gnome.settings-daemon.plugins.media-keys' ;;
                get:custom-keybindings)
                    [ "$FAKE_BINDINGS" = FAIL ] && exit 2
                    printf '%s\\n' "${FAKE_BINDINGS:-@as []}" ;;
                get:name)
                    case "$2" in
                        *custom2/) printf '%s\\n' "'Foreign row'" ;;
                        *) printf '%s\\n' "${FAKE_NAME:-'Other app'}" ;;
                    esac ;;
                get:command)
                    case "$2" in
                        *custom2/) printf '%s\\n' "'foreign-command'" ;;
                        *) printf '%s\\n' "${FAKE_COMMAND:-'gapplication action ch.lkmc.monkeyspaw toggle'}" ;;
                    esac ;;
                get:binding) printf '%s\\n' "${FAKE_ACCELERATOR:-'<Control><Alt>p'}" ;;
                set:*) [ "$3" = "$FAKE_FAIL_KEY" ] && exit 2; exit 0 ;;
                *) exit 2 ;;
            esac
            """)
        return tools
    }

    static func stringOption(_ call: FakePortal.Call, _ name: String) throws -> String {
        let value = try XCTUnwrap(call.option(name))
        defer { g_variant_unref(value) }
        XCTAssertEqual(String(cString: g_variant_get_type_string(value)), "s")
        return String(cString: g_variant_get_string(value, nil))
    }

    static func uintOption(_ call: FakePortal.Call, _ name: String) throws -> UInt32 {
        let value = try XCTUnwrap(call.option(name))
        defer { g_variant_unref(value) }
        XCTAssertEqual(String(cString: g_variant_get_type_string(value)), "u")
        return g_variant_get_uint32(value)
    }

    /// An ordinary round trip is a bus ordering barrier, not a timing sleep.
    static func barrier(_ transport: LinuxPortalTransport) {
        var done = false
        transport.call(.property(.remoteDesktop, .version),
            deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { _ in done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }
}
#endif
