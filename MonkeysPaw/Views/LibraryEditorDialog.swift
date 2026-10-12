import AppKit
import MonkeysPawCore

enum LibraryEditorDialog: Equatable {
    case decision(EditorPendingDecision)
    case conflict(EditorConflict)

    var title: String {
        switch self {
        case .decision: return "Save your edits?"
        case .conflict(let conflict):
            return conflict.kind == .deleted ? "The prompt was deleted on disk" : "The prompt changed on disk"
        }
    }

    var message: String {
        switch self {
        case .decision(let decision):
            switch decision.action {
            case .quit: return "Save or discard your edits before quitting. Cancel keeps Library open."
            case .revert: return "Save or discard your edits before reloading the prompt from disk."
            default: return "Save or discard your edits before continuing. Cancel keeps your draft."
            }
        case .conflict(let conflict):
            var text = conflict.kind == .deleted
                ? "Keep Mine recreates the file. Save as Copy keeps your edits in a new file. Discard closes this draft."
                : "Keep Mine saves over the file on disk. Take Theirs reloads it. Save Mine as Copy keeps your edits in a new file."
            if let failure = conflict.failure { text += " " + EditorStrings.editingFailure(failure) }
            if let reason = conflict.readOnlyReason { text += " " + EditorStrings.readOnly(reason) }
            return text
        }
    }

    var responses: [LibraryEditorResponse] {
        switch self {
        case .decision: return [.decision(.save), .decision(.discard), .decision(.cancel)]
        case .conflict(let conflict): return conflict.choices.map(LibraryEditorResponse.conflict)
        }
    }

    static func present(in window: NSWindow, dialog: Self,
                        done: @escaping (LibraryEditorResponse) -> Void) -> (() -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dialog.title
        alert.informativeText = dialog.message
        let responses = dialog.responses
        for response in responses {
            let button = alert.addButton(withTitle: response.title)
            // Overwriting an external version must be an explicit choice.
            button.keyEquivalent = response == .decision(.cancel) ? "\u{1b}" : ""
            button.hasDestructiveAction = response == .decision(.discard) || response == .conflict(.discard)
        }
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard responses.indices.contains(index) else { return }
            done(responses[index])
        }
        return {
            guard alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
    }
}

enum LibraryEditorResponse: Equatable {
    case decision(EditorDecision)
    case conflict(EditorConflictChoice)

    var title: String {
        switch self {
        case .decision(.save): return EditorStrings.save
        case .decision(.discard), .conflict(.discard): return "Discard"
        case .decision(.cancel): return "Cancel"
        case .conflict(.keepMine): return "Keep Mine"
        case .conflict(.takeTheirs): return "Take Theirs"
        case .conflict(.saveAsCopy): return "Save Mine as Copy"
        }
    }
}
