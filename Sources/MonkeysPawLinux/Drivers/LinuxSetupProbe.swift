#if os(Linux)
import CGtk
import MonkeysPawCore

final class LinuxSetupProbe: SetupProbe {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let runner: LinuxToolRunner
    private let hotkey: LinuxHotkeyBackend
    private let session: SessionProbe
    private let mainThread: MainThread
    private var instructions: GTK.Widget?

    init(application: UnsafeMutablePointer<GtkApplication>, runner: LinuxToolRunner,
         hotkey: LinuxHotkeyBackend, session: SessionProbe, mainThread: MainThread) {
        self.application = application
        self.runner = runner
        self.hotkey = hotkey
        self.session = session
        self.mainThread = mainThread
    }

    func accessibilityStatus() -> SetupStatus { .notApplicable }
    func portalStatus() -> SetupStatus { .unknown }

    func ydotoolStatus() -> SetupStatus {
        guard runner.executable("ydotool") != nil else { return .needsAction(fix: LinuxStrings.ydotoolMissing) }
        guard YdotoolSocket.isReachable(YdotoolSocket.path(in: runner.environment)) else {
            return .needsAction(fix: LinuxStrings.ydotoolSocketUnavailable)
        }
        return .ok
    }

    func hotkeyRegistration() -> HotkeyRegistration { hotkey.currentRegistration }

    func kdeStatus() -> SetupStatus {
        var host = session.currentSession()
        while case .flatpak(let nested) = host { host = nested }
        guard host == .kdeWayland || host == .kdeX11 else { return .notApplicable }
        return .needsAction(fix: SetupStrings.kdeShortcut + " (Added in M1d)")
    }

    func performFix(for kind: SetupRow.Kind, done: @escaping () -> Void) {
        mainThread.run {
            switch kind {
            case .ydotool:
                self.showInstructions(LinuxStrings.ydotoolFix)
                // This launches the browser asynchronously. No tool output, keys
                // or prompt text enter a URL or diagnostics.
                gtk_show_uri(nil, LinuxStrings.ydotoolDocs, 0)
            case .hotkey:
                self.showInstructions(GnomeKeybindingInstaller.command)
            case .kde:
                self.showInstructions(SetupStrings.kdeShortcut + " (Added in M1d)")
            case .portal:
                self.showInstructions(LinuxStrings.portalDeferred)
            case .accessibility:
                break
            }
            done()
        }
    }

    private func showInstructions(_ text: String) {
        let window: GTK.Widget
        if let instructions {
            window = instructions
        } else {
            window = gtk_application_window_new(application)!
            GTK.hideOnClose(window)
            gtk_window_set_title(mp_window(window), LinuxStrings.setup)
            gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), -1)
            instructions = window
        }
        let view = gtk_text_view_new()!
        gtk_text_view_set_editable(mp_text_view(view), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(view), GTK_WRAP_WORD_CHAR)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(view)), text, -1)
        gtk_window_set_child(mp_window(window), view)
        gtk_window_present(mp_window(window))
    }
}
#endif
