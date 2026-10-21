import MonkeysPawCore

enum LibraryDialogStrings {
    static let unsaved = "Your changes will be lost if you don't save them."
    static let revert = "Your current changes will be lost."
    static let dontSave = "Don't Save"
    static let discard = "Discard"
    static let cancel = "Cancel"
    static let keepMine = "Keep Mine"
    static let takeTheirs = "Take Theirs"
    static let saveMineAsCopy = "Save Mine as Copy"
    static let deleted = "Keep Mine recreates the file. Save as Copy keeps your edits in a new file. Discard closes this draft."
    static let modified = "Keep Mine saves over the file on disk. Take Theirs reloads it. Save Mine as Copy keeps your edits in a new file."
    static let topLevel = "Top level of the library"

    static func saveTitle(_ title: String) -> String {
        "Do you want to save the changes you made to “\(title)”?"
    }
    static func revertTitle(_ title: String) -> String { "Revert to the saved version of “\(title)”?" }
    static func conflictTitle(_ title: String, kind: EditorConflict.Kind) -> String {
        kind == .deleted ? "“\(title)” was deleted on disk" : "“\(title)” changed on disk"
    }
}
