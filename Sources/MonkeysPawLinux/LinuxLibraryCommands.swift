#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The header forms collect input; Core owns the guard and stamped writes.
final class LinuxLibraryCommands {
    let widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
    var onChange: (() -> Void)?
    private(set) var message: String?
    var hasDialog: Bool { dialog != nil }

    private let parent: GTK.Widget
    private weak var editor: EditorModel?
    private weak var browser: LibraryBrowserModel?
    private var available = false
    private var revision: UInt64 = 0
    private var previousState: EditorState?
    private var dialog: LinuxLibraryFileCommandDialog?
    private var dialogPrompt: LibraryPromptSelection?
    private var buttons: [GTK.Widget] = []

    var canRun: Bool {
        guard available, let state = editor?.state else { return false }
        return state.prompt != nil && state.stamp != nil && state.canEdit && state.status != .saving
            && state.pendingDecision == nil && state.conflict == nil
    }

    init(parent: GTK.Widget) {
        self.parent = parent
        for command in LinuxLibraryFileCommand.allCases {
            let button = GTK.button(command.label) { [weak self] in self?.request(command) }
            let name: String
            switch command {
            case .rename: name = "library-rename"
            case .move: name = "library-move"
            case .delete: name = "library-delete"
            }
            gtk_widget_set_name(button, name)
            mp_accessible_label(button, command.label)
            buttons.append(button)
            gtk_box_append(mp_box(widget), button)
        }
    }

    func bind(editor: EditorModel, browser: LibraryBrowserModel) {
        unbind()
        self.editor = editor
        self.browser = browser
    }

    func unbind() {
        revision &+= 1
        cancelDialog()
        editor = nil
        browser = nil
        previousState = nil
        message = nil
    }

    func cancelDialog() {
        dialog?.destroy()
        dialog = nil
        dialogPrompt = nil
    }

    func update(_ state: EditorState, available: Bool) {
        self.available = available
        if previousState?.prompt != state.prompt || previousState?.source.map({ old in
            state.source.map { old.utf8.elementsEqual($0.utf8) } ?? false
        }) == false || state.status == .loading || state.status == .saving || state.status == .commandRunning
            || state.pendingDecision != nil || (previousState?.conflict == nil && state.conflict != nil) {
            message = nil
        }
        previousState = state
        if hasDialog, dialogPrompt != state.prompt || !canRun { cancelDialog() }
        for button in buttons { gtk_widget_set_sensitive(button, canRun && !hasDialog ? 1 : 0) }
    }

    func restore(_ revision: HistoryRevision) {
        guard canRun, !hasDialog, let editor, !editor.state.history.isLoading else { return }
        editor.restore(revision, completion: completion(success: LinuxEditorStrings.restored))
    }

    private func request(_ command: LinuxLibraryFileCommand) {
        guard canRun, !hasDialog, gtk_widget_get_visible(parent) != 0,
              let prompt = editor?.state.prompt else { return }
        let folders = browser?.sections.compactMap { section -> String? in
            if case .folder(let folder) = section.id { return folder.string }
            return nil
        } ?? []
        let revision = self.revision
        dialogPrompt = prompt
        dialog = LinuxLibraryFileCommandDialog(parent: parent, command: command, prompt: prompt, folders: folders) { [weak self] input in
            guard let self, self.revision == revision, self.dialogPrompt == prompt else { return }
            self.cancelDialog()
            self.onChange?()
            guard let input, self.canRun, self.editor?.state.prompt == prompt, let editor = self.editor else { return }
            let completion = self.completion(success: command.success)
            switch command {
            case .rename: editor.rename(to: input, completion: completion)
            case .move: editor.move(to: input, completion: completion)
            case .delete: editor.delete(completion: completion)
            }
        }
        onChange?()
    }

    private func completion(success: String) -> (PromptCommandOutcome) -> Void {
        message = nil
        let revision = self.revision
        return { [weak self] outcome in
            guard let self, self.revision == revision, let editor = self.editor else { return }
            // The completion can precede queued observers. Record its state
            // first so their later render does not erase the typed outcome.
            self.update(editor.state, available: self.available)
            if case .cancelled = outcome, editor.state.conflict != nil { self.message = nil }
            else { self.message = LinuxEditorStrings.commandMessage(outcome, success: success) }
            self.onChange?()
        }
    }
}
#endif
