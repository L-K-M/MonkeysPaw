import AppKit
import MonkeysPawCore

struct PasteboardClipboard: Clipboard {
    func writeText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
