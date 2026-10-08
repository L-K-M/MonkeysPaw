import AppKit

/// An AppKit lifecycle keeps control of the non-activating, all-Spaces panel.
@main
enum MonkeysPawApp {
    // NSApplication.delegate is weak, so retain the composition root for the
    // process lifetime rather than leaving it in a local variable.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
