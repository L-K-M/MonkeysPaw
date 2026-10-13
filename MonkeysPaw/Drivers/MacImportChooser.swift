import AppKit
import UniformTypeIdentifiers

enum MacImportChooser {
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = ImportStrings.chooserTitle
        panel.prompt = ImportStrings.choose
        panel.message = ImportStrings.chooserMessage
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = ["md", "prompt", "prompty"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        return panel
    }

    static func choose(in window: NSWindow, done: @escaping ([URL]) -> Void) -> (() -> Void) {
        let panel = makePanel()
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.urls : []) }
        return { panel.cancel(nil) }
    }
}
