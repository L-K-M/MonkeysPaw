import MonkeysPawCore

enum EditorStrings {
    static let source = "Prompt source"
    static let save = "Save"
    static let revert = "Revert"
    static let saveAsCopy = "Save as Copy"
    static let editTab = "Edit"
    static let previewTab = "Preview"
    static let fieldsTab = "Fields"
    static let noFields = "No fields in this prompt."
    static let fieldName = "Name / label"
    static let fieldType = "Type"
    static let fieldDefault = "Default"
    static let fieldOptions = "Options"
    static let fieldBehaviorHeader = "Behavior"
    static let parsedFields = "Parsed prompt fields"
    static let librarySwitchRefused = "Save or discard your Library edits before switching folders. Wait for any save to finish."

    static func fieldKind(_ kind: FieldKind) -> String {
        switch kind {
        case .text: return "Text"
        case .multiline: return "Multiline"
        case .choice: return "Choice"
        }
    }

    static func fieldBehavior(_ field: PromptField) -> String {
        [field.optional ? "Optional" : "Required", field.remember ? "Remembered" : "Not remembered",
         field.isImplicit ? "Implicit" : "Declared"].joined(separator: "\n")
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
