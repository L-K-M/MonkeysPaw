import MonkeysPawCore

enum EditorStrings {
    static let source = "Prompt source"
    static let save = "Save"
    static let revert = "Revert"
    static let saveAsCopy = "Save as Copy"
    static let librarySwitchRefused = "Save or discard your Library edits before switching folders. Wait for any save to finish."

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
        case .idle: message = state.isDirty ? "Unsaved edits" : ""
        case .loading: message = "Loading…"
        case .saving: message = "Saving…"
        case .saved: message = state.isDirty ? "Saved; newer edits are unsaved." : "Saved"
        case .failed(let failure):
            switch failure {
            case .invalid: message = "Could not save. Fix the validation errors below the source."
            case .readOnly(let reason): message = readOnly(reason)
            case .editing(let failure): message = editingFailure(failure)
            }
        }
        guard state.historyMaintenanceFailed else { return message }
        return message + " The prompt was saved, but its history needs maintenance."
    }

    static func editingFailure(_ failure: PromptEditingFailure) -> String {
        switch failure {
        case .fileStore(.notFound): return "The prompt file is missing."
        case .fileStore(.outsideRoot), .fileStore(.invalidPath), .fileStore(.invalidRoot):
            return "The prompt file is outside the active library or has an invalid path."
        case .fileStore: return "Could not access the prompt. Check library and app-data permissions, then retry."
        case .library(.conflict): return "The file changed during the operation. Your edits are still available; retry or save a copy."
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
