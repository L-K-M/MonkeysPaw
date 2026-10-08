#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Desktop action identifiers must match GSimpleAction names exactly.
enum ActionName: String {
    case toggle
    case selftest
    case quit
}

/// The synchronous Linux entry point, with one GtkApplication per session.
public enum MonkeysPawLinuxApp {
    private static let usage = """
        Usage:
          monkeyspaw
          monkeyspaw --version
          monkeyspaw --gapplication-service
          monkeyspaw --selftest
          monkeyspaw --help
          monkeyspaw -h
        """

    private enum LaunchMode {
        case interactive
        case service
        case selftest

        var arguments: [String] {
            switch self {
            case .interactive: return [AppIdentity.binaryName]
            case .service: return [AppIdentity.binaryName, "--gapplication-service"]
            case .selftest: return [AppIdentity.binaryName, "--selftest"]
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
        case ["--selftest"]:
            return runPanel(mode: .selftest)
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
        // GTK uses the program name for X11's WM_CLASS. Keep it aligned with
        // the desktop identity so FocusTracker can reliably exclude our windows.
        g_set_prgname(AppIdentity.linuxAppID)
        let flags = GApplicationFlags(rawValue: mp_app_default_flags().rawValue
            | G_APPLICATION_HANDLES_COMMAND_LINE.rawValue)
        let application = gtk_application_new(AppIdentity.linuxAppID, flags)!
        defer { g_object_unref(application) }

        let gapp = mp_gapp(application)
        let environment = LinuxEnvironment(application: application)
        g_application_add_main_option(gapp, "selftest", 0, G_OPTION_FLAG_NONE,
                                      G_OPTION_ARG_NONE, "Run the paste self-test and print JSON", nil)

        let toggle = g_simple_action_new(ActionName.toggle.rawValue, nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(toggle)) {
            // Cold D-Bus actions need not emit "activate". The environment creates
            // the panel lazily here too, so the first shortcut actually shows it.
            environment.activateToggle()
        }
        g_action_map_add_action(mp_action_map(application), mp_action(toggle))
        g_object_unref(UnsafeMutableRawPointer(toggle))

        let selftest = g_simple_action_new(ActionName.selftest.rawValue, nil)!
        GTK.onActionActivated(UnsafeMutableRawPointer(selftest)) {
            environment.runSelfTest { report in
                guard let json = reportJSON(report) else {
                    environment.log.write(.error, "Could not encode the self-test report")
                    return
                }
                print(json)
                fflush(nil)
            }
        }
        g_action_map_add_action(mp_action_map(application), mp_action(selftest))
        g_object_unref(UnsafeMutableRawPointer(selftest))

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

        let isRemote = g_application_get_is_remote(gapp) != 0
        if isRemote, mode == .service {
            // Service activation races must leave the primary panel's visibility alone.
            // Run GLib's unregister cleanup without its default remote activation.
            // Destroying a registered GtkApplication without run emits a warning.
            let stop: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                      UnsafeMutableRawPointer?) -> gint = { _, _, _ in 0 }
            mp_connect(UnsafeMutableRawPointer(application), "handle-local-options",
                       unsafeBitCast(stop, to: GCallback.self), nil, nil)
            return g_application_run(gapp, 0, nil)
        }

        GTK.onSignal(UnsafeMutableRawPointer(application), "activate") {
            environment.presentFromLauncher()
        }

        GTK.onCommandLine(application) { command in
            if g_variant_dict_contains(g_application_command_line_get_options_dict(command), "selftest") != 0 {
                // Retaining the command keeps the remote CLI waiting. Its print
                // method sends JSON to that caller's stdout, not the primary's.
                g_object_ref(command)
                environment.runSelfTest { report in
                    if let json = reportJSON(report) {
                        mp_command_line_print(command, json)
                        g_application_command_line_set_exit_status(command, 0)
                    } else {
                        environment.log.write(.error, "Could not encode the self-test report")
                        g_application_command_line_set_exit_status(command, 1)
                    }
                    g_object_unref(command)
                    // A standalone diagnostic exits; a resident primary keeps
                    // running after a forwarded CLI diagnostic finishes.
                    if mode == .selftest { g_application_quit(gapp) }
                }
                return 0
            }

            if g_application_command_line_get_is_remote(command) != 0 {
                environment.activateToggle()
            } else {
                environment.presentFromLauncher()
            }
            return 0
        }

        // A panel spends most of its life hidden. Holding keeps the process resident.
        // A standalone diagnostic must not install a GNOME desktop shortcut.
        if !isRemote, mode != .selftest { environment.start() }
        if !isRemote {
            g_application_hold(gapp)
        }
        defer { if !isRemote { g_application_release(gapp) } }

        // Service mode prevents an automatic activation before a cold toggle,
        // which would otherwise show the window and immediately hide it again.
        let arguments = mode.arguments
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        return argv.withUnsafeMutableBufferPointer {
            g_application_run(gapp, Int32(arguments.count), $0.baseAddress)
        }
    }

    private static func reportJSON(_ report: SelfTestReport) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
