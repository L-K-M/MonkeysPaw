import AppKit
import MonkeysPawCore

/// The native menu bar (§24.4). Items keep a nil target so the responder chain
/// reaches the focused text view, the Library window controller, or the app
/// delegate; validation there decides enablement and rewrites stateful titles.
enum MainMenu {
    /// Installs the menus AppKit manages: the main menu plus the registered
    /// Services, Window and Help menus.
    static func install() {
        let menus = build()
        NSApp.mainMenu = menus.main
        NSApp.servicesMenu = menus.services
        NSApp.windowsMenu = menus.windows
        NSApp.helpMenu = menus.help
    }

    /// Pure construction lets hosted tests inspect the menu without touching
    /// NSApp. install() registers the submenus this also builds.
    static func make() -> NSMenu { build().main }

    private struct Built {
        let main: NSMenu
        let services: NSMenu
        let windows: NSMenu
        let help: NSMenu
    }

    private static func build() -> Built {
        let services = NSMenu(title: MainMenuStrings.services)
        let windows = NSMenu(title: MainMenuStrings.window)
        let help = NSMenu(title: MainMenuStrings.help)

        let main = NSMenu()
        main.addItem(topLevel(AppIdentity.displayName, menu: appMenu(services)))
        main.addItem(topLevel(MainMenuStrings.file, menu: fileMenu()))
        main.addItem(topLevel(MainMenuStrings.edit, menu: editMenu()))
        main.addItem(topLevel(MainMenuStrings.view, menu: viewMenu()))
        main.addItem(topLevel(MainMenuStrings.prompt, menu: promptMenu()))
        fillWindowMenu(windows)
        main.addItem(topLevel(MainMenuStrings.window, menu: windows))
        fillHelpMenu(help)
        main.addItem(topLevel(MainMenuStrings.help, menu: help))
        return Built(main: main, services: services, windows: windows, help: help)
    }

    private static func topLevel(_ title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Every command declares its modifier mask, including the default Command.
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                            _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                            tag: Int = 0) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func appMenu(_ services: NSMenu) -> NSMenu {
        let menu = NSMenu(title: AppIdentity.displayName)
        add(menu, MainMenuStrings.about, #selector(AppDelegate.showAboutPanel(_:)))
        add(menu, MainMenuStrings.checkForUpdates, #selector(AppDelegate.checkForUpdates(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.settings, #selector(AppDelegate.showSettings), ",")
        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: MainMenuStrings.services, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        add(menu, MainMenuStrings.hide, #selector(NSApplication.hide(_:)), "h")
        add(menu, MainMenuStrings.hideOthers, #selector(NSApplication.hideOtherApplications(_:)),
            "h", [.command, .option])
        add(menu, MainMenuStrings.showAll, #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.quit, #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.file)
        add(menu, MainMenuStrings.newPrompt, #selector(LibraryWindowController.newDocument(_:)), "n")
        add(menu, MainMenuStrings.importPrompts,
            #selector(LibraryWindowController.importFromMenu), "i", [.command, .shift])
        menu.addItem(.separator())
        add(menu, MainMenuStrings.close, #selector(NSWindow.performClose(_:)), "w")
        add(menu, MainMenuStrings.save, #selector(LibraryWindowController.saveDocument(_:)), "s")
        add(menu, MainMenuStrings.duplicate, #selector(LibraryWindowController.duplicateDocument(_:)),
            "s", [.command, .shift])
        add(menu, MainMenuStrings.rename, #selector(LibraryWindowController.renameDocument(_:)))
        add(menu, MainMenuStrings.moveTo, #selector(LibraryWindowController.moveDocument(_:)))
        add(menu, MainMenuStrings.revertToSaved, #selector(LibraryWindowController.revertDocumentToSaved(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.showInFinder, #selector(LibraryWindowController.showInFinder(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.deletePrompt, #selector(LibraryWindowController.deleteLibraryPrompt(_:)))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.edit)
        add(menu, MainMenuStrings.undo, Selector(("undo:")), "z")
        add(menu, MainMenuStrings.redo, Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, MainMenuStrings.cut, #selector(NSText.cut(_:)), "x")
        add(menu, MainMenuStrings.copy, #selector(NSText.copy(_:)), "c")
        add(menu, MainMenuStrings.paste, #selector(NSText.paste(_:)), "v")
        add(menu, MainMenuStrings.pasteAndMatchStyle, #selector(NSTextView.pasteAsPlainText(_:)),
            "v", [.command, .option, .shift])
        add(menu, MainMenuStrings.delete, #selector(NSText.delete(_:)))
        add(menu, MainMenuStrings.selectAll,
            #selector(NSStandardKeyBindingResponding.selectAll(_:)), "a")
        menu.addItem(.separator())
        menu.addItem(topLevel(MainMenuStrings.find, menu: findMenu()))
        menu.addItem(topLevel(MainMenuStrings.spellingAndGrammar, menu: spellingMenu()))
        menu.addItem(topLevel(MainMenuStrings.substitutions, menu: substitutionsMenu()))
        return menu
    }

    /// The find-panel tags are the shared NSTextFinder.Action values; the
    /// source editor and the Library controller route them to the find bar.
    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.find)
        let findAction = Selector(("performFindPanelAction:"))
        add(menu, MainMenuStrings.findItem, findAction, "f",
            tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(menu, MainMenuStrings.findNext, findAction, "g",
            tag: NSTextFinder.Action.nextMatch.rawValue)
        add(menu, MainMenuStrings.findPrevious, findAction, "g", [.command, .shift],
            tag: NSTextFinder.Action.previousMatch.rawValue)
        menu.addItem(.separator())
        add(menu, MainMenuStrings.useSelectionForFind, findAction, "e",
            tag: NSTextFinder.Action.setSearchString.rawValue)
        add(menu, MainMenuStrings.jumpToSelection, Selector(("centerSelectionInVisibleArea:")), "j")
        menu.addItem(.separator())
        add(menu, MainMenuStrings.searchLibrary, #selector(LibraryWindowController.searchLibrary(_:)),
            "f", [.command, .option])
        return menu
    }

    private static func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.spellingAndGrammar)
        add(menu, MainMenuStrings.showSpellingAndGrammar, Selector(("showGuessPanel:")), ":")
        add(menu, MainMenuStrings.checkDocumentNow, Selector(("checkSpelling:")), ";")
        menu.addItem(.separator())
        add(menu, MainMenuStrings.checkSpellingWhileTyping, Selector(("toggleContinuousSpellChecking:")))
        add(menu, MainMenuStrings.checkGrammarWithSpelling, Selector(("toggleGrammarChecking:")))
        return menu
    }

    private static func substitutionsMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.substitutions)
        add(menu, MainMenuStrings.smartQuotes, Selector(("toggleAutomaticQuoteSubstitution:")))
        add(menu, MainMenuStrings.smartDashes, Selector(("toggleAutomaticDashSubstitution:")))
        add(menu, MainMenuStrings.textReplacement, Selector(("toggleAutomaticTextReplacement:")))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.view)
        add(menu, MainMenuStrings.editMode, #selector(LibraryWindowController.showEdit(_:)), "1")
        add(menu, MainMenuStrings.previewMode, #selector(LibraryWindowController.showPreview(_:)), "2")
        add(menu, LibraryFormStrings.source, #selector(LibraryWindowController.showSource(_:)), "3")
        add(menu, LibraryFormStrings.showDetails, #selector(LibraryWindowController.togglePromptDetails(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.showSidebar, Selector(("toggleSidebar:")), "s", [.control, .command])
        add(menu, MainMenuStrings.showInspector, Selector(("toggleInspector:")), "i", [.command, .option])
        add(menu, MainMenuStrings.fields, #selector(LibraryWindowController.showFields(_:)))
        add(menu, MainMenuStrings.history, #selector(LibraryWindowController.showHistory(_:)))
        add(menu, MainMenuStrings.assistant, #selector(LibraryWindowController.showAssistant(_:)),
            "a", [.command, .shift])
        menu.addItem(.separator())
        add(menu, MainMenuStrings.showToolbar, #selector(NSWindow.toggleToolbarShown(_:)),
            "t", [.command, .option])
        add(menu, MainMenuStrings.customizeToolbar,
            #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        // AppKit adds Enter Full Screen for the fullScreenPrimary Library.
        return menu
    }

    private static func promptMenu() -> NSMenu {
        let menu = NSMenu(title: MainMenuStrings.prompt)
        add(menu, MainMenuStrings.addFavorite, #selector(LibraryWindowController.toggleFavorite(_:)), "d")
        menu.addItem(.separator())
        add(menu, MainMenuStrings.reviewWithAssistant,
            #selector(LibraryWindowController.reviewWithAssistant(_:)), "r")
        add(menu, MainMenuStrings.improveWithAssistant,
            #selector(LibraryWindowController.improveWithAssistant(_:)), "i")
        add(menu, MainMenuStrings.writeWithAssistant,
            #selector(LibraryWindowController.writeWithAssistant(_:)))
        return menu
    }

    /// Registered as NSApp.windowsMenu; AppKit appends the open-window list.
    private static func fillWindowMenu(_ menu: NSMenu) {
        add(menu, MainMenuStrings.minimize, #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, MainMenuStrings.zoom, #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, MainMenuStrings.library, #selector(AppDelegate.showLibrary), "l")
        menu.addItem(.separator())
        add(menu, MainMenuStrings.bringAllToFront, Selector(("arrangeInFront:")))
    }

    /// Registered as NSApp.helpMenu; AppKit inserts the Help search item.
    private static func fillHelpMenu(_ menu: NSMenu) {
        add(menu, MainMenuStrings.appHelp, #selector(AppDelegate.openHelp(_:)))
    }
}
