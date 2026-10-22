import AppKit

extension AppDelegate: NSMenuItemValidation {
    /// Explicit-window validation is shared with hosted tests; actions themselves
    /// now belong to the Library controller in the responder chain.
    func validateLibraryFileMenuItem(_ item: NSMenuItem, in window: NSWindow?) -> Bool {
        libraryWindow?.validateLibraryMenuItem(item, in: window) == true
    }
}
