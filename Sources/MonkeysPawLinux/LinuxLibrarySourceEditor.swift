#if os(Linux)
import CGtk
import MonkeysPawCore

/// GtkTextView owns native shortcuts, undo and input methods. Model refreshes
/// leave preedit alone and keep undo/caret positions through save normalization.
final class LinuxLibrarySourceEditor {
    /// The complete file and the form's body-only view share this widget,
    /// differing in name, accessible label, font and the state they mirror.
    enum Kind {
        case source, body

        var name: String {
            switch self {
            case .source: return "library-source"
            case .body: return "library-body"
            }
        }

        var label: String {
            switch self {
            case .source: return LinuxEditorStrings.source
            case .body: return LinuxEditorStrings.promptBody
            }
        }

        var monospace: Bool { self == .source }
    }

    private static let quoteTagName = "assistant-quote"
    let kind: Kind
    let widget = gtk_text_view_new()!
    private var buffer: UnsafeMutablePointer<GtkTextBuffer> { gtk_text_view_get_buffer(mp_text_view(widget))! }
    private var path: RelativePath?
    private var revision: UInt64 = 0
    private var isUpdating = false
    private var hasLoadedText = false
    private(set) var hasPreedit = false
    var onEdit: ((String) -> Void)?
    var onCompositionEnded: (() -> Void)?
    var onCompositionChanged: (() -> Void)?

    init(kind: Kind = .source) {
        self.kind = kind
        gtk_widget_set_name(widget, kind.name)
        mp_accessible_label(widget, kind.label)
        gtk_text_view_set_monospace(mp_text_view(widget), kind.monospace ? 1 : 0)
        gtk_text_view_set_wrap_mode(mp_text_view(widget), GTK_WRAP_WORD_CHAR)
        gtk_text_buffer_set_enable_undo(buffer, 1)
        if kind == .source {
            _ = mp_text_buffer_background_tag(buffer, Self.quoteTagName, "#f8e5a0")
        }
        GTK.onSignal(UnsafeMutableRawPointer(buffer), "changed") { [weak self] in
            guard let self, !self.isUpdating, gtk_text_view_get_editable(mp_text_view(self.widget)) != 0 else { return }
            self.onEdit?(self.text)
        }
        GTK.onPreeditChanged(widget) { [weak self] active in
            guard let self else { return }
            self.hasPreedit = active
            self.onCompositionChanged?()
            if !active {
                // GTK emits empty preedit before inserting the committed text.
                // Read the live model on the next idle, after that insertion.
                GTK.onMainLoop { [weak self] in self?.onCompositionEnded?() }
            }
        }
    }

    /// Core ranges are UTF-8 bytes; GtkTextIter offsets count Unicode scalars.
    /// Reject partial scalars rather than highlighting a neighbouring quote.
    func highlight(_ byteRange: Range<Int>?) {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let tag = gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buffer), Self.quoteTagName) else { return }
        gtk_text_buffer_remove_tag(buffer, tag, &start, &end)
        guard let byteRange else { return }
        let bytes = Array(text.utf8)
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= bytes.count,
              let prefix = String(bytes: bytes.prefix(byteRange.lowerBound), encoding: .utf8),
              let quote = String(bytes: bytes[byteRange], encoding: .utf8) else { return }
        let offset = prefix.unicodeScalars.count
        gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(offset))
        gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(offset + quote.unicodeScalars.count))
        gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        gtk_text_view_scroll_to_iter(mp_text_view(widget), &start, 0.1, 0, 0, 0)
    }

    /// The body mirrors the form, which is absent for malformed headers and
    /// read-only files; the source mirrors the complete draft.
    private func content(of state: EditorState) -> (text: String?, editable: Bool) {
        switch kind {
        case .source: return (state.source, state.canEdit)
        case .body: return (state.form?.body, state.canEdit && state.form != nil)
        }
    }

    func update(_ state: EditorState, revision: UInt64, available: Bool) {
        // revision identifies a loaded session, not an edit or save refresh.
        let changedSession = path != state.prompt?.relativePath || self.revision != revision
        isUpdating = true
        defer { isUpdating = false }
        if changedSession {
            gtk_text_view_reset_im_context(mp_text_view(widget))
            hasPreedit = false
            hasLoadedText = false
        }
        path = state.prompt?.relativePath
        self.revision = revision
        let content = content(of: state)
        let editable = available && content.editable
        gtk_text_view_set_editable(mp_text_view(widget), editable ? 1 : 0)
        guard !hasPreedit else { return }
        if !changedSession, state.prompt != nil, content.text == nil, state.readOnlyReason == nil { return }
        let text = content.text ?? ""
        let initialLoad = !hasLoadedText && content.text != nil
        if content.text != nil { hasLoadedText = true }
        let old = self.text
        guard changedSession || !old.utf8.elementsEqual(text.utf8) else { return }

        let insert = offset(of: gtk_text_buffer_get_insert(buffer))
        let bound = offset(of: gtk_text_buffer_get_selection_bound(buffer))
        if changedSession || initialLoad || !editable {
            gtk_text_buffer_begin_irreversible_action(buffer)
            gtk_text_buffer_set_text(buffer, text, Int32(text.utf8.count))
            gtk_text_buffer_end_irreversible_action(buffer)
        } else {
            gtk_text_buffer_begin_user_action(buffer)
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            gtk_text_buffer_delete(buffer, &start, &end)
            gtk_text_buffer_insert(buffer, &start, text, Int32(text.utf8.count))
            gtk_text_buffer_end_user_action(buffer)
        }
        var caret = GtkTextIter()
        var anchor = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret,
            changedSession ? 0 : Self.mappedOffset(insert, from: old, to: text))
        gtk_text_buffer_get_iter_at_offset(buffer, &anchor,
            changedSession ? 0 : Self.mappedOffset(bound, from: old, to: text))
        gtk_text_buffer_select_range(buffer, &caret, &anchor)
    }

    private var text: String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let text = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }

    private func offset(of mark: UnsafeMutablePointer<GtkTextMark>?) -> Int32 {
        var position = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &position, mark)
        return gtk_text_iter_get_offset(&position)
    }

    /// GTK offsets count Unicode scalars, including combining marks. A newly
    /// inserted front-matter header must not move a caret out of the body.
    private static func mappedOffset(_ offset: Int32, from old: String, to new: String) -> Int32 {
        let before = Array(old.unicodeScalars)
        let after = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let point = min(max(Int(offset), 0), before.count)
        if point < prefix { return Int32(point) }
        if point >= before.count - suffix { return Int32(after.count - before.count + point) }
        return Int32(min(point, after.count - suffix))
    }
}
#endif
