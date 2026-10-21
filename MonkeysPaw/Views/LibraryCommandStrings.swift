import Foundation
import MonkeysPawCore

/// Copy for History and the native file-command forms and outcomes.
enum LibraryCommandStrings {
    static let fileMenu = "File"
    static let rename = "Rename…"
    static let move = "Move To…"
    static let delete = "Delete…"
    static let renameButton = "Rename"
    static let moveButton = "Move"
    static let deleteButton = "Delete"
    static let cancel = "Cancel"
    static let filename = "Filename"
    static let folder = "Folder relative to the library"
    static let renameHint = "Enter a new filename. The prompt's title stays the same."
    static let moveHint = "Choose a folder or enter a new folder relative to the library. Leave it empty for the top level of the library."
    static let historyTab = "History"
    static let revisions = "Prompt revisions"
    static let historyPreview = "Read-only revision source"
    static let refreshHistory = "Refresh History"
    static let loadingHistory = "Loading history…"
    static let noHistory = "No saved revisions for this prompt."
    static let selectRevision = "Select a revision to preview it."
    static let restore = "Restore"
    static let valid = "Valid"
    static let forensic = "Forensic only"
    static let noUTF8Preview = "No preview: this revision is not UTF-8."
    static let oversizedPreview = "No preview: this revision exceeds the supported prompt size."
    static let renamed = "Renamed"
    static let moved = "Moved"
    static let moveUnavailable = "The prompt could not be moved. Check the source and destination, then try again."
    static let restored = "Restored"
    static let deleted = "Deleted. The prompt's history is kept."
    static let occupied = "The destination already exists. Choose another name or folder; no file was replaced."
    static let invalidDestination = "Enter a valid .md filename or library-relative folder. Avoid absolute paths, parent traversal and ignored names."
    static let missing = "The prompt file is missing. Resolve the deletion conflict before continuing."
    static let changed = "The prompt changed on disk. Resolve the conflict before retrying the command."
    static let inactive = "This editor session is no longer active. Reopen the prompt to try again."
    static let noSelection = "Open a prompt before using a file command."
    static let cancelled = "Cancelled. Your prompt and edits are kept."
    static let historyWarning = "The prompt was updated, but its history needs maintenance."
    static let provenanceWarning = "The prompt was updated, but its provenance record needs maintenance."
    static let historyAndProvenanceWarning = "The prompt was updated, but its history and provenance record need maintenance."
    static let relocated = "The file moved, but its destination changed or could not be checked. Resolve the conflict or check the library before retrying."

    static func renameTitle(_ filename: String) -> String { "Rename “\(filename)”" }
    static func moveTitle(_ filename: String) -> String { "Move “\(filename)”" }

    static func deleteTitle(_ path: String) -> String { "Delete “\(path)”?" }
    static func deleteHint(_ path: String) -> String {
        "The prompt is removed from your library. Its history is kept."
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func byteSize(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func restoreRefusal(_ error: PromptWriteError) -> String {
        switch error {
        case .invalidPrompt: return "Restore refused: this forensic revision is not a valid prompt."
        case .unsupportedFormat: return "Restore refused: this revision uses a newer prompt format."
        case .sourceTooLarge: return "Restore refused: this revision exceeds the supported prompt size."
        case .serializationFailed: return "Restore refused: the revision's front matter could not be serialized."
        }
    }

    static func message(_ outcome: PromptCommandOutcome, success: String) -> String {
        switch outcome {
        case .updated: return success
        case .updatedButHistoryMaintenanceFailed: return historyWarning
        case .updatedButProvenanceFailed(_, let historyFailed):
            return historyFailed ? historyAndProvenanceWarning : provenanceWarning
        case .relocated: return relocated
        case .deleted: return deleted
        case .missing: return missing
        case .destinationOccupied: return occupied
        case .conflict: return changed
        case .forensic(let reason): return restoreRefusal(reason)
        case .readOnly(let reason): return EditorStrings.readOnly(reason)
        case .failed(.fileStore(.invalidPath)), .failed(.library(.invalidPromptPath)): return invalidDestination
        case .failed(.library(.destinationOccupied)): return occupied
        case .failed(.library(.revisionNotFound)): return "The revision is missing. Refresh History and choose another revision."
        case .failed(let failure): return EditorStrings.editingFailure(failure)
        case .cancelled: return cancelled
        case .inactive: return inactive
        case .noSelection: return noSelection
        }
    }
}
