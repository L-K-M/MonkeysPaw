#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

struct LinuxNewPromptRequest: Equatable {
    let id = UUID()
    let folder: RelativePath
}

enum LinuxEditorDialogState: Equatable {
    case decision(EditorPendingDecision, status: EditorStatus)
    case conflict(EditorConflict, status: EditorStatus)
    case newPrompt(LinuxNewPromptRequest)

    var title: String {
        switch self {
        case .decision: return "Save your edits?"
        case .newPrompt: return LinuxStrings.newPromptTitle
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
            case .open, .close, .rename, .move, .delete, .create, .librarySwitch:
                text = "Save or discard your edits before continuing. Cancel keeps your draft."
            }
            return text + failureMessage(status)
        case .newPrompt(let request): return LinuxStrings.newPromptHint(request.folder)
        case .conflict(let conflict, let status):
            var text = conflict.kind == .deleted
                ? "Keep Mine recreates the file. Save as Copy keeps your edits in a new file. Discard closes this draft."
                : "Keep Mine saves over the file on disk. Take Theirs reloads it. Save Mine as Copy keeps your edits in a new file."
            if let failure = conflict.failure { text += " " + LinuxEditorStrings.editingFailure(failure) }
            if let reason = conflict.readOnlyReason { text += " " + LinuxEditorStrings.readOnly(reason) }
            return text + failureMessage(status)
        }
    }

    var responses: [LinuxEditorResponse] {
        switch self {
        case .decision: return [.decision(.save), .decision(.discard), .decision(.cancel)]
        case .newPrompt: return [.createPrompt(LinuxStrings.newPromptDefaultTitle), .cancelNewPrompt]
        case .conflict(let conflict, _):
            return conflict.choices.map(LinuxEditorResponse.conflict) + [.dismissConflict]
        }
    }

    private func failureMessage(_ status: EditorStatus) -> String {
        guard case .failed(let failure) = status else { return "" }
        return " " + LinuxEditorStrings.failure(failure)
    }
}

enum LinuxEditorResponse: Equatable {
    case decision(EditorDecision)
    case conflict(EditorConflictChoice)
    /// Native dismissal leaves Core's conflict and draft available for repair.
    case dismissConflict
    case createPrompt(String), cancelNewPrompt

    var title: String {
        switch self {
        case .decision(.save): return LinuxEditorStrings.save
        case .decision(.discard), .conflict(.discard): return "Discard"
        case .decision(.cancel), .dismissConflict: return "Cancel"
        case .conflict(.keepMine): return "Keep Mine"
        case .conflict(.takeTheirs): return "Take Theirs"
        case .conflict(.saveAsCopy): return "Save Mine as Copy"
        case .createPrompt: return LinuxStrings.newPromptCreate
        case .cancelNewPrompt: return LinuxEditorStrings.cancel
        }
    }
}

/// A modal transient window uses only GTK 4.8 APIs. GtkDialog/MessageDialog
/// are deprecated in CI's GTK 4.14, and GtkAlertDialog is absent on this host.
final class LinuxEditorDialog {
    private let window: GTK.Widget
    private var isDestroyed = false
    private var hasResponded = false
    private var hasPreedit = false

    init(parent: GTK.Widget, state: LinuxEditorDialogState, respond: @escaping (LinuxEditorResponse) -> Void) {
        window = gtk_window_new()!
        gtk_widget_set_name(window, "library-editor-dialog")
        gtk_window_set_title(mp_window(window), state.title)
        gtk_window_set_transient_for(mp_window(window), mp_window(parent))
        gtk_window_set_modal(mp_window(window), 1)
        gtk_window_set_destroy_with_parent(mp_window(window), 1)
        GTK.onSignal(window, "destroy") { [weak self] in self?.isDestroyed = true }
        let input: GTK.Widget?
        if case .newPrompt = state {
            input = gtk_entry_new()!
        } else { input = nil }
        let respondOnce: (LinuxEditorResponse) -> Void = { [weak self] response in
            guard let self, !self.isDestroyed, !self.hasResponded else { return }
            self.hasResponded = true
            if case .createPrompt = response, let input {
                respond(.createPrompt(String(cString: mp_entry_text(input))))
            } else { respond(response) }
        }
        let cancel: LinuxEditorResponse = {
            switch state {
            case .decision: return .decision(.cancel)
            case .conflict: return .dismissConflict
            case .newPrompt: return .cancelNewPrompt
            }
        }()
        GTK.onCloseRequested(window) { respondOnce(cancel) }
        GTK.observeKeys(window) { [weak self] key, modifiers in
            let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
                | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
            guard self?.hasPreedit == false, key == UInt32(GDK_KEY_Escape), modifiers & relevant == 0 else { return false }
            respondOnce(cancel)
            return true
        }
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 16) }
        let message = GTK.label(state.message)
        gtk_widget_set_name(message, "library-dialog-message")
        gtk_label_set_max_width_chars(mp_label(message), 64)
        gtk_box_append(mp_box(content), message)
        if let input {
            gtk_widget_set_name(input, "library-new-prompt-title")
            mp_accessible_label(input, LinuxStrings.promptTitle)
            mp_entry_set_text(input, LinuxStrings.newPromptDefaultTitle)
            gtk_box_append(mp_box(content), GTK.label(LinuxStrings.promptTitle))
            gtk_box_append(mp_box(content), input)
            if let text = mp_entry_text_delegate(input) {
                GTK.onPreeditChanged(text) { [weak self] active in self?.hasPreedit = active }
            }
            GTK.onSignal(input, "activate") { respondOnce(.createPrompt("")) }
        }
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        var cancelButton: GTK.Widget?
        for (position, response) in state.responses.enumerated() {
            let button = GTK.button(response.title) { respondOnce(response) }
            gtk_widget_set_name(button, "library-dialog-response-\(position)")
            mp_accessible_label(button, response.title)
            gtk_box_append(mp_box(buttons), button)
            if response == cancel { cancelButton = button }
        }
        gtk_box_append(mp_box(content), buttons)
        gtk_window_set_child(mp_window(window), content)
        gtk_window_present(mp_window(window))
        if let input {
            gtk_widget_grab_focus(input)
            gtk_editable_select_region(OpaquePointer(input), 0, -1)
        } else if let cancelButton { gtk_widget_grab_focus(cancelButton) }
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        gtk_window_destroy(mp_window(window))
    }
}
#endif
