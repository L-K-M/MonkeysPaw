import AppKit

extension LibraryWindowController {
    static func configureFileCommandAlert(_ alert: NSAlert, request: LibraryFileCommandRequest) {
        let input: NSTextField
        let label: String
        switch request.command {
        case .rename:
            input = NSTextField(string: request.filename)
            label = LibraryCommandStrings.filename
        case .move:
            let combo = NSComboBox()
            combo.isEditable = true
            combo.addItems(withObjectValues: [""] + request.folders)
            combo.stringValue = request.folder
            input = combo
            label = LibraryCommandStrings.folder
        case .delete: return
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        let caption = NSTextField(labelWithString: label)
        caption.frame = NSRect(x: 0, y: 32, width: 320, height: 20)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        input.setAccessibilityLabel(label)
        input.setAccessibilityIdentifier("library-command-input")
        container.addSubview(caption)
        container.addSubview(input)
        alert.accessoryView = container
        alert.window.initialFirstResponder = input
    }

    static func fileCommandResponse(_ response: LibraryEditorResponse, alert: NSAlert) -> LibraryEditorResponse {
        let input = alert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.last
        let text = input?.currentEditor()?.string ?? input?.stringValue ?? ""
        switch response {
        case .rename: return .rename(text)
        case .move: return .move(text)
        default: return response
        }
    }
}
