import AppKit

extension AppDelegate: NSMenuItemValidation {
    func makeLibraryFileMenu() -> NSMenuItem {
        let item = NSMenuItem(title: LibraryCommandStrings.fileMenu, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: LibraryCommandStrings.fileMenu)
        let actions: [(String, Selector, String)] = [
            (EditorStrings.save, #selector(saveLibraryPrompt), "s"),
            (LibraryCommandStrings.rename, #selector(renameLibraryPrompt), ""),
            (LibraryCommandStrings.move, #selector(moveLibraryPrompt), ""),
            (LibraryCommandStrings.delete, #selector(deleteLibraryPrompt), "")
        ]
        for (title, action, key) in actions {
            let command = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            command.target = self
        }
        item.submenu = menu
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateLibraryFileMenuItem(menuItem, in: NSApp.keyWindow)
    }

    /// Explicit window input keeps hosted tests independent of native key status.
    func validateLibraryFileMenuItem(_ item: NSMenuItem, in window: NSWindow?) -> Bool {
        switch item.action {
        case #selector(saveLibraryPrompt):
            guard let presentation = libraryCommandTarget(in: window) else { return false }
            return presentation.canSave || presentation.canShowConflict
        case #selector(renameLibraryPrompt), #selector(moveLibraryPrompt), #selector(deleteLibraryPrompt):
            return libraryCommandTarget(in: window)?.canRunFileCommand == true
        default: return true
        }
    }

    @objc func saveLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.save() }
    @objc func renameLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.rename) }
    @objc func moveLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.move) }
    @objc func deleteLibraryPrompt() { libraryCommandTarget(in: NSApp.keyWindow)?.requestFileCommand(.delete) }

    private func libraryCommandTarget(in candidate: NSWindow?) -> LibraryViewState? {
        guard let window = libraryWindow?.window, candidate === window, window.isVisible,
              window.attachedSheet == nil, libraryWindow?.presentation.fileCommandRequest == nil else { return nil }
        return libraryWindow?.presentation
    }
}
