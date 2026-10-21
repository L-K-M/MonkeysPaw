import AppKit

extension AppDelegate: NSMenuItemValidation {
    func makeLibraryFileMenu() -> NSMenuItem {
        let item = NSMenuItem(title: LibraryCommandStrings.fileMenu, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: LibraryCommandStrings.fileMenu)
        let actions: [(String, Selector, String)] = [
            (LibraryCommandStrings.newPrompt, #selector(newLibraryPrompt), "n"),
            (EditorStrings.save, #selector(saveLibraryPrompt), "s"),
            (LibraryCommandStrings.rename, #selector(renameLibraryPrompt), ""),
            (LibraryCommandStrings.move, #selector(moveLibraryPrompt), ""),
            (LibraryCommandStrings.delete, #selector(deleteLibraryPrompt), ""),
            (LibraryAssistantStrings.title, #selector(showLibraryAssistant), "A")
        ]
        for (title, action, key) in actions {
            let command = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            command.target = self
            if action == #selector(showLibraryAssistant) { command.keyEquivalentModifierMask = [.command, .shift] }
        }
        item.submenu = menu
        return item
    }

    /// Explicit window input keeps hosted tests independent of native key status.
    func validateLibraryFileMenuItem(_ item: NSMenuItem, in window: NSWindow?) -> Bool {
        switch item.action {
        case #selector(newLibraryPrompt):
            guard let presentation = libraryCommandTarget(in: window),
                  (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
            return presentation.canCreatePrompt
        case #selector(saveLibraryPrompt):
            guard let presentation = libraryCommandTarget(in: window) else { return false }
            return presentation.canSave || presentation.canShowConflict
        case #selector(renameLibraryPrompt), #selector(moveLibraryPrompt), #selector(deleteLibraryPrompt):
            return libraryCommandTarget(in: window)?.canRunFileCommand == true
        case #selector(showLibraryAssistant):
            guard let presentation = libraryCommandTarget(in: window) else { return false }
            return presentation.isAssistantVisible || presentation.canShowAssistant
        default: return false
        }
    }

    @objc func newLibraryPrompt() {
        guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        libraryCommandTarget(in: NSApp.keyWindow)?.requestNewPrompt()
    }
    @objc func saveLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.save() }
    @objc func renameLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.rename) }
    @objc func moveLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.move) }
    @objc func deleteLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.delete) }
    @objc func showLibraryAssistant() { libraryCommandTarget(in: NSApp.keyWindow)?.toggleAssistant() }

    private func libraryCommandTarget(in candidate: NSWindow?) -> LibraryViewState? {
        guard let window = libraryWindow?.window, candidate === window, window.isVisible,
              window.attachedSheet == nil, libraryWindow?.presentation.fileCommandRequest == nil,
              libraryWindow?.presentation.newPromptRequest == nil,
              libraryWindow?.presentation.isScopeDropPending == false else { return nil }
        return libraryWindow?.presentation
    }
}
