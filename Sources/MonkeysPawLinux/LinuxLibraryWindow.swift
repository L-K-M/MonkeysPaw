#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GTK owns this reusable window. Model subscriptions and borrowed widget
/// pointers are retired before a graph replacement or native destruction.
final class LinuxLibraryWindow {
    private let window: GTK.Widget
    private let openFolder: () -> Void
    private weak var browser: LibraryBrowserModel?
    private var observer: UUID?
    private var isDestroyed = false
    private var isRendering = false
    private var filterPreedit = false
    private var renderedSections: [LibraryBrowserSection] = []
    private var renderedRows: [LibraryBrowserRow] = []
    private var renderedSection: LibrarySectionID?
    private var renderedRowsSection: LibrarySectionID?
    private var messageSelection: LibraryPromptSelection?
    private var message: String?

    private let filter: GTK.Widget
    private let sidebar: GTK.Widget
    private let list: GTK.Widget
    private let preview: GTK.Widget
    private let previewTitle: GTK.Widget
    private let favorite: GTK.Widget
    private let status: GTK.Widget
    private let empty: GTK.Widget

    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, browser: LibraryBrowserModel,
         openFolder: @escaping () -> Void) {
        self.openFolder = openFolder
        window = gtk_application_window_new(application)!
        filter = gtk_entry_new()!
        sidebar = gtk_list_box_new()!
        list = gtk_list_box_new()!
        preview = gtk_text_view_new()!
        previewTitle = GTK.label(LinuxStrings.preview)
        favorite = GTK.button(LinuxStrings.addFavorite) {}
        status = GTK.label("")
        empty = GTK.label(LinuxStrings.noLibraryMatches)

        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.library)
        gtk_window_set_default_size(mp_window(window),
            Int32(Limits.panelSize.width + Limits.panelSize.height), Int32(Limits.setupWindowSize.height))
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            self.isDestroyed = true
            self.unbind()
        }
        GTK.observeKeys(window) { [weak self] key, modifiers in
            self?.keyPressed(key, modifiers: modifiers) ?? false
        }

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 12) }
        let toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_widget_set_name(filter, "library-filter")
        gtk_entry_set_placeholder_text(mp_entry(filter), LinuxStrings.filterLibrary)
        mp_accessible_label(filter, LinuxStrings.filterLibrary)
        gtk_widget_set_hexpand(filter, 1)
        GTK.onSignal(filter, "changed") { [weak self] in
            guard let self, !self.isDestroyed, !self.isRendering else { return }
            self.browser?.setFilter(String(cString: mp_entry_text(self.filter)))
        }
        if let text = mp_entry_text_delegate(filter) {
            GTK.onPreeditChanged(text) { [weak self] active in self?.filterPreedit = active }
        }
        gtk_widget_set_name(favorite, "library-favorite")
        GTK.onSignal(favorite, "clicked") { [weak self] in self?.toggleFavorite() }
        let reveal = GTK.button(LinuxStrings.openFolder) { [weak self] in
            guard let self, self.isVisible else { return }
            self.openFolder()
        }
        gtk_widget_set_name(reveal, "library-open-folder")
        for widget in [filter, favorite, reveal] { gtk_box_append(mp_box(toolbar), widget) }
        gtk_box_append(mp_box(content), toolbar)

        let panes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_widget_set_vexpand(panes, 1)
        configureList(sidebar, name: "library-sidebar", label: LinuxStrings.librarySections)
        configureList(list, name: "library-list", label: LinuxStrings.libraryPrompts)
        GTK.onRow(sidebar, "row-selected") { [weak self] position in
            guard let self, !self.isDestroyed, !self.isRendering, let position,
                  self.renderedSections.indices.contains(position) else { return }
            self.browser?.selectSection(self.renderedSections[position].id)
        }
        GTK.onRow(list, "row-selected") { [weak self] position in
            guard let self, !self.isDestroyed, !self.isRendering, let position,
                  self.renderedRows.indices.contains(position) else { return }
            self.browser?.selectPrompt(self.renderedRows[position].selection)
        }
        gtk_box_append(mp_box(panes), scrolled(sidebar, width: Limits.panelSize.width / 4))
        let results = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_hexpand(results, 1)
        gtk_box_append(mp_box(results), scrolled(list, width: Limits.panelSize.width / 2))
        gtk_widget_set_name(empty, "library-empty")
        gtk_box_append(mp_box(results), empty)
        gtk_box_append(mp_box(panes), results)
        let detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_hexpand(detail, 1)
        gtk_widget_set_name(previewTitle, "library-preview-title")
        gtk_box_append(mp_box(detail), previewTitle)
        gtk_widget_set_name(preview, "library-preview")
        mp_accessible_label(preview, LinuxStrings.preview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(preview), GTK_WRAP_WORD_CHAR)
        gtk_box_append(mp_box(detail), scrolled(preview, width: Limits.panelSize.width / 2))
        gtk_box_append(mp_box(panes), detail)
        gtk_box_append(mp_box(content), panes)
        gtk_widget_set_name(status, "library-status")
        gtk_box_append(mp_box(content), status)
        gtk_box_append(mp_box(content), GTK.label(LinuxStrings.libraryHint))
        gtk_window_set_child(mp_window(window), content)
        rebind(browser: browser)
    }

    deinit { unbind() }

    func rebind(browser: LibraryBrowserModel) {
        guard !isDestroyed else { return }
        unbind()
        self.browser = browser
        filterPreedit = false
        message = nil
        messageSelection = nil
        observer = browser.addObserver { [weak self, weak browser] _ in
            guard let self, let browser, self.browser === browser else { return }
            self.render()
        }
        render()
    }

    func show() {
        guard !isDestroyed else { return }
        render()
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(filter)
    }

    func hide() {
        guard !isDestroyed else { return }
        gtk_widget_set_visible(window, 0)
    }

    private func unbind() {
        if let observer { browser?.removeObserver(observer) }
        observer = nil
        browser = nil
    }

    private func render() {
        guard !isDestroyed, let browser else { return }
        isRendering = true
        defer { isRendering = false }
        let state = browser.state
        if !String(cString: mp_entry_text(filter)).utf8.elementsEqual(state.filter.utf8) {
            mp_entry_set_text(filter, state.filter)
        }
        if messageSelection != state.selection { message = nil }
        renderSections(state)
        renderRows(state)
        gtk_widget_set_visible(empty, state.rows.isEmpty ? 1 : 0)
        gtk_label_set_text(mp_label(previewTitle), state.selectedPrompt?.title ?? LinuxStrings.preview)
        let text: String
        if let row = state.selectedPrompt, !row.canRender {
            text = row.issues.map(\.message).joined(separator: "\n")
        } else if let entry = browser.selectedEntry {
            text = LinuxLibraryPreview.text(for: entry.document)
        } else { text = LinuxStrings.selectLibraryPrompt }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), text, -1)
        let favoriteTitle = state.selectedPrompt?.favorite == true
            ? LinuxStrings.removeFavorite : LinuxStrings.addFavorite
        gtk_button_set_label(mp_button(favorite), favoriteTitle)
        mp_accessible_label(favorite, favoriteTitle)
        gtk_widget_set_sensitive(favorite, state.selectedPrompt != nil && state.selectedPrompt?.isReadOnly == false ? 1 : 0)
        gtk_label_set_text(mp_label(status), message ?? "")
        gtk_widget_set_visible(status, message == nil ? 0 : 1)
    }

    private func renderSections(_ state: LibraryBrowserState) {
        if renderedSections != state.sections {
            let hadFocus = containsFocus(sidebar)
            clear(sidebar)
            renderedSections = state.sections
            for section in state.sections {
                let label = GTK.label("\(section.title) (\(section.count))")
                gtk_widget_set_margin_start(label, Int32(section.depth * 12))
                let accessibleTitle: String
                if case .folder(let path) = section.id { accessibleTitle = path.string }
                else { accessibleTitle = section.title }
                mp_accessible_label(label, "\(accessibleTitle) (\(section.count))")
                gtk_list_box_append(mp_list_box(sidebar), label)
            }
            select(in: sidebar, position: state.sections.firstIndex { $0.id == state.selectedSection }, focus: hadFocus)
        } else if renderedSection != state.selectedSection {
            select(in: sidebar, position: state.sections.firstIndex { $0.id == state.selectedSection })
        }
        renderedSection = state.selectedSection
    }

    private func renderRows(_ state: LibraryBrowserState) {
        let hadFocus = containsFocus(list)
        if renderedRows != state.rows || (renderedRowsSection == .recent) != (state.selectedSection == .recent) {
            clear(list)
            renderedRows = state.rows
            for row in state.rows {
                let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
                let title = (row.favorite ? "★ " : "") + row.title
                gtk_box_append(mp_box(content), rowLabel(title))
                gtk_box_append(mp_box(content), rowLabel(row.relativePath.string))
                var badges = [String]()
                if row.isReadOnly { badges.append(LinuxStrings.readOnly) }
                if !row.canRender { badges.append(LinuxStrings.invalidPrompt) }
                if state.selectedSection == .recent, let lastUsed = row.lastUsedAt {
                    badges.append(LinuxStrings.lastUsed(lastUsed))
                }
                if !badges.isEmpty { gtk_box_append(mp_box(content), rowLabel(badges.joined(separator: " · "))) }
                mp_accessible_label(content, ([title, row.relativePath.string] + badges).joined(separator: ", "))
                gtk_list_box_append(mp_list_box(list), content)
            }
        }
        renderedRowsSection = state.selectedSection
        select(in: list, position: state.rows.firstIndex { $0.selection == state.selection }, focus: hadFocus)
    }

    private func toggleFavorite() {
        guard isVisible, let browser, browser.state.selectedPrompt?.isReadOnly == false else { return }
        message = LinuxStrings.favoriteMessage(browser.toggleFavorite())
        messageSelection = browser.selection
        render()
    }

    private func keyPressed(_ key: UInt32, modifiers: UInt32) -> Bool {
        guard isVisible, let browser else { return false }
        // Native IME cancellation belongs to the focused filter's input method.
        if filterPreedit, containsFocus(filter) { return false }
        let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
        let modifiers = modifiers & relevant
        if key == UInt32(GDK_KEY_Escape), modifiers == 0 {
            if !browser.filter.isEmpty { browser.setFilter(""); render() }
            else { hide() }
            return true
        }
        if [UInt32(GDK_KEY_d), UInt32(GDK_KEY_D)].contains(key), modifiers == GDK_CONTROL_MASK.rawValue {
            toggleFavorite()
            return true
        }
        return false // GTK owns list arrows, activation and Tab traversal.
    }

    private func containsFocus(_ widget: GTK.Widget) -> Bool {
        guard let focus = gtk_window_get_focus(mp_window(window)) else { return false }
        return focus == widget || gtk_widget_is_ancestor(focus, widget) != 0
    }

    private func select(in list: GTK.Widget, position: Int?, focus: Bool = false) {
        let row = position.flatMap { gtk_list_box_get_row_at_index(mp_list_box(list), Int32($0)) }
        gtk_list_box_select_row(mp_list_box(list), row)
        guard focus else { return }
        // Get the row as a GtkWidget without assuming the C importer's row type.
        var widget = gtk_widget_get_first_child(list)
        for _ in 0..<(position ?? 0) { widget = widget.flatMap(gtk_widget_get_next_sibling) }
        gtk_widget_grab_focus(position == nil ? list : widget)
    }

    private func configureList(_ widget: GTK.Widget, name: String, label: String) {
        gtk_widget_set_name(widget, name)
        mp_accessible_label(widget, label)
        gtk_list_box_set_selection_mode(mp_list_box(widget), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(mp_list_box(widget), 0)
        gtk_widget_add_css_class(widget, "navigation-sidebar")
    }

    private func clear(_ list: GTK.Widget) {
        while let row = gtk_widget_get_first_child(list) { gtk_list_box_remove(mp_list_box(list), row) }
    }

    private func rowLabel(_ text: String) -> GTK.Widget {
        let label = GTK.label(text)
        gtk_label_set_wrap(mp_label(label), 0)
        gtk_label_set_ellipsize(mp_label(label), PANGO_ELLIPSIZE_END)
        gtk_widget_set_tooltip_text(label, text)
        return label
    }

    private func scrolled(_ child: GTK.Widget, width: Int) -> GTK.Widget {
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_min_content_width(mp_scrolled_window(scroll), Int32(width))
        gtk_widget_set_hexpand(scroll, 1)
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), child)
        return scroll
    }
}
#endif
