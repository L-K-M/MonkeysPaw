import AppKit
import MonkeysPawCore

struct PasteboardClipboard: Clipboard {
    /// Invoked inline on the caller's AppKit UI thread.
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        let text = NSPasteboard.general.string(forType: .string)
        completion(text.flatMap { $0.isEmpty ? nil : $0 })
    }

    func writeText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
