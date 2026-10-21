#if os(Linux)
import CGtk

/// GNOME-style structure shared by the Settings pages: a scrolled column of
/// titled groups whose `boxed-list` rows pair a label with a control.
///
/// GTK 4.8 has no clamp widget. A scroller reports a bounded natural width;
/// expanding side spacers center it without stretching the settings column.
enum LinuxSettingsLayout {
    enum Emphasis { case normal, secondary }
    private static let captionChars: Int32 = 72
    private static let columnWidth: Int32 = 640

    static func page(named name: String? = nil) -> (page: GTK.Widget, column: GTK.Widget) {
        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)!
        gtk_widget_set_hexpand(column, 0)
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(column, 18) }
        let scroll = gtk_scrolled_window_new()!
        gtk_widget_set_hexpand(scroll, 0)
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_width(mp_scrolled_window(scroll), 1)
        gtk_scrolled_window_set_max_content_width(mp_scrolled_window(scroll), columnWidth)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), column)
        let page = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        if let name { gtk_widget_set_name(page, name) }
        let lead = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        let trail = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_hexpand(lead, 1)
        gtk_widget_set_hexpand(trail, 1)
        gtk_box_append(mp_box(page), lead)
        gtk_box_append(mp_box(page), scroll)
        gtk_box_append(mp_box(page), trail)
        return (page, column)
    }

    /// Titled group appended to a page column; returns the group's box so
    /// lists, button rows and captions can be appended under the heading.
    static func group(_ title: String, in column: GTK.Widget) -> GTK.Widget {
        let group = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let heading = GTK.label(title)
        gtk_widget_add_css_class(heading, "heading")
        gtk_box_append(mp_box(group), heading)
        gtk_box_append(mp_box(column), group)
        return group
    }

    /// A `boxed-list` GtkListBox inside a group. Selection stays off: rows
    /// hold controls and text, not activatable content.
    static func list(in group: GTK.Widget) -> GTK.Widget {
        let list = gtk_list_box_new()!
        gtk_widget_add_css_class(list, "boxed-list")
        gtk_list_box_set_selection_mode(mp_list_box(list), GTK_SELECTION_NONE)
        gtk_box_append(mp_box(group), list)
        return list
    }

    /// Row content box appended to a list; the caller adds a text block via
    /// `rowText` then the trailing control.
    @discardableResult
    static func row(in list: GTK.Widget) -> GTK.Widget {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_widget_set_margin_top(row, 10)
        gtk_widget_set_margin_bottom(row, 10)
        gtk_widget_set_margin_start(row, 12)
        gtk_widget_set_margin_end(row, 12)
        gtk_list_box_append(mp_list_box(list), row)
        return row
    }

    /// Expanding text block on the row's left, pushing a trailing control to
    /// the right. With no title it acts as the spacer for a controls row.
    /// Returns the block so value and subtitle labels can be appended.
    @discardableResult
    static func rowText(_ title: String? = nil, in row: GTK.Widget) -> GTK.Widget {
        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        if let title { gtk_box_append(mp_box(text), GTK.label(title)) }
        gtk_box_append(mp_box(row), text)
        return text
    }

    /// Label inside a row's text block; `emphasis` marks secondary values.
    @discardableResult
    static func label(_ text: String, name: String? = nil, emphasis: Emphasis = .normal,
                      in box: GTK.Widget) -> GTK.Widget {
        let label = GTK.label(text)
        if let name { gtk_widget_set_name(label, name) }
        if emphasis == .secondary { gtk_widget_add_css_class(label, "dim-label") }
        gtk_label_set_wrap_mode(mp_label(label), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_max_width_chars(mp_label(label), captionChars)
        gtk_box_append(mp_box(box), label)
        return label
    }

    /// Dim, wrapping explanation under a heading or list.
    @discardableResult
    static func caption(_ text: String? = nil, name: String? = nil,
                        in box: GTK.Widget) -> GTK.Widget {
        let caption = label(text ?? "", name: name, emphasis: .secondary, in: box)
        gtk_widget_add_css_class(caption, "caption")
        return caption
    }
}
#endif
