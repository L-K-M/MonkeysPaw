import AppKit
import Darwin

/// An AppKit lifecycle keeps control of the non-activating, all-Spaces panel.
@main
enum MonkeysPawApp {
    // NSApplication.delegate is weak, so retain the composition root for the
    // process lifetime rather than leaving it in a local variable.
    private static let delegate = AppDelegate()

    static func main() {
        // Closed log pipes or helpers that stop reading stdin must surface
        // EPIPE to the writer instead of terminating the app with SIGPIPE.
        _ = Darwin.signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
