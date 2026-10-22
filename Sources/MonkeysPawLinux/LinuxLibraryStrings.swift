#if os(Linux)
import MonkeysPawCore

enum LinuxLibraryStrings {
    static let sidebar = "Show Sidebar"
    static let inspector = "Show Inspector"
    static let search = "Search Library"
    static let menu = "Library Menu"
    static let duplicate = "Duplicate"
    static let revert = "Revert to Saved"
    static let showFiles = "Show in Files"
    static let importFiles = "Import Files…"
    static let importFolder = "Import Folder…"
    static let importInto = "Import into"
    static let chooseFiles = "Choose Files…"
    static let chooseFolder = "Choose Folder…"
    static let library = "Library"
    static let groups = "Groups"
    static let folders = "Folders"
    static let tags = "Tags"
    static let valid = "Valid"
    static let favorite = "Favourite"
    static let comparison = "Comparison"
    static let newerEdits = " Newer edits are unsaved."

    static func count(_ count: Int) -> String { "\(count) " + (count == 1 ? "prompt" : "prompts") }
    static func subtitle(path: String, dirty: Bool) -> String { path + (dirty ? " — Edited" : "") }
    static func issues(_ count: Int) -> String { count == 0 ? valid : "\(count) " + (count == 1 ? "issue" : "issues") }
    static func field(_ field: PromptField) -> String {
        [field.label, field.description, field.kind.rawValue.capitalized,
         "Default: " + field.defaultValue,
         field.options.isEmpty ? nil : "Options: " + field.options.map { $0.label + " = " + $0.value }.joined(separator: ", "),
         LinuxEditorStrings.behavior(field).replacingOccurrences(of: "\n", with: " · ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
#endif
