import MonkeysPawCore

enum LibraryEditorDialog: Equatable {
    case decision(EditorPendingDecision, status: EditorStatus)
    case conflict(EditorConflict, status: EditorStatus)

    var title: String {
        switch self {
        case .decision: return "Save your edits?"
        case .conflict(let conflict, _):
            return conflict.kind == .deleted ? "The prompt was deleted on disk" : "The prompt changed on disk"
        }
    }

    var message: String {
        switch self {
        case .decision(let decision, let status):
            let text: String
            switch decision.action {
            case .quit: text = "Save or discard your edits before quitting. Cancel keeps Library open."
            case .revert: text = "Save or discard your edits before reloading the prompt from disk."
            case .open, .close, .rename, .move, .delete, .librarySwitch:
                text = "Save or discard your edits before continuing. Cancel keeps your draft."
            }
            return text + failureMessage(status)
        case .conflict(let conflict, let status):
            var text = conflict.kind == .deleted
                ? "Keep Mine recreates the file. Save as Copy keeps your edits in a new file. Discard closes this draft."
                : "Keep Mine saves over the file on disk. Take Theirs reloads it. Save Mine as Copy keeps your edits in a new file."
            if let failure = conflict.failure { text += " " + EditorStrings.editingFailure(failure) }
            if let reason = conflict.readOnlyReason { text += " " + EditorStrings.readOnly(reason) }
            return text + failureMessage(status)
        }
    }

    var responses: [LibraryEditorResponse] {
        switch self {
        case .decision: return [.decision(.save), .decision(.discard), .decision(.cancel)]
        case .conflict(let conflict, _):
            return conflict.choices.map(LibraryEditorResponse.conflict) + [.dismissConflict]
        }
    }

    private func failureMessage(_ status: EditorStatus) -> String {
        guard case .failed(let failure) = status else { return "" }
        return " " + EditorStrings.failure(failure)
    }
}

enum LibraryEditorResponse: Equatable {
    case decision(EditorDecision)
    case conflict(EditorConflictChoice)
    /// Native dismissal leaves Core's conflict and draft available for repair.
    case dismissConflict

    var title: String {
        switch self {
        case .decision(.save): return EditorStrings.save
        case .decision(.discard), .conflict(.discard): return "Discard"
        case .decision(.cancel), .dismissConflict: return "Cancel"
        case .conflict(.keepMine): return "Keep Mine"
        case .conflict(.takeTheirs): return "Take Theirs"
        case .conflict(.saveAsCopy): return "Save Mine as Copy"
        }
    }
}
