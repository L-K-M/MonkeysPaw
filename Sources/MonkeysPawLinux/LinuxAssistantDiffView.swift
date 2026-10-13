#if os(Linux)
import CGtk
import MonkeysPawCore

/// Render Core's final merged comparison. Tags mark changed lines; blank rows
/// align insertions/deletions without changing the candidate's saved bytes.
final class LinuxAssistantDiffView {
    let widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
    private var rendered: ArtifactDiff?
    private var views: [(GTK.Widget, GTK.Widget)] = []

    init() {
        gtk_widget_set_name(widget, "assistant-diff")
        for (name, title) in [("header", "Front matter"), ("body", "Body")] {
            gtk_box_append(mp_box(widget), GTK.label(title))
            let panes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            var pair: [GTK.Widget] = []
            for (side, label) in [("before", "Before"), ("after", "Merged candidate")] {
                let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
                gtk_widget_set_hexpand(column, 1)
                gtk_box_append(mp_box(column), GTK.label(label))
                let view = gtk_text_view_new()!
                gtk_widget_set_name(view, "assistant-diff-" + name + "-" + side)
                mp_accessible_label(view, title + ": " + label)
                gtk_text_view_set_editable(mp_text_view(view), 0)
                gtk_text_view_set_cursor_visible(mp_text_view(view), 0)
                gtk_text_view_set_monospace(mp_text_view(view), 1)
                let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
                _ = mp_text_buffer_background_tag(buffer, "assistant-change", side == "before" ? "#f6d5d5" : "#d5efd5")
                _ = mp_text_buffer_background_tag(buffer, "assistant-placeholder-change", "#f8e5a0")
                let scroll = gtk_scrolled_window_new()!
                gtk_widget_set_size_request(scroll, 160, 90)
                gtk_scrolled_window_set_child(mp_scrolled_window(scroll), view)
                gtk_box_append(mp_box(column), scroll)
                gtk_box_append(mp_box(panes), column)
                pair.append(view)
            }
            views.append((pair[0], pair[1]))
            gtk_box_append(mp_box(widget), panes)
        }
    }

    func update(_ diff: ArtifactDiff?) {
        gtk_widget_set_visible(widget, diff == nil ? 0 : 1)
        guard rendered != diff else { return }
        rendered = diff
        for (index, rows) in [diff?.frontMatter ?? [], diff?.body ?? []].enumerated() {
            render(rows, in: views[index].0, side: .removed)
            render(rows, in: views[index].1, side: .added)
        }
    }

    private func render(_ rows: [LineDiffLine], in view: GTK.Widget, side: LineDiffLine.Kind) {
        var text = ""
        var changed: [Range<Int>] = []
        var placeholders: [Range<Int>] = []
        var offset = 0
        for row in rows {
            let present = row.kind == .unchanged || row.kind == side
            var line = present ? row.text : "\n"
            if present, !line.hasSuffix("\n") { line += "\n[No newline at end]\n" }
            let end = offset + line.unicodeScalars.count
            if row.kind == side {
                changed.append(offset..<end)
                if !row.placeholderWarnings.isEmpty { placeholders.append(offset..<end) }
            }
            text += line
            offset = end
        }
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        gtk_text_buffer_set_text(buffer, text, Int32(text.utf8.count))
        for (name, ranges) in [("assistant-change", changed), ("assistant-placeholder-change", placeholders)] {
            for range in ranges {
                var start = GtkTextIter(), end = GtkTextIter()
                gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(range.lowerBound))
                gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(range.upperBound))
                let tag = gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buffer), name)
                gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
            }
        }
    }
}
#endif
