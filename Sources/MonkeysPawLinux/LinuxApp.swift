#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Desktop action identifiers must match GSimpleAction names exactly.
enum ActionName: String {
    case toggle
    case quit
}

/// The synchronous Linux entry point, with one GtkApplication per session.
public enum MonkeysPawLinuxApp {
    private static let usage = """
        Usage:
          monkeyspaw
          monkeyspaw --version
          monkeyspaw --gapplication-service
          monkeyspaw --help
          monkeyspaw -h
        """

    private enum LaunchMode {
        case interactive
        case service

        var arguments: [String] {
            switch self {
            case .interactive: return [AppIdentity.binaryName]
            case .service: return [AppIdentity.binaryName, "--gapplication-service"]
            }
        }
    }

    public static func main() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments {
        case ["--version"]:
            print("\(AppIdentity.binaryName) \(AppIdentity.fallbackVersion)")
            return 0
        case ["--help"], ["-h"]:
            print(usage)
            return 0
        case ["--gapplication-service"]:
            // The session bus starts the app with GLib's service convention.
            return runPanel(mode: .service)
        case []:
            return runPanel(mode: .interactive)
        default:
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            return 2
        }
    }

    private static func runPanel(mode: LaunchMode) -> Int32 {
        // This identity is also the D-Bus name, desktop basename and StartupWMClass.
        // IS_SERVICE rejects an existing primary during registration. Register
        // normally to detect remote launches, then let run parse the service flag.
        let application = gtk_application_new(AppIdentity.linuxAppID, mp_app_default_flags())!
        defer { g_object_unref(application) }

        let gapp = mp_gapp(application)
        let environment = LinuxEnvironment(application: application)

        let toggle = g_simple_action_new(ActionName.toggle.rawValue, nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(toggle)) {
            // Cold D-Bus actions need not emit "activate". The environment creates
            // the panel lazily here too, so the first shortcut actually shows it.
            environment.panel.toggle()
        }
        g_action_map_add_action(mp_action_map(application), mp_action(toggle))
        g_object_unref(UnsafeMutableRawPointer(toggle))

        let quit = g_simple_action_new(ActionName.quit.rawValue, nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(quit)) {
            g_application_quit(gapp)
        }
        g_action_map_add_action(mp_action_map(application), mp_action(quit))
        g_object_unref(UnsafeMutableRawPointer(quit))

        // Register early so a remote invocation exits without entering the main loop.
        var error: UnsafeMutablePointer<GError>?
        guard g_application_register(gapp, nil, &error) != 0 else {
            let detail = error.flatMap { $0.pointee.message }
                .map { String(cString: $0) } ?? "unknown error"
            if let error { g_error_free(error) }

            environment.log.write(.error, "Could not register the application with the session bus: \(detail)")
            return 1
        }

        if g_application_get_is_remote(gapp) != 0 {
            // Service activation races must leave the primary panel's visibility alone.
            if mode == .interactive {
                g_action_group_activate_action(mp_action_group(application), ActionName.toggle.rawValue, nil)
                if let connection = g_application_get_dbus_connection(gapp) {
                    g_dbus_connection_flush_sync(connection, nil, nil)
                }
            }

            // Run GLib's unregister cleanup without its default remote activation.
            // Destroying a registered GtkApplication without run emits a warning.
            let stop: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                      UnsafeMutableRawPointer?) -> gint = { _, _, _ in 0 }
            mp_connect(UnsafeMutableRawPointer(application), "handle-local-options",
                       unsafeBitCast(stop, to: GCallback.self), nil, nil)
            return g_application_run(gapp, 0, nil)
        }

        GTK.onSignal(UnsafeMutableRawPointer(application), "activate") {
            environment.panel.show()
        }

        // A panel spends most of its life hidden. Holding keeps the process resident.
        g_application_hold(gapp)
        defer { g_application_release(gapp) }

        // Service mode prevents an automatic activation before a cold toggle,
        // which would otherwise show the window and immediately hide it again.
        let arguments = mode.arguments
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        return argv.withUnsafeMutableBufferPointer {
            g_application_run(gapp, Int32(arguments.count), $0.baseAddress)
        }
    }
}
#endif
