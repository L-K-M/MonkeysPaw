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
    var isScopeDropPending: Bool { pendingDrop != nil }

    private let parent: GTK.Widget
    private weak var editor: EditorModel?
    private weak var browser: LibraryBrowserModel?
    private var available = false
    private var revision: UInt64 = 0
    private var previousState: EditorState?
    private var dialog: LinuxLibraryFileCommandDialog?
    private var dialogPrompt: LibraryPromptSelection?
    private var buttons: [GTK.Widget] = []
    private var dragEpoch = UUID()
    private var pendingDrop: (selection: LibraryPromptSelection, section: LibrarySectionID)?
    private var dropOpenApproved = false

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
        dragEpoch = UUID()
        pendingDrop = nil
        dropOpenApproved = false
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
        finishDrop()
    }

    private func identityPayload(_ selection: LibraryPromptSelection) -> String {
        let identity: String
        switch selection.identity {
        case .assigned(let id): identity = id.rawValue
        case .local(let hash): identity = hash
        }
        return "monkeyspaw-row:" + dragEpoch.uuidString + ":" + identity + ":" + selection.relativePath.string
    }

    private func dragPayload(for selection: LibraryPromptSelection) -> String? {
        guard available, !hasDialog, pendingDrop == nil, gtk_widget_get_visible(parent) != 0,
              browser?.rows.contains(where: { $0.selection == selection && !$0.isReadOnly }) == true else { return nil }
        return identityPayload(selection)
    }

    @discardableResult
    private func drop(_ payload: String, onto section: LibrarySectionID) -> Bool {
        guard available, !hasDialog, pendingDrop == nil, gtk_widget_get_visible(parent) != 0,
              let browser, let editor, browser.moveDestination(for: section) != nil,
              editor.state.pendingDecision == nil, editor.state.conflict == nil,
              editor.state.queuedActions.isEmpty,
              editor.state.status != .loading, editor.state.status != .saving,
              editor.state.status != .commandRunning,
              let row = browser.rows.first(where: {
                  !$0.isReadOnly && payload.utf8.elementsEqual(identityPayload($0.selection).utf8)
              }) else { return false }
        // Match exact issued identity/path/epoch bytes against current rows.
        // Never parse a dropped string into a path or pass it to ImportModel.
        // Spend the payload even when the editor's guard later cancels.
        dragEpoch = UUID()
        pendingDrop = (row.selection, section)
        dropOpenApproved = editor.state.prompt == row.selection
        if dropOpenApproved { finishDrop(); return true }
        let revision = self.revision
        editor.request(.open(row.selection)) { [weak self] result in
            guard let self, self.revision == revision else { return }
            guard result == .allowed else {
                self.pendingDrop = nil
                // The editor published before this callback cleared the drop gate.
                self.onChange?()
                return
            }
            self.browser?.selectPrompt(row.selection)
            self.dropOpenApproved = true
            self.finishDrop()
        }
        return true
    }

    private func finishDrop() {
        guard let pendingDrop, dropOpenApproved, let editor else { return }
        if editor.state.status == .loading { return }
        self.pendingDrop = nil
        dropOpenApproved = false
        guard canRun, !hasDialog, gtk_widget_get_visible(parent) != 0,
              editor.state.queuedActions.isEmpty,
              editor.state.prompt == pendingDrop.selection,
              let destination = browser?.moveDestination(for: pendingDrop.section) else { return }
        editor.move(to: destination.string, completion: completion(success: LinuxLibraryFileCommand.move.success))
    }

    private final class DragHandler {
        let prepare: () -> String?
        init(_ prepare: @escaping () -> String?) { self.prepare = prepare }
    }

    func installDrag(on widget: GTK.Widget, selection: LibraryPromptSelection) {
        let revision = self.revision
        let source = gtk_drag_source_new()!
        gtk_drag_source_set_actions(source, GDK_ACTION_MOVE)
        let handler = Unmanaged.passRetained(DragHandler { [weak self] in
            guard let self, self.revision == revision else { return nil }
            return self.dragPayload(for: selection)
        }).toOpaque()
        let prepare: @convention(c) (UnsafeMutableRawPointer?, Double, Double,
                                     UnsafeMutableRawPointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
            guard let data, let payload = Unmanaged<DragHandler>.fromOpaque(data).takeUnretainedValue().prepare() else { return nil }
            return mp_library_row_provider(payload)
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<DragHandler>.fromOpaque(data).release() }
        }
        mp_connect(UnsafeMutableRawPointer(source), "prepare", unsafeBitCast(prepare, to: GCallback.self), handler, release)
        gtk_widget_add_controller(widget, mp_drag_source_controller(source))
    }

    private final class DropHandler {
        let receive: (String) -> Bool
        init(_ receive: @escaping (String) -> Bool) { self.receive = receive }
    }

    func installDrop(on widget: GTK.Widget, section: LibrarySectionID) {
        let revision = self.revision
        let target = gtk_drop_target_new(mp_library_row_type(), GDK_ACTION_MOVE)!
        let handler = Unmanaged.passRetained(DropHandler { [weak self] payload in
            guard let self, self.revision == revision else { return false }
            return self.drop(payload, onto: section)
        }).toOpaque()
        let receive: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<GValue>?, Double, Double,
                                     UnsafeMutableRawPointer?) -> gboolean = { _, value, _, _, data in
            guard let value, let data, let string = mp_library_row_string(value),
                  let payload = String(validatingUTF8: string) else { return 0 }
            return Unmanaged<DropHandler>.fromOpaque(data).takeUnretainedValue().receive(payload) ? 1 : 0
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<DropHandler>.fromOpaque(data).release() }
        }
        mp_connect(UnsafeMutableRawPointer(target), "drop", unsafeBitCast(receive, to: GCallback.self), handler, release)
        gtk_widget_add_controller(widget, target)
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
