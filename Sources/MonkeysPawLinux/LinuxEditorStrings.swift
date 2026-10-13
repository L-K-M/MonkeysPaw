#if os(Linux)
import Foundation
import MonkeysPawCore

enum LinuxEditorStrings {
    static let fields = "Fields"
    static let parsedFields = "Parsed prompt fields"
    static let noFields = "No fields in this prompt."
    static let fieldColumns = ["Name / label", "Type", "Default", "Options", "Behavior"]
    static func behavior(_ field: PromptField) -> String {
        [field.optional ? "Optional" : "Required", field.remember ? "Remembered" : "Not remembered",
         field.isImplicit ? "Implicit" : "Declared"].joined(separator: "\n")
    }

    static let source = "Prompt source"
    static let save = "Save"
    static let revert = "Revert"
    static let saveAsCopy = "Save as Copy"
    static let history = "History"
    static let revisions = "Prompt revisions"
    static let historyPreview = "Read-only revision source"
    static let refreshHistory = "Refresh History"
    static let loadingHistory = "Loading history…"
    static let noHistory = "No saved revisions for this prompt."
    static let selectRevision = "Select a revision to preview it."
    static let restore = "Restore"
    static let validRevision = "Valid"
    static let forensicRevision = "Forensic only"
    static let noUTF8Preview = "No preview: this revision is not UTF-8."
    static let oversizedPreview = "No preview: this revision exceeds the supported prompt size."
    static let rename = "Rename…"
    static let move = "Move…"
    static let delete = "Delete…"
    static let renameTitle = "Rename prompt"
    static let moveTitle = "Move prompt"
    static let renameButton = "Rename"
    static let moveButton = "Move"
    static let deleteButton = "Delete"
    static let cancel = "Cancel"
    static let filename = "Filename"
    static let folder = "Folder relative to the library"
    static let rootFolder = "Library root"
    static let existingFolders = "Existing folders"
    static let renameHint = "Enter a filename including .md. The prompt title stays the same. Existing files are never replaced."
    static let moveHint = "Choose an existing folder or enter a new relative folder. Leave it empty for the library root. Existing files are never replaced."
    static let renamed = "Renamed"
    static let moved = "Moved"
    static let restored = "Restored"
    static let deleted = "Deleted. The prompt's history is kept."
    static let occupied = "The destination already exists. Choose another name or folder; no file was replaced."
    static let invalidDestination = "Enter a valid .md filename or library-relative folder. Avoid absolute paths, parent traversal and ignored names."
    static let missing = "The prompt file is missing. Resolve the deletion conflict before continuing."
    static let changed = "The prompt changed on disk. Resolve the conflict before retrying the command."
    static let cancelled = "Cancelled. Your prompt and edits are kept."
    static let inactive = "This editor session is no longer active. Reopen the prompt to try again."
    static let noSelection = "Open a prompt before using a file command."
    static let historyWarning = "The prompt was updated, but its history needs maintenance."
    static let relocated = "The file moved, but its destination changed or could not be checked. Resolve the conflict or check the library before retrying."
    static let revisionMissing = "The revision is missing. Refresh History and choose another revision."
    static let librarySwitchRefused = "Save or discard your Library edits before switching folders. Wait for any save to finish."

    static func deleteTitle(_ path: String) -> String { "Delete “\(path)”?" }
    static func deleteHint(_ path: String) -> String {
        "Delete “\(path)” from your library? This removes the file and closes the editor. Its history is kept."
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func revisionMetadata(_ snapshot: PromptHistorySnapshot) -> String {
        "\(snapshot.byteCount) bytes · " + (snapshot.isForensic ? forensicRevision : validRevision)
    }

    static func restoreRefusal(_ error: PromptWriteError) -> String {
        switch error {
        case .invalidPrompt: return "Restore refused: this forensic revision is not a valid prompt."
        case .unsupportedFormat: return "Restore refused: this revision uses a newer prompt format."
        case .sourceTooLarge: return "Restore refused: this revision exceeds the supported prompt size."
        case .serializationFailed: return "Restore refused: the revision's front matter could not be serialized."
        }
    }

    static func commandMessage(_ outcome: PromptCommandOutcome, success: String) -> String {
        switch outcome {
        case .updated: return success
        case .updatedButHistoryMaintenanceFailed: return historyWarning
        case .relocated: return relocated
        case .deleted: return deleted
        case .missing: return missing
        case .destinationOccupied: return occupied
        case .conflict: return changed
        case .forensic(let reason): return restoreRefusal(reason)
        case .readOnly(let reason): return readOnly(reason)
        case .failed(.fileStore(.invalidPath)), .failed(.library(.invalidPromptPath)): return invalidDestination
        case .failed(.library(.destinationOccupied)): return occupied
        case .failed(.library(.revisionNotFound)): return revisionMissing
        case .failed(let failure): return editingFailure(failure)
        case .cancelled: return cancelled
        case .inactive: return inactive
        case .noSelection: return noSelection
        }
    }

    static func readOnly(_ reason: PromptReadOnlyReason) -> String {
        switch reason {
        case .invalidUTF8: return "Read-only: encode this file as UTF-8 before editing it."
        case .sourceTooLarge: return "Read-only: this file exceeds the supported prompt size."
        case .unsupportedFormat: return "Read-only: this file uses a newer prompt format."
        }
    }

    static func status(_ state: EditorState) -> String {
        let message: String
        switch state.status {
        case .idle:
            if let conflict = state.conflict {
                message = conflict.kind == .deleted
                    ? "The file was deleted on disk. Save to choose how to keep your draft."
                    : "The file changed on disk. Save to reopen the conflict choices."
            } else { message = state.isDirty ? "Unsaved edits" : "" }
        case .loading: message = "Loading…"
        case .saving: message = "Saving…"
        case .commandRunning: message = "Updating the file…"
        case .saved: message = state.isDirty ? "Saved; newer edits are unsaved." : "Saved"
        case .failed(let error): message = failure(error)
        }
        guard state.historyMaintenanceFailed else { return message }
        let separator = message.hasSuffix(".") || message.hasSuffix("…") ? " " : ". "
        return message.isEmpty ? "The prompt was saved, but its history needs maintenance."
            : message + separator + "History needs maintenance."
    }

    static func failure(_ error: EditorFailure) -> String {
        switch error {
        case .invalid: return "Could not save. Fix the validation errors in Edit."
        case .readOnly(let reason): return readOnly(reason)
        case .editing(let failure): return editingFailure(failure)
        }
    }

    static func editingFailure(_ failure: PromptEditingFailure) -> String {
        switch failure {
        case .fileStore(.notFound): return "The prompt file is missing."
        case .fileStore(.outsideRoot), .fileStore(.invalidPath), .fileStore(.invalidRoot):
            return "The prompt file is outside the active library or has an invalid path."
        case .fileStore: return "Could not access the prompt. Check library and app-data permissions, then retry."
        case .library(.conflict): return "The file changed during the operation. Your edits are still available; retry or save a copy."
        case .library(.destinationOccupied): return occupied
        case .library(.invalidPromptPath): return invalidDestination
        case .library(.revisionNotFound): return revisionMissing
        case .library(.recoveryRequired), .library(.historyMaintenanceFailed):
            return "The operation needs recovery. Your edits are still available; check the library before retrying."
        case .library: return "Could not complete the operation. Check the library, then retry."
        case .write(let error): return error.description
        case .identity: return "Could not assign a prompt identity. Retry the save."
        }
    }

    static func issue(_ issue: PromptIssue) -> String {
        let location: String
        switch issue.location {
        case .frontMatter(let line, let column): location = "Line \(line), column \(column): "
        case .body(let offset): location = "Body byte \(offset): "
        case nil: location = ""
        }
        return issue.severity.rawValue.capitalized + ": " + location + issue.message
    }
}
#endif
