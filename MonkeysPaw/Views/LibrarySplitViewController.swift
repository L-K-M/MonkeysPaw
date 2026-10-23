import AppKit

/// Native sidebar/inspector actions are handled before the window controller in
/// the responder chain, so they share its sheet and input-method validation.
final class LibrarySplitViewController: NSSplitViewController, NSMenuItemValidation, NSToolbarItemValidation {
    var validateCommand: ((NSMenuItem) -> Bool)?
    var onToggleSidebar: (() -> Void)?
    var onToggleInspector: (() -> Void)?

    override func toggleSidebar(_ sender: Any?) {
        let item = NSMenuItem(title: LibraryStrings.showSidebar, action: #selector(toggleSidebar(_:)), keyEquivalent: "")
        guard validateCommand?(item) == true else { return }
        if let onToggleSidebar { onToggleSidebar(); return }
        super.toggleSidebar(sender)
    }

    override func toggleInspector(_ sender: Any?) {
        let item = NSMenuItem(title: LibraryStrings.showInspector, action: #selector(toggleInspector(_:)), keyEquivalent: "")
        guard validateCommand?(item) == true else { return }
        if let onToggleInspector { onToggleInspector(); return }
        super.toggleInspector(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validateCommand?(item) == true }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        let enabled = validateCommand?(menuItem) == true
        item.toolTip = menuItem.title
        return enabled
    }
}
