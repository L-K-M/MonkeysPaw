import AppKit

extension NSToolbarItem.Identifier {
    static let libraryNewPrompt = Self("LibraryNewPrompt")
    static let libraryListSeparator = Self("LibraryListSeparator")
    static let libraryEditorMode = Self("LibraryEditorMode")
    static let libraryFavorite = Self("LibraryFavorite")
    static let libraryAssistant = Self("LibraryAssistant")
    static let librarySearch = Self("LibrarySearch")
    static let libraryReveal = Self("LibraryReveal")
    static let libraryImport = Self("LibraryImport")
    static let libraryDelete = Self("LibraryDelete")
}

extension LibraryWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSSearchFieldDelegate {
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // New Prompt sits over the prompt list, as Compose does in Mail and Notes.
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .libraryNewPrompt, .libraryListSeparator,
         .libraryEditorMode, .flexibleSpace, .libraryFavorite, .libraryAssistant, .librarySearch,
         .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.libraryReveal, .libraryImport, .libraryDelete, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .libraryListSeparator, let split = splitController?.splitView {
            let item = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split, dividerIndex: 1)
            item.label = LibraryStrings.editPreview
            item.paletteLabel = item.label
            item.toolTip = item.label
            return item
        }
        if identifier == .libraryEditorMode {
            let labels = [EditorStrings.editTab, EditorStrings.previewTab]
            let images = ["pencil", "eye"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() }
            let item = NSToolbarItemGroup(itemIdentifier: identifier, images: images,
                selectionMode: .selectOne, labels: labels, target: self, action: #selector(selectEditorMode(_:)))
            for (index, symbol) in ["pencil", "eye"].enumerated() {
                item.subitems[index].image = NSImage(systemSymbolName: symbol, accessibilityDescription: labels[index])
                item.subitems[index].toolTip = labels[index]
                item.subitems[index].paletteLabel = labels[index]
            }
            item.label = LibraryStrings.editPreview
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.selectedIndex = presentation.editorMode == .edit ? 0 : 1
            return item
        }
        if identifier == .librarySearch {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = LibraryStrings.search
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.searchField.placeholderString = LibraryStrings.search
            item.searchField.stringValue = presentation.snapshot.filter
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.delegate = self
            item.searchField.setAccessibilityLabel(LibraryStrings.search)
            item.searchField.setAccessibilityIdentifier("library-filter")
            item.searchField.target = self
            item.searchField.action = #selector(filterSearch(_:))
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let symbol: String
        switch identifier {
        case .libraryNewPrompt:
            item.label = LibraryNativeStrings.newPromptToolbar
            item.toolTip = LibraryCommandStrings.newPrompt
            symbol = "square.and.pencil"
            item.action = #selector(newDocument(_:))
        case .libraryFavorite:
            item.label = LibraryStrings.favourite
            item.toolTip = presentation.openPromptRow?.favorite == true ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite
            symbol = presentation.openPromptRow?.favorite == true ? "star.fill" : "star"
            item.action = #selector(toggleFavorite(_:))
        case .libraryAssistant:
            item.label = LibraryAssistantStrings.title
            symbol = "sparkles"
            item.action = #selector(showAssistant(_:))
        case .libraryReveal:
            item.label = Strings.showInFinder
            symbol = "folder"
            item.action = #selector(showInFinder(_:))
        case .libraryImport:
            item.label = ImportStrings.action
            symbol = "square.and.arrow.down"
            item.action = #selector(importFromMenu)
        case .libraryDelete:
            item.label = LibraryCommandStrings.delete
            symbol = "trash"
            item.action = #selector(deleteLibraryPrompt(_:))
        default: return nil
        }
        item.paletteLabel = item.label
        if item.toolTip == nil { item.toolTip = item.label }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.target = self
        return item
    }

    func updateToolbarItems() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .libraryFavorite }) else { return }
        let favorite = presentation.openPromptRow?.favorite == true
        item.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: LibraryStrings.favourite)
        item.toolTip = favorite ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .librarySearch {
            return commandsAvailable(in: window, context: .textInput)
        }
        if item.itemIdentifier == .libraryEditorMode {
            return commandsAvailable(in: window, context: .responderChain) && presentation.editorState.prompt != nil
        }
        guard let action = item.action else { return true }
        let menuItem = NSMenuItem(title: item.label, action: action, keyEquivalent: "")
        return validateMenuItem(menuItem)
    }

    @objc func filterSearch(_ sender: NSSearchField) { presentation.setFilter(sender.stringValue) }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        // The native cancel button and Escape can send a search action without
        // a text-edit notification. Read the field's final value in both paths.
        filterSearch(sender)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? NSSearchField, field === searchItem?.searchField,
              commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText(),
              !field.stringValue.isEmpty else { return false }
        // Consume the clear once; a second Escape can end native search editing.
        field.stringValue = ""
        textView.string = ""
        filterSearch(field)
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        // Composition stays native; filtering does not replace the field editor.
        filterSearch(field)
    }
}
