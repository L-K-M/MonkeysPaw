import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Structural checks for the native menu bar (§24.4). Titles that validation
/// rewrites are asserted at their initial values; enablement belongs to the
/// window-controller and delegate tests that drive a real responder chain.
final class MacMainMenuTests: XCTestCase {
    private var originalMainMenu: NSMenu?
    private var originalServicesMenu: NSMenu?
    private var originalWindowsMenu: NSMenu?
    private var originalHelpMenu: NSMenu?

    override func setUp() {
        originalMainMenu = NSApp.mainMenu
        originalServicesMenu = NSApp.servicesMenu
        originalWindowsMenu = NSApp.windowsMenu
        originalHelpMenu = NSApp.helpMenu
    }

    override func tearDown() {
        NSApp.mainMenu = originalMainMenu
        NSApp.servicesMenu = originalServicesMenu
        NSApp.windowsMenu = originalWindowsMenu
        NSApp.helpMenu = originalHelpMenu
    }

    private func submenu(_ main: NSMenu, _ title: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> NSMenu {
        try XCTUnwrap(main.items.first { $0.title == title }?.submenu,
                      "Missing submenu \(title)", file: file, line: line)
    }

    private func row(_ menu: NSMenu, _ title: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title },
                      "Missing item \(title)", file: file, line: line)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func check(_ item: NSMenuItem, action: String, key: String,
                       modifiers: NSEvent.ModifierFlags,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.action, Selector((action)), item.title, file: file, line: line)
        XCTAssertNil(item.target, "\(item.title) must reach the responder chain", file: file, line: line)
        XCTAssertEqual(item.keyEquivalent, key, item.title, file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, item.title, file: file, line: line)
    }

    private func checkEveryItemRoutesThroughTheResponderChain(_ menu: NSMenu,
                                                              file: StaticString = #filePath,
                                                              line: UInt = #line) {
        for item in menu.items {
            // AppKit targets a submenu's parent item at that submenu.
            if let submenu = item.submenu {
                checkEveryItemRoutesThroughTheResponderChain(submenu, file: file, line: line)
                continue
            }
            XCTAssertNil(item.target, "\(item.title) should have no explicit target",
                         file: file, line: line)
        }
    }

    func testTopLevelMenusMatchTheDesignOrder() {
        XCTAssertEqual(titles(MainMenu.make()),
            [MainMenuStrings.appMenu, MainMenuStrings.file, MainMenuStrings.edit,
             MainMenuStrings.view, MainMenuStrings.prompt, MainMenuStrings.window,
             MainMenuStrings.help])
    }

    func testAppMenuItemsCarryStandardActionsAndKeys() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.appMenu)
        XCTAssertEqual(titles(menu), [MainMenuStrings.about, MainMenuStrings.checkForUpdates, "-",
            MainMenuStrings.settings, "-", MainMenuStrings.services, "-", MainMenuStrings.hide,
            MainMenuStrings.hideOthers, MainMenuStrings.showAll, "-", MainMenuStrings.quit])
        try check(row(menu, MainMenuStrings.about), action: "showAboutPanel:",
                  key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.checkForUpdates), action: "checkForUpdates:",
                  key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.settings), action: "showSettings",
                  key: ",", modifiers: .command)
        try check(row(menu, MainMenuStrings.hide), action: "hide:", key: "h", modifiers: .command)
        try check(row(menu, MainMenuStrings.hideOthers), action: "hideOtherApplications:",
                  key: "h", modifiers: [.command, .option])
        try check(row(menu, MainMenuStrings.showAll), action: "unhideAllApplications:",
                  key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.quit), action: "terminate:", key: "q", modifiers: .command)
        XCTAssertNotNil(try row(menu, MainMenuStrings.services).submenu)
    }

    func testFileMenuItemsCarryLibraryDocumentActions() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.file)
        XCTAssertEqual(titles(menu), [MainMenuStrings.newPrompt, MainMenuStrings.importPrompts, "-", MainMenuStrings.close,
            MainMenuStrings.save, MainMenuStrings.duplicate, MainMenuStrings.rename,
            MainMenuStrings.moveTo, MainMenuStrings.revertToSaved, "-",
            MainMenuStrings.showInFinder, "-", MainMenuStrings.deletePrompt])
        let creation = try submenu(menu, MainMenuStrings.newPrompt)
        let parent = try row(menu, MainMenuStrings.newPrompt)
        XCTAssertNotEqual(parent.action, #selector(LibraryWindowController.newDocument(_:)))
        XCTAssertTrue(parent.keyEquivalent.isEmpty)
        XCTAssertEqual(titles(creation), [MainMenuStrings.blankPrompt, MainMenuStrings.generatePrompt])
        try check(row(creation, MainMenuStrings.blankPrompt), action: "newDocument:", key: "n", modifiers: .command)
        try check(row(creation, MainMenuStrings.generatePrompt), action: "writeWithAssistant:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.importPrompts), action: "importFromMenu",
                  key: "i", modifiers: [.command, .shift])
        try check(row(menu, MainMenuStrings.close), action: "performClose:", key: "w", modifiers: .command)
        try check(row(menu, MainMenuStrings.save), action: "saveDocument:", key: "s", modifiers: .command)
        try check(row(menu, MainMenuStrings.duplicate), action: "duplicateDocument:",
                  key: "s", modifiers: [.command, .shift])
        try check(row(menu, MainMenuStrings.rename), action: "renameDocument:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.moveTo), action: "moveDocument:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.revertToSaved), action: "revertDocumentToSaved:",
                  key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.showInFinder), action: "showInFinder:",
                  key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.deletePrompt), action: "deleteLibraryPrompt:",
                  key: "", modifiers: .command)
    }

    func testEditMenuItemsCarryTextActions() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.edit)
        XCTAssertEqual(titles(menu), [MainMenuStrings.undo, MainMenuStrings.redo, "-",
            MainMenuStrings.cut, MainMenuStrings.copy, MainMenuStrings.paste,
            MainMenuStrings.pasteAndMatchStyle, MainMenuStrings.delete, MainMenuStrings.selectAll,
            "-", MainMenuStrings.find, MainMenuStrings.spellingAndGrammar, MainMenuStrings.substitutions])
        try check(row(menu, MainMenuStrings.undo), action: "undo:", key: "z", modifiers: .command)
        try check(row(menu, MainMenuStrings.redo), action: "redo:", key: "z", modifiers: [.command, .shift])
        try check(row(menu, MainMenuStrings.cut), action: "cut:", key: "x", modifiers: .command)
        try check(row(menu, MainMenuStrings.copy), action: "copy:", key: "c", modifiers: .command)
        try check(row(menu, MainMenuStrings.paste), action: "paste:", key: "v", modifiers: .command)
        try check(row(menu, MainMenuStrings.pasteAndMatchStyle), action: "pasteAsPlainText:",
                  key: "v", modifiers: [.command, .option, .shift])
        try check(row(menu, MainMenuStrings.delete), action: "delete:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.selectAll), action: "selectAll:", key: "a", modifiers: .command)
    }

    func testFindSubmenuCarriesFindPanelActionsAndTags() throws {
        let editMenu = try submenu(MainMenu.make(), MainMenuStrings.edit)
        let menu = try XCTUnwrap(row(editMenu, MainMenuStrings.find).submenu)
        XCTAssertEqual(titles(menu), [MainMenuStrings.findItem, MainMenuStrings.findNext,
            MainMenuStrings.findPrevious, "-", MainMenuStrings.useSelectionForFind,
            MainMenuStrings.jumpToSelection, "-", MainMenuStrings.searchLibrary])
        let find = try row(menu, MainMenuStrings.findItem)
        check(find, action: "performFindPanelAction:", key: "f", modifiers: .command)
        XCTAssertEqual(find.tag, NSTextFinder.Action.showFindInterface.rawValue)
        let next = try row(menu, MainMenuStrings.findNext)
        check(next, action: "performFindPanelAction:", key: "g", modifiers: .command)
        XCTAssertEqual(next.tag, NSTextFinder.Action.nextMatch.rawValue)
        let previous = try row(menu, MainMenuStrings.findPrevious)
        check(previous, action: "performFindPanelAction:", key: "g", modifiers: [.command, .shift])
        XCTAssertEqual(previous.tag, NSTextFinder.Action.previousMatch.rawValue)
        let selection = try row(menu, MainMenuStrings.useSelectionForFind)
        check(selection, action: "performFindPanelAction:", key: "e", modifiers: .command)
        XCTAssertEqual(selection.tag, NSTextFinder.Action.setSearchString.rawValue)
        try check(row(menu, MainMenuStrings.jumpToSelection), action: "centerSelectionInVisibleArea:",
                  key: "j", modifiers: .command)
        try check(row(menu, MainMenuStrings.searchLibrary), action: "searchLibrary:",
                  key: "f", modifiers: [.command, .option])
    }

    func testSpellingAndSubstitutionsSubmenusUseStandardToggles() throws {
        let editMenu = try submenu(MainMenu.make(), MainMenuStrings.edit)
        let spelling = try XCTUnwrap(row(editMenu, MainMenuStrings.spellingAndGrammar).submenu)
        XCTAssertEqual(titles(spelling), [MainMenuStrings.showSpellingAndGrammar,
            MainMenuStrings.checkDocumentNow, "-", MainMenuStrings.checkSpellingWhileTyping,
            MainMenuStrings.checkGrammarWithSpelling])
        try check(row(spelling, MainMenuStrings.showSpellingAndGrammar), action: "showGuessPanel:",
                  key: ":", modifiers: .command)
        try check(row(spelling, MainMenuStrings.checkDocumentNow), action: "checkSpelling:",
                  key: ";", modifiers: .command)
        try check(row(spelling, MainMenuStrings.checkSpellingWhileTyping),
                  action: "toggleContinuousSpellChecking:", key: "", modifiers: .command)
        try check(row(spelling, MainMenuStrings.checkGrammarWithSpelling),
                  action: "toggleGrammarChecking:", key: "", modifiers: .command)

        let substitutions = try XCTUnwrap(row(editMenu, MainMenuStrings.substitutions).submenu)
        XCTAssertEqual(titles(substitutions), [MainMenuStrings.smartQuotes, MainMenuStrings.smartDashes,
            MainMenuStrings.textReplacement])
        try check(row(substitutions, MainMenuStrings.smartQuotes),
                  action: "toggleAutomaticQuoteSubstitution:", key: "", modifiers: .command)
        try check(row(substitutions, MainMenuStrings.smartDashes),
                  action: "toggleAutomaticDashSubstitution:", key: "", modifiers: .command)
        try check(row(substitutions, MainMenuStrings.textReplacement),
                  action: "toggleAutomaticTextReplacement:", key: "", modifiers: .command)
    }

    func testViewMenuItemsCarryPaneAndToolbarActions() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.view)
        XCTAssertEqual(titles(menu), [MainMenuStrings.editMode, MainMenuStrings.previewMode, LibraryFormStrings.source,
            LibraryFormStrings.showDetails, "-",
            MainMenuStrings.showSidebar, MainMenuStrings.showInspector, MainMenuStrings.fields,
            MainMenuStrings.history, MainMenuStrings.assistant, "-", MainMenuStrings.showToolbar,
            MainMenuStrings.customizeToolbar])
        try check(row(menu, MainMenuStrings.editMode), action: "showEdit:", key: "1", modifiers: .command)
        try check(row(menu, MainMenuStrings.previewMode), action: "showPreview:", key: "2", modifiers: .command)
        try check(row(menu, LibraryFormStrings.source), action: "showSource:", key: "3", modifiers: .command)
        try check(row(menu, LibraryFormStrings.showDetails), action: "togglePromptDetails:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.showSidebar), action: "toggleSidebar:",
                  key: "s", modifiers: [.control, .command])
        try check(row(menu, MainMenuStrings.showInspector), action: "toggleInspector:",
                  key: "i", modifiers: [.command, .option])
        try check(row(menu, MainMenuStrings.fields), action: "showFields:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.history), action: "showHistory:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.assistant), action: "showAssistant:",
                  key: "a", modifiers: [.command, .shift])
        try check(row(menu, MainMenuStrings.showToolbar), action: "toggleToolbarShown:",
                  key: "t", modifiers: [.command, .option])
        try check(row(menu, MainMenuStrings.customizeToolbar), action: "runToolbarCustomizationPalette:",
                  key: "", modifiers: .command)
    }

    func testPromptMenuItemsCarryPromptActions() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.prompt)
        XCTAssertEqual(titles(menu), [MainMenuStrings.addFavorite, "-",
            MainMenuStrings.reviewWithAssistant, MainMenuStrings.improveWithAssistant])
        try check(row(menu, MainMenuStrings.addFavorite), action: "toggleFavorite:",
                  key: "d", modifiers: .command)
        try check(row(menu, MainMenuStrings.reviewWithAssistant), action: "reviewWithAssistant:",
                  key: "r", modifiers: .command)
        try check(row(menu, MainMenuStrings.improveWithAssistant), action: "improveWithAssistant:",
                  key: "i", modifiers: .command)
    }

    func testWindowMenuItemsCarryWindowActions() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.window)
        XCTAssertEqual(titles(menu), [MainMenuStrings.minimize, MainMenuStrings.zoom, "-",
            MainMenuStrings.library, "-", MainMenuStrings.bringAllToFront])
        try check(row(menu, MainMenuStrings.minimize), action: "performMiniaturize:",
                  key: "m", modifiers: .command)
        try check(row(menu, MainMenuStrings.zoom), action: "performZoom:", key: "", modifiers: .command)
        try check(row(menu, MainMenuStrings.library), action: "showLibrary", key: "l", modifiers: .command)
        try check(row(menu, MainMenuStrings.bringAllToFront), action: "arrangeInFront:",
                  key: "", modifiers: .command)
    }

    func testHelpMenuItemOpensHelp() throws {
        let menu = try submenu(MainMenu.make(), MainMenuStrings.help)
        XCTAssertEqual(titles(menu), [MainMenuStrings.appHelp])
        try check(row(menu, MainMenuStrings.appHelp), action: "openHelp:", key: "", modifiers: .command)
    }

    func testNoItemTargetsAnythingDirectly() {
        checkEveryItemRoutesThroughTheResponderChain(MainMenu.make())
    }

    func testInstallRegistersMainServicesWindowAndHelpMenus() throws {
        MainMenu.install()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try submenu(main, MainMenuStrings.appMenu)
        let servicesItem = try row(appMenu, MainMenuStrings.services)
        XCTAssertNotNil(servicesItem.submenu)
        // AppKit owns the Services menu it was given and may substitute its own instance.
        XCTAssertNotNil(NSApp.servicesMenu)
        XCTAssertTrue(NSApp.windowsMenu === (try submenu(main, MainMenuStrings.window)))
        XCTAssertTrue(NSApp.helpMenu === (try submenu(main, MainMenuStrings.help)))
    }
}
