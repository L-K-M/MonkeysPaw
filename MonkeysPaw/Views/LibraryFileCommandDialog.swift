import AppKit

extension LibraryWindowController {
    /// The title field starts with the default title selected, so typing replaces it.
    static func configureNewPromptAlert(_ alert: NSAlert) {
        let label = LibraryCommandStrings.promptTitle
        let input = NSTextField(string: LibraryStrings.newPromptDefaultTitle)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        let caption = NSTextField(labelWithString: label)
        caption.frame = NSRect(x: 0, y: 32, width: 320, height: 20)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        input.setAccessibilityLabel(label)
        input.setAccessibilityIdentifier("library-new-prompt-title")
        container.addSubview(caption)
        container.addSubview(input)
        alert.accessoryView = container
        alert.window.initialFirstResponder = input
    }

    static func configureFileCommandAlert(_ alert: NSAlert, request: LibraryFileCommandRequest) {
        let input: NSTextField
        let label: String
        switch request.command {
        case .rename:
            input = LibraryFilenameField(string: request.filename)
            label = LibraryCommandStrings.filename
        case .move:
            let combo = NSComboBox()
            combo.isEditable = true
            combo.addItems(withObjectValues: [""] + request.folders)
            combo.stringValue = request.folder
            combo.placeholderString = LibraryDialogStrings.topLevel
            input = combo
            label = LibraryCommandStrings.folder
        case .delete: return
        }
        let container = LibraryCommandAccessory(alert: alert, request: request, input: input)
        let caption = NSTextField(labelWithString: label)
        caption.frame = NSRect(x: 0, y: 32, width: 320, height: 20)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        input.setAccessibilityLabel(label)
        input.setAccessibilityIdentifier("library-command-input")
        container.addSubview(caption)
        container.addSubview(input)
        input.delegate = container
        alert.accessoryView = container
        alert.window.initialFirstResponder = input
        container.validateInput()
    }

    static func fileCommandResponse(_ response: LibraryEditorResponse, alert: NSAlert) -> LibraryEditorResponse {
        let input = alert.window.initialFirstResponder as? NSTextField
        let text = input?.currentEditor()?.string ?? input?.stringValue ?? ""
        switch response {
        case .rename: return .rename(text)
        case .move: return .move(text)
        case .createPrompt: return .createPrompt(text)
        default: return response
        }
    }
}

/// The accessory view owns the field delegate for the sheet's lifetime.
private final class LibraryCommandAccessory: NSView, NSTextFieldDelegate {
    private weak var alert: NSAlert?
    private let request: LibraryFileCommandRequest
    private let input: NSTextField

    init(alert: NSAlert, request: LibraryFileCommandRequest, input: NSTextField) {
        self.alert = alert
        self.request = request
        self.input = input
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func controlTextDidChange(_ notification: Notification) { validateInput() }
    func validateInput() {
        guard request.command == .rename else { return }
        let value = input.currentEditor()?.string ?? input.stringValue
        alert?.buttons.first?.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.utf8.elementsEqual(request.filename.utf8)
    }
}

private final class LibraryFilenameField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let editor = currentEditor() as? NSTextView {
            let length = (stringValue as NSString).length
            editor.setSelectedRange(NSRange(location: 0, length: stringValue.hasSuffix(".md") ? max(0, length - 3) : length))
        }
        return result
    }
}
