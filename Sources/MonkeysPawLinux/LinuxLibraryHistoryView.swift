#if os(Linux)
import CGtk
import MonkeysPawCore

/// History renders Core snapshots; selecting one never edits the live draft.
final class LinuxLibraryHistoryView {
    let widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    var onLoad: (() -> Void)?
    var onSelect: ((HistoryRevision?) -> Void)?
    var onRestore: ((HistoryRevision) -> Void)?

    private let list = gtk_list_box_new()!
    private let preview = gtk_text_view_new()!
    private let status = GTK.label("")
    private let refresh = GTK.button(LinuxEditorStrings.refreshHistory) {}
    private let restore = GTK.button(LinuxEditorStrings.restore) {}
    private var revisions: [PromptHistorySnapshot] = []
    private var selected: HistoryRevision?
    private var renderedSource: String?
    private var isRendering = false

    init() {
        gtk_widget_set_name(widget, "library-history")
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        for (button, name) in [(refresh, "library-history-refresh"), (restore, "library-restore")] {
            gtk_widget_set_name(button, name)
            gtk_box_append(mp_box(actions), button)
        }
        GTK.onSignal(refresh, "clicked") { [weak self] in self?.onLoad?() }
        GTK.onSignal(restore, "clicked") { [weak self] in
            guard let self, let selected = self.selected else { return }
            self.onRestore?(selected)
        }
        gtk_box_append(mp_box(widget), actions)
        gtk_widget_set_name(status, "library-history-status")
        gtk_label_set_selectable(mp_label(status), 1)
        gtk_box_append(mp_box(widget), status)
        gtk_widget_set_name(list, "library-history-list")
        mp_accessible_label(list, LinuxEditorStrings.revisions)
        gtk_list_box_set_selection_mode(mp_list_box(list), GTK_SELECTION_SINGLE)
        GTK.onRow(list, "row-selected") { [weak self] position in
            guard let self, !self.isRendering else { return }
            self.onSelect?(position.flatMap { self.revisions.indices.contains($0) ? self.revisions[$0].revision : nil })
        }
        gtk_widget_set_name(preview, "library-history-preview")
        mp_accessible_label(preview, LinuxEditorStrings.historyPreview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_monospace(mp_text_view(preview), 1)
        gtk_box_append(mp_box(widget), scrolled(list))
        gtk_box_append(mp_box(widget), scrolled(preview))
    }

    func update(_ state: EditorState, available: Bool, canRestore: Bool) {
        isRendering = true
        defer { isRendering = false }
        let history = state.history
        if revisions != history.revisions {
            while let row = gtk_widget_get_first_child(list) { gtk_list_box_remove(mp_list_box(list), row) }
            revisions = history.revisions
            for snapshot in revisions {
                let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
                let timestamp = LinuxEditorStrings.timestamp(snapshot.revision.timestamp)
                let metadata = LinuxEditorStrings.revisionMetadata(snapshot)
                gtk_box_append(mp_box(row), GTK.label(timestamp))
                gtk_box_append(mp_box(row), GTK.label(metadata))
                mp_accessible_label(row, timestamp + ", " + metadata)
                gtk_list_box_append(mp_list_box(list), row)
            }
        }
        selected = history.selectedRevision
        let position = revisions.firstIndex { $0.revision == selected }
        gtk_list_box_select_row(mp_list_box(list), position.flatMap {
            gtk_list_box_get_row_at_index(mp_list_box(list), Int32($0))
        })
        let snapshot = position.map { revisions[$0] }
        let source = snapshot?.source ?? ""
        if renderedSource.map({ $0.utf8.elementsEqual(source.utf8) }) != true {
            renderedSource = source
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), source, Int32(source.utf8.count))
        }
        var messages: [String] = []
        if history.isLoading { messages.append(LinuxEditorStrings.loadingHistory) }
        if let failure = history.failure { messages.append(LinuxEditorStrings.editingFailure(failure)) }
        if let snapshot {
            if let reason = snapshot.restoreFailure { messages.append(LinuxEditorStrings.restoreRefusal(reason)) }
            if snapshot.source == nil {
                messages.append(snapshot.byteCount > Limits.maxPromptBytes
                    ? LinuxEditorStrings.oversizedPreview : LinuxEditorStrings.noUTF8Preview)
            }
        } else if !history.isLoading {
            messages.append(revisions.isEmpty ? LinuxEditorStrings.noHistory : LinuxEditorStrings.selectRevision)
        }
        gtk_label_set_text(mp_label(status), messages.joined(separator: "\n"))
        gtk_widget_set_sensitive(refresh, available && state.prompt != nil && !history.isLoading
            && state.status != .loading && state.status != .saving && state.status != .commandRunning ? 1 : 0)
        // Forensic revisions remain selectable and return Core's typed refusal.
        gtk_widget_set_sensitive(restore, canRestore && !history.isLoading && selected != nil ? 1 : 0)
    }

    private func scrolled(_ child: GTK.Widget) -> GTK.Widget {
        let scroll = gtk_scrolled_window_new()!
        gtk_widget_set_hexpand(scroll, 1)
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), child)
        return scroll
    }
}
#endif
