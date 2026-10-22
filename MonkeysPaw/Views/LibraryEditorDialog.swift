import MonkeysPawCore

/// Revert to Saved discards; every other guarded reload offers Save first.
enum LibraryDecisionStyle: Equatable { case save, revertToSaved }

enum LibraryEditorDialog: Equatable {
    case decision(EditorPendingDecision, status: EditorStatus, title: String = LibraryStrings.title,
                  style: LibraryDecisionStyle = .save)
    case conflict(EditorConflict, status: EditorStatus, title: String = LibraryStrings.title)
    case fileCommand(LibraryFileCommandRequest)
    case newPrompt(LibraryNewPromptRequest)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.decision(let left, let leftStatus, let leftTitle, let leftStyle),
              .decision(let right, let rightStatus, let rightTitle, let rightStyle)):
            return left == right && leftStatus == rightStatus && leftTitle == rightTitle && leftStyle == rightStyle
        case (.conflict(let left, let leftStatus, let leftTitle), .conflict(let right, let rightStatus, let rightTitle)):
            return left == right && leftStatus == rightStatus && leftTitle == rightTitle
        case (.fileCommand(let left), .fileCommand(let right)):
            // Reopened forms must replace their native sheet and callback token.
            return left.id == right.id && left == right
        case (.newPrompt(let left), .newPrompt(let right)): return left == right
        default: return false
        }
    }

    var title: String {
        switch self {
        case .decision(_, _, let title, let style):
            return style == .revertToSaved ? LibraryDialogStrings.revertTitle(title) : LibraryDialogStrings.saveTitle(title)
        case .conflict(let conflict, _, let title):
            return LibraryDialogStrings.conflictTitle(title, kind: conflict.kind)
        case .fileCommand(let request): return request.title
        case .newPrompt: return LibraryCommandStrings.newPromptTitle
        }
    }

    var message: String {
        switch self {
        case .decision(_, let status, _, let style):
            let text = style == .revertToSaved ? LibraryDialogStrings.revert : LibraryDialogStrings.unsaved
            return text + failureMessage(status)
        case .conflict(let conflict, let status, _):
            var text = conflict.kind == .deleted ? LibraryDialogStrings.deleted : LibraryDialogStrings.modified
            if let failure = conflict.failure { text += " " + EditorStrings.editingFailure(failure) }
            if let reason = conflict.readOnlyReason { text += " " + EditorStrings.readOnly(reason) }
            return text + failureMessage(status)
        case .fileCommand(let request): return request.message
        case .newPrompt(let request): return LibraryCommandStrings.newPromptHint(request.folder)
        }
    }

    var responses: [LibraryEditorResponse] {
        switch self {
        case .decision(_, _, _, let style):
            return style == .revertToSaved ? [.decision(.discard), .decision(.cancel)]
                : [.decision(.save), .decision(.cancel), .decision(.discard)]
        case .conflict(let conflict, _, _):
            return conflict.choices.map(LibraryEditorResponse.conflict) + [.dismissConflict]
        case .fileCommand(let request): return request.responses
        case .newPrompt: return [.createPrompt(LibraryStrings.newPromptDefaultTitle), .cancelFileCommand]
        }
    }

    /// Form responses carry the user's text rather than the initial value.
    func accepts(_ response: LibraryEditorResponse) -> Bool {
        switch (self, response) {
        case (.fileCommand(let request), .rename): return request.command == .rename
        case (.fileCommand(let request), .move): return request.command == .move
        case (.newPrompt, .createPrompt): return true
        default: return responses.contains(response)
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
    case rename(String), move(String), delete, cancelFileCommand
    case createPrompt(String)

    var title: String {
        switch self {
        case .decision(.save): return EditorStrings.save
        case .decision(.discard): return LibraryDialogStrings.dontSave
        case .conflict(.discard): return LibraryDialogStrings.discard
        case .decision(.cancel), .dismissConflict: return LibraryDialogStrings.cancel
        case .conflict(.keepMine): return LibraryDialogStrings.keepMine
        case .conflict(.takeTheirs): return LibraryDialogStrings.takeTheirs
        case .conflict(.saveAsCopy): return LibraryDialogStrings.saveMineAsCopy
        case .rename: return LibraryCommandStrings.renameButton
        case .move: return LibraryCommandStrings.moveButton
        case .delete: return LibraryCommandStrings.deleteButton
        case .cancelFileCommand: return LibraryCommandStrings.cancel
        case .createPrompt: return LibraryCommandStrings.create
        }
    }
}
