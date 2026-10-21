import MonkeysPawCore

/// Menu-bar copy for the native main menu (§24.4). Titles that already live in
/// another strings table are reused; validation rewrites stateful titles such
/// as Favourite, Sidebar, Inspector and Toolbar at display time.
enum MainMenuStrings {
    static let appMenu = AppIdentity.displayName
    static let about = "About \(AppIdentity.displayName)"
    static let checkForUpdates = "Check for Updates…"
    static let settings = Strings.settings
    static let services = "Services"
    static let hide = "Hide \(AppIdentity.displayName)"
    static let hideOthers = "Hide Others"
    static let showAll = "Show All"
    static let quit = "Quit \(AppIdentity.displayName)"

    static let file = LibraryCommandStrings.fileMenu
    static let importPrompts = ImportStrings.action
    static let close = "Close"
    static let save = EditorStrings.save
    static let duplicate = "Duplicate"
    static let rename = LibraryCommandStrings.rename
    static let moveTo = "Move To…"
    static let revertToSaved = "Revert to Saved"
    static let showInFinder = Strings.showInFinder
    static let deletePrompt = LibraryCommandStrings.delete

    static let edit = Strings.edit
    static let undo = "Undo"
    static let redo = "Redo"
    static let cut = "Cut"
    static let copy = Strings.copy
    static let paste = "Paste"
    static let pasteAndMatchStyle = "Paste and Match Style"
    static let delete = "Delete"
    static let selectAll = "Select All"

    static let find = "Find"
    static let findItem = "Find…"
    static let findNext = "Find Next"
    static let findPrevious = "Find Previous"
    static let useSelectionForFind = "Use Selection for Find"
    static let jumpToSelection = "Jump to Selection"
    static let searchLibrary = "Search Library"

    static let spellingAndGrammar = "Spelling and Grammar"
    static let showSpellingAndGrammar = "Show Spelling and Grammar"
    static let checkDocumentNow = "Check Document Now"
    static let checkSpellingWhileTyping = "Check Spelling While Typing"
    static let checkGrammarWithSpelling = "Check Grammar With Spelling"

    static let substitutions = "Substitutions"
    static let smartQuotes = "Smart Quotes"
    static let smartDashes = "Smart Dashes"
    static let textReplacement = "Text Replacement"

    static let view = "View"
    static let editMode = EditorStrings.editTab
    static let previewMode = EditorStrings.previewTab
    static let showSidebar = LibraryStrings.showSidebar
    static let showInspector = LibraryStrings.showInspector
    static let fields = EditorStrings.fieldsTab
    static let history = LibraryCommandStrings.historyTab
    static let assistant = LibraryAssistantStrings.title
    static let showToolbar = LibraryStrings.showToolbar
    static let customizeToolbar = "Customize Toolbar…"

    static let prompt = "Prompt"
    static let addFavorite = LibraryStrings.addFavorite
    static let reviewWithAssistant = "Review with Assistant"
    static let improveWithAssistant = "Improve with Assistant"
    static let writeWithAssistant = "Write with Assistant…"

    static let window = "Window"
    static let minimize = "Minimize"
    static let zoom = "Zoom"
    static let library = Strings.library
    static let bringAllToFront = "Bring All to Front"

    static let help = "Help"
    static let appHelp = "\(AppIdentity.displayName) Help"
}
