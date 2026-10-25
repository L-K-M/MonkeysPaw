#if os(Linux)

/// Footer key-hint labels for the picker. The shortcut prefix mirrors the
/// LinuxPickerKeys bindings, so the footer buttons double as the key-hint
/// row (§24.5); accessibility labels stay on the plain action names.
enum LinuxPickerStrings {
    static let useHint = "↵ " + LinuxStrings.usePrompt
    static let deliverHint = "↵ " + LinuxStrings.deliver
    static let copyHint = "Alt+↵ " + LinuxStrings.copy
    static let editHint = "Ctrl+↵ " + LinuxStrings.edit
    static let libraryHint = "Ctrl+L " + LinuxStrings.library
    static let proofHint = "Ctrl+P Proof"
    static let escapePicker = "Esc: close"
    static let escapeFill = "Esc: back"
    static let moreActions = "More actions"
}
#endif
