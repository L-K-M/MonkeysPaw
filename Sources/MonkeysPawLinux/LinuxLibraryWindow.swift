#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GTK owns this reusable window. Model subscriptions and borrowed widget
/// pointers are retired before a graph replacement or native destruction.
final class LinuxLibraryWindow {
    private enum OpenContext { case library, creation }
    struct ImportBinding {
        let state: LinuxLibraryImportState
        let chooser: LinuxImportChoosing
    }

    private let window: GTK.Widget
    private let openFolder: () -> Void
    private let showSettings: () -> Void
    private let showAbout: (GTK.Widget) -> Void
    private let showFiles: ((RelativePath) -> Void)?
    private var createPrompt: (String, RelativePath) -> LibraryPromptSelection?
    private weak var browser: LibraryBrowserModel?
    private weak var editor: EditorModel?
    private var assistantProvider: () -> AssistantModel? = { nil }
    private let assistantPanel = LinuxAssistantPanel()
    private var conflictProvider: () -> ConflictModel? = { nil }
    private weak var conflictModel: ConflictModel?
    private let conflictView = LinuxConflictView()
    private let syncStatusView = LinuxSyncStatusView(surface: .library)
    private var assistantMessage: String?
    private var assistantMessagePrompt: LibraryPromptSelection?
    private var assistantMessageStamp: FileStamp?
    private var renderedEditorStatus: EditorStatus?
    private var observer: UUID?
    private var editorObserver: UUID?
    private var bindingRevision: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var previousPrompt: LibraryPromptSelection?
    private var copySelection: LibraryPromptSelection?
    private var revealAfterOpen: [LibraryPromptSelection] = []
    private var focusAfterOpen: LibraryPromptSelection?
    private var closeRequested = false
    private var available = true
    private var activeDialog: LinuxEditorDialogState?
    private var newPromptRequest: LinuxNewPromptRequest?
    private weak var imports: LinuxLibraryImportState?
    private var dialog: LinuxEditorDialog?
    private var dialogRevision: UInt64 = 0
    private var dismissedConflict: EditorConflict?
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
    private let newPrompt = gtk_button_new()!
    private let sidebar: GTK.Widget
    private let list: GTK.Widget
    private let preview: GTK.Widget
    private let favorite: GTK.Widget
    private let status: GTK.Widget
    private let empty: GTK.Widget
    private enum Size {
        static let width: Int32 = 1180
        static let height: Int32 = 720
        static let sidebar: Int32 = 220
        static let list: Int32 = 300
        static let inspector: Int32 = 320
    }
    private let title = GTK.label("")
    private let subtitle = GTK.label("")
    private let searchBar = gtk_search_bar_new()!
    private let editorStack = gtk_stack_new()!
    private let inspectorStack = gtk_stack_new()!
    private let inspectorPane = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    private let sidebarPane = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    private let editToggle = gtk_toggle_button_new_with_label(LinuxStrings.edit)!
    private let previewToggle = gtk_toggle_button_new_with_label(LinuxStrings.preview)!
    private let sourceToggle = gtk_toggle_button_new_with_label(LinuxStrings.source)!
    private let inspectorToggle = gtk_toggle_button_new()!
    private let searchToggle = gtk_toggle_button_new()!
    private let issuesRevealer = gtk_revealer_new()!
    private let validationSummary = GTK.button("") {}
    private var actions: [LinuxLibraryAction: OpaquePointer] = [:]
    private var contextMenu: GTK.Widget?
    private var contextModel: OpaquePointer?
    private var contextFavorite: Bool?
    private var contextSelection: LibraryPromptSelection?
    private enum EditorMode { case edit, preview, source }
    private var mode: EditorMode = .edit
    private let source = LinuxLibrarySourceEditor()
    private let body = LinuxLibrarySourceEditor(kind: .body)
    private let formBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    private let fieldsSection = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
    private let fieldsRows = gtk_list_box_new()!
    private var fieldButtons: [GTK.Widget] = []
    private var fieldDialog: LinuxFieldSettingsDialog?
    private var fieldDialogRevision: UInt64 = 0
    private var fieldDialogName: String?
    private var fieldDialogPrompt: LibraryPromptSelection?
    private var fieldDialogSource: String?
    private let titleEntry = gtk_entry_new()!
    private let descriptionEntry = gtk_entry_new()!
    private let tagsFlow = gtk_flow_box_new()!
    private let tagEntry = gtk_entry_new()!
    private let tagAdd = gtk_button_new_with_label(LinuxEditorStrings.addTag)!
    private let privateToggle = gtk_check_button_new_with_label(LinuxEditorStrings.privateToggle)!
    private let privateHint = GTK.label(LinuxEditorStrings.privateHint)
    private let fallbackBar = gtk_info_bar_new()!
    private let fallback = GTK.label(LinuxEditorStrings.formUnavailable)
    private var isUpdatingForm = false
    private var formPreedit = false
    private var renderedTags: [String] = []
    private var renderedTagsRevision: UInt64?
    private var renderedFormRevision: UInt64?
    private var renderedFieldSettings: [PromptFieldSettings]?
    private var renderedFieldSettingsRevision: UInt64?
    private let readOnly = GTK.label("")
    private let readOnlyBar = gtk_info_bar_new()!
    private let validation = GTK.label("")
    private let fields = gtk_list_box_new()!
    private let editorStatus = GTK.label("")
    private let editorEmpty = GTK.label(LinuxStrings.selectLibraryPrompt)
    private let history = LinuxLibraryHistoryView()
    private let commands: LinuxLibraryCommands
    private var historyPrompt: LibraryPromptSelection?
    private var historyReloadPending = false
    private var renderedFields: [PromptField]?
    private var renderedPreview: String?
    private var importView: LinuxLibraryImportView?

    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, browser: LibraryBrowserModel, editor: EditorModel,
         imports: ImportBinding? = nil,
         assistant: @escaping () -> AssistantModel? = { nil },
         conflict: @escaping () -> ConflictModel? = { nil },
         syncStatus: SyncStatusModel? = nil,
         syncNavigation: @escaping (SyncStatusAction) -> Void = { _ in },
         showSettings: @escaping () -> Void = {}, showAbout: @escaping (GTK.Widget) -> Void = { _ in },
         showFiles: ((RelativePath) -> Void)? = nil,
         createPrompt: @escaping (String, RelativePath) -> LibraryPromptSelection? = { _, _ in nil },
         openFolder: @escaping () -> Void) {
        self.openFolder = openFolder
        self.showSettings = showSettings
        self.showAbout = showAbout
        self.showFiles = showFiles
        self.createPrompt = createPrompt
        window = gtk_application_window_new(application)!
        LinuxStyle.install(on: window)
        commands = LinuxLibraryCommands(parent: window)
        filter = gtk_search_entry_new()!
        sidebar = gtk_list_box_new()!
        list = gtk_list_box_new()!
        preview = gtk_text_view_new()!
        favorite = gtk_toggle_button_new()!
        status = GTK.label("")
        empty = GTK.label(LinuxStrings.noLibraryMatches)
        commands.onChange = { [weak self] in
            self?.render()
        }

        GTK.hideOnClose(window)
        GTK.onCloseRequested(window) { [weak self] in self?.requestClose() }
        gtk_window_set_title(mp_window(window), LinuxStrings.library)
        gtk_window_set_default_size(mp_window(window), Size.width, Size.height)
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            if let menu = self.contextMenu { gtk_widget_unparent(menu); self.contextMenu = nil }
            self.isDestroyed = true
            self.unbind()
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isVisible { self.syncStatusView.show(); self.render() }
            else {
                self.newPromptRequest = nil
                if case .newPrompt = self.activeDialog { self.endDialog() }
                self.syncStatusView.suspend()
                self.commands.cancelDialog(); self.endFieldDialog()
                self.assistantPanel.close(); self.conflictView.close()
            }
        }
        GTK.observeKeys(window) { [weak self] key, modifiers in
            self?.keyPressed(key, modifiers: modifiers) ?? false
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "focus-widget") { [weak self] in self?.updateActions() }
        GTK.onNotify(UnsafeMutableRawPointer(window), "is-active") { [weak self] in self?.updateActions() }

        installActions(application: application)
        configureHeader()
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_name(filter, "library-filter")
        GTK.searchPlaceholder(filter, LinuxStrings.filterLibrary)
        mp_accessible_label(filter, LinuxStrings.filterLibrary)
        gtk_widget_set_hexpand(filter, 1)
        GTK.onSignal(filter, "changed") { [weak self] in
            guard let self, !self.isDestroyed, !self.isRendering else { return }
            self.browser?.setFilter(String(cString: mp_entry_text(self.filter)))
        }
        if let text = mp_entry_text_delegate(filter) {
            GTK.onPreeditChanged(text) { [weak self] active in
                self?.filterPreedit = active
                self?.updateActions()
            }
        }
        gtk_search_bar_set_child(mp_search_bar(searchBar), filter)
        gtk_search_bar_connect_entry(mp_search_bar(searchBar), mp_editable(filter))
        // No key-capture widget: editor typing must never open library search.
        GTK.onNotify(UnsafeMutableRawPointer(searchBar), "search-mode-enabled") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            gtk_toggle_button_set_active(mp_toggle_button(self.searchToggle),
                gtk_search_bar_get_search_mode(mp_search_bar(self.searchBar)))
        }
        gtk_box_append(mp_box(content), searchBar)
        if let imports {
            let view = LinuxLibraryImportView(parent: window, list: list, chooser: imports.chooser)
            importView = view
            view.onChange = { [weak self] in self?.updateActions() }
            gtk_box_append(mp_box(content), view.widget)
        }

        configureList(sidebar, name: "library-sidebar", label: LinuxStrings.librarySections)
        gtk_widget_set_name(sidebarPane, "library-sidebar-pane")
        gtk_widget_add_css_class(sidebar, "navigation-sidebar")
        configureSectionHeaders()
        configureList(list, name: "library-list", label: LinuxStrings.libraryPrompts)
        gtk_widget_add_css_class(list, "rich-list")
        GTK.onRow(sidebar, "row-selected") { [weak self] position in
            guard let self, !self.isDestroyed, !self.isRendering, let position,
                  self.renderedSections.indices.contains(position) else { return }
            self.browser?.selectSection(self.renderedSections[position].id)
        }
        GTK.onRow(list, "row-selected") { [weak self] position in
            guard let self, !self.isDestroyed, !self.isRendering, let position,
                  self.renderedRows.indices.contains(position) else { return }
            self.selectPrompt(self.renderedRows[position].selection)
        }
        GTK.onRow(list, "row-activated") { [weak self] _ in self?.activate(.edit) }
        gtk_box_append(mp_box(sidebarPane), scrolled(sidebar, width: 150))
        gtk_box_append(mp_box(sidebarPane), syncStatusView.widget)
        let results = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_vexpand(results, 1)
        gtk_box_append(mp_box(results), scrolled(list, width: 160))
        gtk_widget_set_name(empty, "library-empty")
        gtk_widget_add_css_class(empty, "dim-label")
        gtk_widget_set_halign(empty, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(empty, GTK_ALIGN_CENTER)
        gtk_list_box_set_placeholder(mp_list_box(list), empty)
        configureContextMenu(in: results)
        let detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_hexpand(detail, 1)
        configureEditor(in: detail)
        configureInspector()
        let editorPanes = paned(detail, inspectorPane, position: Int(Size.width - Size.sidebar - Size.list - Size.inspector))
        gtk_paned_set_resize_end_child(mp_paned(editorPanes), 0)
        gtk_paned_set_shrink_start_child(mp_paned(editorPanes), 0)
        gtk_paned_set_shrink_end_child(mp_paned(editorPanes), 0)
        let listPanes = paned(results, editorPanes, position: Int(Size.list))
        gtk_paned_set_resize_start_child(mp_paned(listPanes), 0)
        gtk_paned_set_shrink_end_child(mp_paned(listPanes), 0)
        let panes = paned(sidebarPane, listPanes, position: Int(Size.sidebar))
        gtk_paned_set_resize_start_child(mp_paned(panes), 0)
        gtk_paned_set_shrink_end_child(mp_paned(panes), 0)
        gtk_widget_set_vexpand(panes, 1)
        gtk_widget_set_visible(inspectorPane, 0)
        gtk_box_append(mp_box(content), panes)
        gtk_widget_set_name(status, "library-status")
        gtk_box_append(mp_box(content), status)
        gtk_window_set_child(mp_window(window), content)
        rebind(browser: browser, editor: editor, imports: imports?.state, assistant: assistant, conflict: conflict,
               syncStatus: syncStatus, syncNavigation: syncNavigation, createPrompt: createPrompt)
    }

    private func configureHeader() {
        let header = gtk_header_bar_new()!
        gtk_window_set_titlebar(mp_window(window), header)
        let titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_name(title, "library-title")
        gtk_widget_set_name(subtitle, "library-subtitle")
        gtk_widget_add_css_class(title, "title")
        gtk_widget_add_css_class(subtitle, "subtitle")
        gtk_widget_add_css_class(subtitle, "dim-label")
        for label in [title, subtitle] {
            gtk_label_set_wrap(mp_label(label), 0)
            gtk_label_set_ellipsize(mp_label(label), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(mp_label(label), 44)
            gtk_label_set_xalign(mp_label(label), 0.5)
            gtk_box_append(mp_box(titles), label)
        }
        gtk_header_bar_set_title_widget(mp_header_bar(header), titles)
        let sidebarButton = gtk_toggle_button_new()!
        configureIcon(sidebarButton, icon: "sidebar-show-symbolic", label: LinuxLibraryStrings.sidebar,
                      name: "library-sidebar-toggle", action: .sidebar)
        gtk_header_bar_pack_start(mp_header_bar(header), sidebarButton)
        configureIcon(newPrompt, icon: "document-new-symbolic", label: LinuxStrings.newPrompt,
                      name: "library-new-prompt", action: .newPrompt)
        gtk_header_bar_pack_start(mp_header_bar(header), newPrompt)
        let menu = gtk_menu_button_new()!
        gtk_widget_set_name(menu, "library-menu")
        gtk_menu_button_set_icon_name(mp_menu_button(menu), "open-menu-symbolic")
        mp_accessible_label(menu, LinuxLibraryStrings.menu)
        let model = primaryMenu()
        gtk_menu_button_set_menu_model(mp_menu_button(menu), mp_menu_model(model))
        g_object_unref(UnsafeMutableRawPointer(model))
        gtk_header_bar_pack_end(mp_header_bar(header), menu)
        configureIcon(inspectorToggle, icon: "sidebar-show-right-symbolic", label: LinuxLibraryStrings.inspector,
                      name: "library-inspector-toggle", action: .inspector)
        gtk_header_bar_pack_end(mp_header_bar(header), inspectorToggle)
        configureIcon(searchToggle, icon: "system-search-symbolic", label: LinuxLibraryStrings.search,
                      name: "library-search-toggle", action: .search)
        gtk_actionable_set_action_name(mp_actionable(searchToggle), nil)
        GTK.onSignal(searchToggle, "clicked") { [weak self] in
            guard let self, self.isEnabled(.search) else { return }
            let reveal = gtk_toggle_button_get_active(mp_toggle_button(self.searchToggle))
            gtk_search_bar_set_search_mode(mp_search_bar(self.searchBar), reveal)
            if reveal != 0 { gtk_widget_grab_focus(self.filter) }
        }
        gtk_header_bar_pack_end(mp_header_bar(header), searchToggle)
        configureIcon(favorite, icon: "non-starred-symbolic", label: LinuxStrings.addFavorite,
                      name: "library-favorite", action: .favorite)
        gtk_header_bar_pack_end(mp_header_bar(header), favorite)
        let modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(modes, "linked")
        for (button, name, action) in [(editToggle, "library-mode-edit", LinuxLibraryAction.edit),
                                       (previewToggle, "library-mode-preview", .preview),
                                       (sourceToggle, "library-mode-source", .source)] {
            gtk_widget_set_name(button, name)
            gtk_actionable_set_action_name(mp_actionable(button), "win." + action.rawValue)
            gtk_box_append(mp_box(modes), button)
        }
        gtk_header_bar_pack_end(mp_header_bar(header), modes)
    }

    private func configureIcon(_ button: GTK.Widget, icon: String, label: String,
                               name: String, action: LinuxLibraryAction) {
        gtk_button_set_icon_name(mp_button(button), icon)
        gtk_widget_set_name(button, name)
        gtk_widget_set_tooltip_text(button, label)
        mp_accessible_label(button, label)
        gtk_actionable_set_action_name(mp_actionable(button), "win." + action.rawValue)
    }

    private func primaryMenu() -> OpaquePointer {
        let menu = g_menu_new()!
        let sections: [[(String, LinuxLibraryAction)]] = [
            [(LinuxStrings.newPrompt, .newPrompt), (LinuxLibraryStrings.importFiles, .importFiles), (LinuxLibraryStrings.importFolder, .importFolder)],
            [(LinuxEditorStrings.save, .save), (LinuxLibraryStrings.duplicate, .duplicate), (LinuxLibraryStrings.revert, .revert)],
            [(LinuxEditorStrings.rename, .rename), (LinuxEditorStrings.move, .move),
             (LinuxLibraryStrings.showFiles, .showFiles), (LinuxEditorStrings.delete, .delete)],
            [(LinuxLibraryStrings.sidebar, .sidebar), (LinuxLibraryStrings.inspector, .inspector),
             (LinuxAssistantStrings.title, .assistant)],
            [(LinuxStrings.openSettings, .settings), (LinuxAboutStrings.title, .about)]
        ]
        for items in sections {
            let section = g_menu_new()!
            for (title, action) in items { g_menu_append(section, title, "win." + action.rawValue) }
            g_menu_append_section(menu, nil, mp_menu_model(section))
            g_object_unref(UnsafeMutableRawPointer(section))
        }
        return menu
    }

    private func configureContextMenu(in anchor: GTK.Widget) {
        let model = g_menu_new()!
        for (title, action) in [(LinuxStrings.edit, LinuxLibraryAction.edit),
                               (LinuxStrings.addFavorite, .favorite), (LinuxEditorStrings.rename, .rename),
                               (LinuxEditorStrings.move, .move), (LinuxLibraryStrings.duplicate, .duplicate),
                               (LinuxLibraryStrings.showFiles, .showFiles), (LinuxEditorStrings.delete, .delete)] {
            g_menu_append(model, title, "win." + action.rawValue)
        }
        let menu = gtk_popover_menu_new_from_model(mp_menu_model(model))!
        contextModel = model
        g_object_unref(UnsafeMutableRawPointer(model))
        gtk_widget_set_name(menu, "library-context-menu")
        // ListBox owns only rows and its placeholder. Anchor the popover to
        // the surrounding box so list disposal never tries to remove it as a row.
        gtk_widget_set_parent(menu, anchor)
        contextMenu = menu
        GTK.onSignal(menu, "destroy") { [weak self] in
            self?.contextMenu = nil
            self?.contextModel = nil
        }
        GTK.onSignal(menu, "closed") { [weak self] in
            self?.contextSelection = nil
            self?.updateActions()
        }
        GTK.onSecondaryClick(list) { [weak self] x, y in
            guard let self, self.commandsAvailable,
                  let row = gtk_list_box_get_row_at_y(mp_list_box(self.list), Int32(y)) else { return }
            let index = Int(gtk_list_box_row_get_index(row))
            guard self.renderedRows.indices.contains(index) else { return }
            self.contextSelection = self.renderedRows[index].selection
            gtk_list_box_select_row(mp_list_box(self.list), row)
            self.updateActions()
            var targetX = 0.0, targetY = 0.0
            guard gtk_widget_translate_coordinates(self.list, anchor, x, y, &targetX, &targetY) != 0 else { return }
            var point = GdkRectangle(x: Int32(targetX), y: Int32(targetY), width: 1, height: 1)
            gtk_popover_set_pointing_to(mp_popover(menu), &point)
            gtk_popover_popup(mp_popover(menu))
        }
    }

    private func configureSectionHeaders() {
        GTK.listHeaders(sidebar) { [weak self] index, before in
            guard let self, self.renderedSections.indices.contains(index) else { return nil }
            let group = self.sectionHeading(self.renderedSections[index].id)
            if let before, self.renderedSections.indices.contains(before),
               self.sectionHeading(self.renderedSections[before].id) == group { return nil }
            return group
        }
    }

    private func sectionHeading(_ section: LibrarySectionID) -> String {
        switch section {
        case .all, .favourites, .recent, .conflicts: return LinuxLibraryStrings.library
        case .group: return LinuxLibraryStrings.groups
        case .folder: return LinuxLibraryStrings.folders
        case .tag: return LinuxLibraryStrings.tags
        }
    }

    private func paned(_ start: GTK.Widget, _ end: GTK.Widget, position: Int) -> GTK.Widget {
        let pane = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(mp_paned(pane), start)
        gtk_paned_set_end_child(mp_paned(pane), end)
        gtk_paned_set_position(mp_paned(pane), Int32(position))
        return pane
    }

    private var inspectorPage: String? {
        gtk_stack_get_visible_child_name(mp_stack(inspectorStack)).map { String(cString: $0) }
    }

    private func showInspector(_ page: String) {
        gtk_widget_set_visible(inspectorPane, 1)
        gtk_stack_set_visible_child_name(mp_stack(inspectorStack), page)
        if page == "assistant" { assistantPanel.show() }
        updateActions()
    }

    private func setMode(_ mode: EditorMode) {
        self.mode = mode
        applyEditorMode()
        updateActions()
    }

    /// The form mirrors a parsed document only. Malformed headers and
    /// read-only files show the full source in Edit with an explanation.
    /// A loading document has no form yet; that is not a fallback.
    private var formIsVisible: Bool {
        let state = editor?.state
        return state?.prompt == nil || state?.source == nil || state?.form != nil
    }

    private func applyEditorMode() {
        let page = mode == .preview ? "preview" : (mode == .edit && formIsVisible) ? "edit" : "source"
        gtk_stack_set_visible_child_name(mp_stack(editorStack), page)
        gtk_widget_set_visible(fallbackBar, mode == .edit && !formIsVisible
            && editor?.state.readOnlyReason == nil ? 1 : 0)
    }

    /// Commands and reveals focus the editor the user actually sees.
    private var visibleEditor: GTK.Widget {
        switch mode {
        case .source: return source.widget
        case .preview: return preview
        case .edit: return formIsVisible ? body.widget : source.widget
        }
    }

    private var focusedHasPreedit: Bool {
        (filterPreedit && containsFocus(filter)) || (source.hasPreedit && containsFocus(source.widget))
            || (body.hasPreedit && containsFocus(body.widget))
            || (formPreedit && (containsFocus(titleEntry) || containsFocus(descriptionEntry)
                || containsFocus(tagEntry))) || assistantPanel.hasPreedit
    }

    private var commandsAvailable: Bool {
        isVisible && activeDialog == nil && !commands.hasDialog && importView?.isChoosing != true && !focusedHasPreedit
            && !hasModalChild()
    }

    private func hasModalChild(named name: String? = nil) -> Bool {
        let windows = gtk_window_get_toplevels()!
        for index in 0..<g_list_model_get_n_items(windows) {
            guard let item = g_list_model_get_item(windows, index) else { continue }
            defer { g_object_unref(item) }
            let child = item.assumingMemoryBound(to: GtkWindow.self)
            if gtk_window_get_modal(child) != 0, gtk_widget_get_visible(mp_window_widget(child)) != 0,
               gtk_window_get_transient_for(child) == mp_window(window),
               name == nil || String(cString: gtk_widget_get_name(mp_window_widget(child))) == name { return true }
        }
        return false
    }

    private func installActions(application: UnsafeMutablePointer<GtkApplication>) {
        for command in LinuxLibraryAction.allCases {
            let action: OpaquePointer
            switch command {
            case .sidebar, .inspector, .favorite, .edit, .preview, .source:
                action = g_simple_action_new_stateful(command.rawValue, nil, g_variant_new_boolean(0))!
            default: action = g_simple_action_new(command.rawValue, nil)!
            }
            actions[command] = action // The window's action map owns this reference.
            GTK.onActionActivated(UnsafeMutableRawPointer(action)) { [weak self] in self?.activate(command) }
            if let state = g_action_get_state(mp_action(action)) {
                g_variant_unref(state)
                GTK.onActionStateChanged(UnsafeMutableRawPointer(action)) { [weak self] requested in
                    guard let self, let current = g_action_get_state(mp_action(action)) else { return }
                    defer { g_variant_unref(current) }
                    guard self.isEnabled(command), (g_variant_get_boolean(current) != 0) != requested else {
                        self.updateActions()
                        return
                    }
                    self.activate(command)
                }
            }
            g_action_map_add_action(mp_window_action_map(window), mp_action(action))
            g_object_unref(UnsafeMutableRawPointer(action))
            if let accelerator = command.accelerator {
                let strings = [strdup(accelerator), nil]
                defer { strings.forEach { free($0) } }
                strings.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: strings.count) {
                        gtk_application_set_accels_for_action(application, "win." + command.rawValue, $0)
                    }
                }
            }
        }
    }

    private func isEnabled(_ command: LinuxLibraryAction) -> Bool {
        guard commandsAvailable, let state = editor?.state else { return false }
        let editorAvailable = available && !conflictView.isResolving
        if [.edit, .favorite, .rename, .move, .duplicate, .showFiles, .delete].contains(command),
           let contextSelection, contextSelection != state.prompt { return false }
        switch command {
        case .newPrompt: return canCreatePrompt
        case .save: return editorAvailable && state.canSave
        case .duplicate: return editorAvailable && state.canSaveAsCopy
        case .revert: return editorAvailable && state.prompt != nil && state.status != .loading
            && state.status != .saving && state.status != .commandRunning
        case .rename, .move, .delete: return commands.canRun
        case .favorite: return browser.map { canFavorite($0.state) } ?? false
        case .review: return editorAvailable && assistantProvider() != nil && assistantPanel.canStart(.review)
        case .improve: return editorAvailable && assistantProvider() != nil && assistantPanel.canStart(.improve)
        case .importFiles, .importFolder: return importView?.canImport == true
        case .showFiles: return available && state.prompt != nil
        case .edit, .preview, .source: return state.prompt != nil
        default: return true
        }
    }

    private func updateActions() {
        guard !isDestroyed else { return }
        for (command, action) in actions { g_simple_action_set_enabled(action, isEnabled(command) ? 1 : 0) }
        gtk_widget_set_sensitive(searchToggle, isEnabled(.search) ? 1 : 0)
        for (command, selected) in [(LinuxLibraryAction.sidebar, gtk_widget_get_visible(sidebarPane) != 0),
                                     (.inspector, gtk_widget_get_visible(inspectorPane) != 0),
                                     (.favorite, browser?.state.selectedPrompt?.favorite == true),
                                     (.edit, mode == .edit), (.preview, mode == .preview),
                                     (.source, mode == .source)] {
            if let action = actions[command] { g_simple_action_set_state(action, g_variant_new_boolean(selected ? 1 : 0)) }
        }
    }

    @discardableResult
    private func activate(_ command: LinuxLibraryAction) -> Bool {
        guard isEnabled(command) else { return false }
        switch command {
        case .newPrompt: return requestNewPrompt()
        case .save: return savePrompt()
        case .duplicate: editor?.saveAsCopy()
        case .revert: editor?.revert()
        case .rename: commands.request(.rename)
        case .move: commands.request(.move)
        case .delete: commands.request(.delete)
        case .favorite: return toggleFavorite()
        case .edit: setMode(.edit); gtk_widget_grab_focus(visibleEditor)
        case .preview: setMode(.preview)
        case .source: setMode(.source); gtk_widget_grab_focus(source.widget)
        case .search:
            gtk_search_bar_set_search_mode(mp_search_bar(searchBar), 1)
            gtk_widget_grab_focus(filter)
            gtk_editable_select_region(OpaquePointer(filter), 0, -1)
        case .sidebar: gtk_widget_set_visible(sidebarPane, gtk_widget_get_visible(sidebarPane) == 0 ? 1 : 0)
        case .inspector: gtk_widget_set_visible(inspectorPane, gtk_widget_get_visible(inspectorPane) == 0 ? 1 : 0)
        case .fields: showInspector("fields")
        case .history: showInspector("history")
        case .assistant: showInspector("assistant")
        case .review, .improve:
            guard let editor, let model = assistantProvider() else { return false }
            assistantPanel.bind(model: model, editor: editor, available: available && !conflictView.isResolving)
            guard assistantPanel.canStart(command == .review ? .review : .improve) else { return false }
            showInspector("assistant")
            return assistantPanel.start(command == .review ? .review : .improve)
        case .importFiles: importView?.show(.files)
        case .importFolder: importView?.show(.folder)
        case .showFiles:
            if let path = editor?.state.prompt?.relativePath, let showFiles { showFiles(path) }
            else { openFolder() }
        case .settings: showSettings()
        case .about: showAbout(window)
        case .close: return requestClose()
        }
        updateActions()
        return true
    }

    deinit { unbind() }

    func rebind(browser: LibraryBrowserModel, editor: EditorModel, imports: LinuxLibraryImportState? = nil,
                assistant: @escaping () -> AssistantModel? = { nil },
                conflict: @escaping () -> ConflictModel? = { nil },
                syncStatus: SyncStatusModel? = nil,
                syncNavigation: @escaping (SyncStatusAction) -> Void = { _ in },
                createPrompt: @escaping (String, RelativePath) -> LibraryPromptSelection? = { _, _ in nil }) {
        guard !isDestroyed else { return }
        precondition((importView == nil) == (imports == nil),
                     "Import-enabled windows require the current graph's import state")
        unbind()
        self.browser = browser
        self.editor = editor
        self.imports = imports
        self.createPrompt = createPrompt
        syncStatusView.bind(syncStatus, navigate: { [weak self] action in
            guard let self, self.isVisible else { return }
            if action == .conflicts { self.showSyncConflicts() }
            else { syncNavigation(action) }
        }, openFile: { [weak self] path in self?.openSyncErrorFile(path) })
        if isVisible { syncStatusView.show() }
        assistantProvider = assistant
        conflictProvider = conflict
        conflictView.onChange = { [weak self] in self?.render() }
        conflictView.onResolve = { [weak self] action in self?.resolveConflict(action) }
        assistantMessage = nil
        renderedEditorStatus = nil
        let binding = bindingRevision
        assistantPanel.onOutcome = { [weak self, weak editor] outcome in
            guard let self, let editor, !self.isDestroyed, self.bindingRevision == binding,
                  self.editor === editor else { return }
            self.assistantMessage = LinuxAssistantStrings.outcome(outcome)
            self.assistantMessagePrompt = editor.state.prompt
            self.assistantMessageStamp = editor.state.stamp
            // The outcome can arrive before this busy state was rendered.
            self.renderedEditorStatus = editor.state.status
            self.render()
        }
        commands.bind(editor: editor, browser: browser)
        renderedSections = []
        renderedRowsSection = nil
        historyPrompt = nil
        historyReloadPending = false
        if let imports { importView?.bind(imports) }
        previousPrompt = nil
        copySelection = nil
        revealAfterOpen = []
        focusAfterOpen = nil
        closeRequested = false
        dismissedConflict = nil
        setMode(.edit)
        filterPreedit = false
        message = nil
        messageSelection = nil
        observer = browser.addObserver { [weak self, weak browser] _ in
            guard let self, let browser, self.browser === browser else { return }
            self.selectAdoptedCopy()
            if self.isVisible, !self.closeRequested, self.editor?.state.prompt == nil,
               let selection = browser.selection { self.selectPrompt(selection) }
            self.render()
            imports?.updateDestinations(browser.sections)
        }
        editorObserver = editor.addObserver { [weak self, weak editor] state in
            guard let self, let editor, self.editor === editor else { return }
            let previous = self.previousPrompt
            let adoptedCopy = state.prompt != previous && state.prompt == state.lastCopy
            let openingSession = state.status == .loading && state.source == nil && state.prompt != previous
            // A fresh open/copy retires undo, including another identity at the
            // same path. First-save identity assignment keeps the original undo.
            if previous?.relativePath != state.prompt?.relativePath || adoptedCopy || openingSession {
                self.sourceRevision &+= 1
            }
            self.previousPrompt = state.prompt
            if adoptedCopy, let prompt = state.prompt {
                self.copySelection = prompt
                self.browser?.setFilter("")
                self.browser?.selectSection(.all)
                self.selectAdoptedCopy()
            } else if self.isVisible, !self.closeRequested, state.prompt == nil,
                      let selection = self.browser?.selection, selection.relativePath != previous?.relativePath {
                self.selectPrompt(selection)
            }
            self.render()
            // A History request made while busy must retry even if its prompt stayed the same.
            if self.isHistorySelected, self.historyReloadPending { self.loadHistory() }
        }
        render()
        imports?.updateDestinations(browser.sections)
    }

    func show() {
        guard !isDestroyed else { return }
        syncStatusView.show()
        render()
        gtk_window_present(mp_window(window))
        if editor?.state.prompt == nil, let selection = browser?.selection { selectPrompt(selection) }
        updateDialog()
        gtk_widget_grab_focus(editor?.state.prompt == nil ? list : visibleEditor)
    }

    func hide() { requestClose() }

    func tearDown() {
        guard !isDestroyed else { return }
        unbind()
        gtk_widget_set_visible(window, 0)
    }

    private func unbind() {
        syncStatusView.retire(isDestroyed ? .destroyed : .rebind)
        assistantPanel.retire(destroyed: isDestroyed)
        conflictView.unbind(isDestroyed ? .destroyed : .rebind)
        conflictProvider = { nil }
        conflictModel = nil
        assistantProvider = { nil }
        createPrompt = { _, _ in nil }
        newPromptRequest = nil
        imports = nil
        endDialog()
        endFieldDialog()
        commands.unbind()
        importView?.unbind()
        bindingRevision &+= 1
        sourceRevision &+= 1
        if let observer { browser?.removeObserver(observer) }
        if let editorObserver { editor?.removeObserver(editorObserver) }
        observer = nil
        editorObserver = nil
        browser = nil
        editor = nil
    }

    /// Picker opens reveal hidden rows only after the draft guard approves.
    func openPrompt(_ selection: LibraryPromptSelection) {
        guard !isDestroyed, available else { return }
        setMode(.edit)
        if !revealAfterOpen.contains(selection) { revealAfterOpen.append(selection) }
        selectPrompt(selection)
    }

    func showSyncConflicts() {
        guard !isDestroyed, let browser else { return }
        browser.setFilter("")
        browser.selectSection(.conflicts)
    }

    private func openSyncErrorFile(_ path: RelativePath) {
        guard isVisible, let browser else { return }
        browser.setFilter("")
        browser.selectSection(.all)
        guard let row = browser.rows.first(where: { $0.relativePath == path }) else {
            message = LinuxStrings.promptFileUnavailable
            messageSelection = browser.selection
            render()
            return
        }
        openPrompt(row.selection)
    }

    func setLibraryAvailable(_ available: Bool) {
        let becameAvailable = available && !self.available
        self.available = available
        if !available { newPromptRequest = nil }
        if becameAvailable, !isDestroyed, isHistorySelected { loadHistory() }
        render()
    }

    private var canCreatePrompt: Bool {
        guard commandsAvailable, available, !closeRequested, !conflictView.isResolving,
              newPromptRequest == nil, activeDialog == nil, !commands.hasDialog,
              !commands.isScopeDropPending, imports?.isChoosing != true,
              let state = editor?.state else { return false }
        return state.pendingDecision == nil && state.conflict == nil && state.queuedActions.isEmpty
            && state.status != .loading && state.status != .saving && state.status != .commandRunning
    }

    @discardableResult
    private func requestNewPrompt() -> Bool {
        guard canCreatePrompt, let folder = browser?.newPromptDestination() else { return false }
        message = nil
        newPromptRequest = LinuxNewPromptRequest(folder: folder)
        render()
        return true
    }

    private func resolveNewPrompt(_ response: LinuxEditorResponse, request: LinuxNewPromptRequest) {
        guard newPromptRequest == request else { return }
        newPromptRequest = nil
        render()
        guard case .createPrompt(let input) = response, canCreatePrompt, let editor else { return }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LinuxStrings.newPromptDefaultTitle : input
        let revision = bindingRevision
        editor.request(.create) { [weak self] result in
            // A close, open or hide during the guard's save supersedes creation.
            guard let self, self.bindingRevision == revision, result == .allowed,
                  self.canCreatePrompt else { return }
            guard let selection = self.createPrompt(title, request.folder) else {
                // Publish after queued editor state, like a command completion.
                GTK.onMainLoop { [weak self] in
                    guard let self, !self.isDestroyed, self.bindingRevision == revision else { return }
                    self.message = LinuxStrings.createPromptFailed
                    self.messageSelection = self.browser?.selection
                    self.render()
                }
                return
            }
            self.setMode(.edit)
            self.browser?.setFilter("")
            if self.browser?.selectedSection != .all,
               self.browser.flatMap({ $0.moveDestination(for: $0.selectedSection) }) != request.folder {
                self.browser?.selectSection(.all)
            }
            self.selectPrompt(selection, context: .creation)
            // The form's availability is known only once the prompt loads.
            self.focusAfterOpen = selection
        }
    }

    private func selectPrompt(_ selection: LibraryPromptSelection, context: OpenContext = .library) {
        guard !isDestroyed, let editor else { return }
        guard !conflictView.isResolving else { render(); return }
        let action = EditorDiscardAction.open(selection)
        guard editor.state.pendingDecision?.action != action, !editor.state.queuedActions.contains(action) else { return }
        let revision = bindingRevision
        editor.request(action) { [weak self] result in
            guard let self, !self.isDestroyed, self.bindingRevision == revision else { return }
            let reveal = self.revealAfterOpen.contains(selection)
            self.revealAfterOpen.removeAll { $0 == selection }
            if result == .allowed {
                if reveal { self.browser?.setFilter(""); self.browser?.selectSection(.all) }
                // The index may not have published this newly committed row yet.
                self.copySelection = context == .creation ? selection : nil
                self.browser?.selectPrompt(self.editor?.state.prompt)
                self.selectAdoptedCopy()
                if reveal { self.focusAfterOpen = selection }
            }
            self.render() // Cancel restores the native row to Core's selection.
        }
    }

    private func selectAdoptedCopy() {
        guard let copy = copySelection, let browser, browser.rows.contains(where: { $0.selection == copy }) else { return }
        copySelection = nil
        browser.selectPrompt(copy)
    }

    @discardableResult
    private func requestClose() -> Bool {
        guard !isDestroyed, !closeRequested, let editor else { return false }
        guard !hasModalChild(named: "monkeyspaw-about") else { return false }
        assistantPanel.close()
        conflictView.close()
        closeRequested = true
        let revision = bindingRevision
        editor.request(.close) { [weak self] result in
            guard let self, !self.isDestroyed, self.bindingRevision == revision else { return }
            self.closeRequested = false
            if result == .allowed {
                self.endDialog()
                self.importView?.cancelChoosing()
                self.sourceRevision &+= 1
                self.render()
                gtk_widget_set_visible(self.window, 0)
            }
        }
        return true
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
        renderEditor()
        let favoriteTitle = state.selectedPrompt?.favorite == true
            ? LinuxStrings.removeFavorite : LinuxStrings.addFavorite
        gtk_button_set_icon_name(mp_button(favorite), state.selectedPrompt?.favorite == true
            ? "starred-symbolic" : "non-starred-symbolic")
        gtk_widget_set_tooltip_text(favorite, favoriteTitle)
        let isFavorite = state.selectedPrompt?.favorite == true
        if contextFavorite != isFavorite, let model = contextModel {
            contextFavorite = isFavorite
            g_menu_remove(model, 1)
            g_menu_insert(model, 1, favoriteTitle, "win.favorite")
        }
        if let prompt = editor?.state.prompt {
            let row = state.selectedPrompt.flatMap { $0.selection == prompt ? $0 : nil }
                ?? state.rows.first { $0.selection == prompt }
            gtk_label_set_text(mp_label(title), row?.title ?? prompt.relativePath.string)
            gtk_label_set_text(mp_label(subtitle), LinuxLibraryStrings.subtitle(path: prompt.relativePath.string,
                dirty: editor?.state.isDirty == true))
        } else {
            let section = state.sections.first { $0.id == state.selectedSection }
            gtk_label_set_text(mp_label(title), section?.title ?? LinuxStrings.library)
            gtk_label_set_text(mp_label(subtitle), LinuxLibraryStrings.count(section?.count ?? 0))
        }
        mp_accessible_label(favorite, favoriteTitle)
        gtk_widget_set_sensitive(favorite, canFavorite(state) ? 1 : 0)
        gtk_label_set_text(mp_label(status), message ?? "")
        gtk_widget_set_visible(status, message == nil ? 0 : 1)
        updateDialog()
        updateActions()
    }

    /// Edit is a structured form over the same draft: native entries for
    /// title and description, removable chips for tags, the private toggle
    /// and the shared native text view for the body. Views never parse or
    /// serialize; every change goes through EditorModel.edit.
    private func configureForm() {
        gtk_widget_set_name(formBox, "library-form")
        gtk_widget_set_vexpand(formBox, 1)
        for edge in [gtk_widget_set_margin_start, gtk_widget_set_margin_end,
                     gtk_widget_set_margin_top, gtk_widget_set_margin_bottom] { edge(formBox, 12) }
        for (label, entry, name) in [(LinuxStrings.promptTitle, titleEntry, "library-form-title"),
                                     (LinuxEditorStrings.description, descriptionEntry,
                                      "library-form-description")] {
            let heading = GTK.label(label)
            gtk_widget_add_css_class(heading, "heading")
            gtk_label_set_xalign(mp_label(heading), 0)
            gtk_box_append(mp_box(formBox), heading)
            gtk_widget_set_name(entry, name)
            mp_accessible_label(entry, label)
            gtk_widget_set_hexpand(entry, 1)
            GTK.onSignal(entry, "changed") { [weak self] in
                guard let self, !self.isUpdatingForm else { return }
                let text = String(cString: mp_entry_text(entry))
                if entry == self.titleEntry { self.formEdit(.title(text)) }
                else { self.formEdit(.description(text)) }
            }
            gtk_box_append(mp_box(formBox), entry)
        }
        let tagsHeading = GTK.label(LinuxLibraryStrings.tags)
        gtk_widget_add_css_class(tagsHeading, "heading")
        gtk_label_set_xalign(mp_label(tagsHeading), 0)
        gtk_box_append(mp_box(formBox), tagsHeading)
        gtk_widget_set_name(tagsFlow, "library-form-tags")
        gtk_flow_box_set_selection_mode(flowBox(), GTK_SELECTION_NONE)
        gtk_flow_box_set_column_spacing(flowBox(), 6)
        gtk_flow_box_set_row_spacing(flowBox(), 6)
        gtk_widget_set_hexpand(tagsFlow, 1)
        gtk_box_append(mp_box(formBox), tagsFlow)
        let addRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_name(tagEntry, "library-form-tag-entry")
        gtk_entry_set_placeholder_text(mp_entry(tagEntry), LinuxEditorStrings.newTag)
        mp_accessible_label(tagEntry, LinuxEditorStrings.newTag)
        gtk_widget_set_hexpand(tagEntry, 1)
        GTK.onSignal(tagEntry, "activate") { [weak self] in self?.addTagFromEntry() }
        gtk_widget_set_name(tagAdd, "library-form-tag-add")
        GTK.onSignal(tagAdd, "clicked") { [weak self] in self?.addTagFromEntry() }
        gtk_box_append(mp_box(addRow), tagEntry)
        gtk_box_append(mp_box(addRow), tagAdd)
        gtk_box_append(mp_box(formBox), addRow)
        let privateRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_widget_set_name(privateToggle, "library-form-private")
        GTK.onSignal(privateToggle, "toggled") { [weak self] in
            guard let self, !self.isUpdatingForm else { return }
            self.formEdit(.isPrivate(gtk_check_button_get_active(mp_check_button(self.privateToggle)) != 0))
        }
        gtk_widget_set_name(privateHint, "library-form-private-hint")
        gtk_widget_add_css_class(privateHint, "caption")
        gtk_label_set_xalign(mp_label(privateHint), 0)
        gtk_widget_set_valign(privateHint, GTK_ALIGN_CENTER)
        gtk_label_set_wrap(mp_label(privateHint), 1)
        gtk_box_append(mp_box(privateRow), privateToggle)
        gtk_box_append(mp_box(privateRow), privateHint)
        gtk_box_append(mp_box(formBox), privateRow)
        let fieldsHeading = GTK.label(LinuxEditorStrings.placeholders)
        gtk_widget_add_css_class(fieldsHeading, "heading")
        gtk_label_set_xalign(mp_label(fieldsHeading), 0)
        gtk_box_append(mp_box(fieldsSection), fieldsHeading)
        gtk_widget_set_name(fieldsRows, "library-form-fields")
        mp_accessible_label(fieldsRows, LinuxEditorStrings.placeholders)
        gtk_list_box_set_selection_mode(mp_list_box(fieldsRows), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(fieldsRows, "boxed-list")
        gtk_box_append(mp_box(fieldsSection), fieldsRows)
        gtk_widget_set_name(fieldsSection, "library-form-fields-section")
        gtk_box_append(mp_box(formBox), fieldsSection)
        let bodyHeading = GTK.label(LinuxEditorStrings.promptBody)
        gtk_widget_add_css_class(bodyHeading, "heading")
        gtk_label_set_xalign(mp_label(bodyHeading), 0)
        gtk_box_append(mp_box(formBox), bodyHeading)
        gtk_box_append(mp_box(formBox), scrolled(body.widget, width: 200))
    }

    /// GtkFlowBox is opaque to Swift; the pointer is the same widget.
    private func flowBox() -> OpaquePointer { OpaquePointer(tagsFlow) }

    /// Structured edits join the same draft as source edits: one shared
    /// history, save and guard path, with assistant context revoked.
    private func formEdit(_ change: PromptEdit) {
        guard available, !conflictView.isResolving else { return }
        assistantMessage = nil
        editor?.edit(change)
        assistantProvider()?.contextChanged()
    }

    private func addTagFromEntry() {
        guard !isUpdatingForm, let tags = editor?.state.form?.tags else { return }
        let tag = String(cString: mp_entry_text(tagEntry)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        formEdit(.tags(tags + [tag]))
        mp_entry_set_text(tagEntry, "")
    }

    private func removeTag(_ tag: String, at index: Int) {
        guard var tags = editor?.state.form?.tags, tags.indices.contains(index),
              tags[index].utf8.elementsEqual(tag.utf8) else { return }
        tags.remove(at: index)
        formEdit(.tags(tags))
    }

    private func setFormEntry(_ entry: GTK.Widget, _ text: String) {
        if !String(cString: mp_entry_text(entry)).utf8.elementsEqual(text.utf8) {
            mp_entry_set_text(entry, text)
        }
    }

    /// Chips map one-to-one to the tag array; values are never split.
    private func updateTags(_ tags: [String], editable: Bool) {
        let unchanged = renderedTags.count == tags.count
            && zip(renderedTags, tags).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        guard renderedTagsRevision != sourceRevision || !unchanged else { return }
        renderedTags = tags
        renderedTagsRevision = sourceRevision
        let revision = sourceRevision
        while let child = gtk_widget_get_first_child(tagsFlow) { gtk_flow_box_remove(flowBox(), child) }
        for (index, tag) in tags.enumerated() {
            let chip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
            gtk_widget_set_name(chip, "library-tag-chip")
            gtk_widget_add_css_class(chip, "mp-tag-chip")
            gtk_box_append(mp_box(chip), GTK.label(tag))
            let remove = gtk_button_new_from_icon_name("window-close-symbolic")!
            gtk_widget_set_name(remove, "library-tag-remove")
            gtk_widget_add_css_class(remove, "flat")
            gtk_widget_add_css_class(remove, "circular")
            let removeLabel = LinuxEditorStrings.removeTag(tag)
            mp_accessible_label(remove, removeLabel)
            gtk_widget_set_tooltip_text(remove, removeLabel)
            gtk_widget_set_sensitive(remove, editable ? 1 : 0)
            GTK.onSignal(remove, "clicked") { [weak self] in
                guard let self, self.sourceRevision == revision else { return }
                self.removeTag(tag, at: index)
            }
            gtk_box_append(mp_box(chip), remove)
            gtk_flow_box_insert(flowBox(), chip, -1)
        }
    }

    /// Programmatic control refreshes must not feed back into Core edits.
    /// Controls update in place so the focused entry keeps its composition.
    private func updateForm(_ state: EditorState, editable: Bool) {
        let form = state.form
        let sensitive = editable && form != nil
        isUpdatingForm = true
        defer { isUpdatingForm = false }
        if renderedFormRevision != sourceRevision {
            // Retire composition before these persistent controls adopt another
            // prompt. Reset callbacks cannot become edits to the new session.
            for entry in [titleEntry, descriptionEntry, tagEntry] {
                gtk_entry_reset_im_context(mp_entry(entry))
            }
            formPreedit = false
            mp_entry_set_text(tagEntry, "")
            renderedFormRevision = sourceRevision
        }
        // An entry with an active composition owns its text until commit.
        if !(formPreedit && containsFocus(titleEntry)) { setFormEntry(titleEntry, form?.title ?? "") }
        if !(formPreedit && containsFocus(descriptionEntry)) { setFormEntry(descriptionEntry, form?.description ?? "") }
        updateTags(form?.tags ?? [], editable: sensitive)
        let active: Int32 = form?.isPrivate == true ? 1 : 0
        if gtk_check_button_get_active(mp_check_button(privateToggle)) != active {
            gtk_check_button_set_active(mp_check_button(privateToggle), active)
        }
        for control in [titleEntry, descriptionEntry, tagEntry, tagAdd, privateToggle] {
            gtk_widget_set_sensitive(control, sensitive ? 1 : 0)
        }
        for index in 0..<(form?.tags.count ?? 0) {
            guard let child = gtk_flow_box_get_child_at_index(flowBox(), Int32(index)),
                  let chip = gtk_flow_box_child_get_child(child),
                  let remove = gtk_widget_get_last_child(chip) else { continue }
            gtk_widget_set_sensitive(remove, sensitive ? 1 : 0)
        }
        updateFieldRows(form?.fieldSettings ?? [], editable: sensitive, state: state)
    }

    /// Placeholder rows mirror the form's field projection. A staged dialog
    /// stays open only while its prompt, field and editability still hold;
    /// any lapse retires it so a stale Apply can never reach another draft.
    private func updateFieldRows(_ settings: [PromptFieldSettings], editable: Bool, state: EditorState) {
        if fieldDialog != nil,
           !editable || state.prompt != fieldDialogPrompt || state.pendingDecision != nil
                || state.source.map({ Data($0.utf8) }) != fieldDialogSource.map({ Data($0.utf8) })
               || state.conflict != nil || !settings.contains(where: { $0.name == fieldDialogName }) {
            endFieldDialog()
        }
        gtk_widget_set_visible(fieldsSection, settings.isEmpty ? 0 : 1)
        if renderedFieldSettings != settings || renderedFieldSettingsRevision != sourceRevision {
            renderedFieldSettings = settings
            renderedFieldSettingsRevision = sourceRevision
            fieldButtons = []
            clear(fieldsRows)
            let revision = sourceRevision
            for field in settings {
                let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                             gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(row, 8) }
                let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3)!
                gtk_widget_set_hexpand(text, 1)
                let name = GTK.label(field.name)
                gtk_widget_add_css_class(name, "monospace")
                gtk_box_append(mp_box(text), name)
                let summary = GTK.label(LinuxEditorStrings.fieldSummary(field))
                gtk_widget_add_css_class(summary, "dim-label")
                gtk_label_set_wrap(mp_label(summary), 0)
                gtk_label_set_ellipsize(mp_label(summary), PANGO_ELLIPSIZE_END)
                gtk_box_append(mp_box(text), summary)
                mp_accessible_label(text, field.name + ", " + LinuxEditorStrings.fieldSummary(field))
                gtk_box_append(mp_box(row), text)
                let button = gtk_button_new_with_label(LinuxEditorStrings.fieldSettings)!
                gtk_widget_set_name(button, "library-form-field-settings")
                let accessible = LinuxEditorStrings.fieldSettingsLabel(field.name)
                mp_accessible_label(button, accessible)
                gtk_widget_set_tooltip_text(button, accessible)
                gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
                GTK.onSignal(button, "clicked") { [weak self] in
                    guard let self, self.sourceRevision == revision else { return }
                    self.openFieldSettings(named: field.name)
                }
                fieldButtons.append(button)
                gtk_box_append(mp_box(row), button)
                gtk_list_box_append(mp_list_box(fieldsRows), row)
            }
        }
        for button in fieldButtons { gtk_widget_set_sensitive(button, editable ? 1 : 0) }
    }

    private func openFieldSettings(named name: String) {
        guard isVisible, available, !conflictView.isResolving, fieldDialog == nil,
              activeDialog == nil, !hasModalChild(),
              let state = editor?.state, state.canEdit,
              state.pendingDecision == nil, state.conflict == nil,
              let staged = state.form?.fieldSettings.first(where: { $0.name == name }) else { return }
        let prompt = state.prompt
        let source = state.source.map { Data($0.utf8) }
        let revision = sourceRevision
        fieldDialogRevision &+= 1
        let dialogID = fieldDialogRevision
        fieldDialogName = name
        fieldDialogPrompt = prompt
        fieldDialogSource = state.source
        fieldDialog = LinuxFieldSettingsDialog(parent: window, settings: staged) { [weak self] response in
            guard let self, !self.isDestroyed, self.fieldDialogRevision == dialogID else { return }
            self.endFieldDialog()
            self.updateActions()
            guard let response else { return }
            // A stale Apply must never reach another prompt or a republished draft.
            guard self.sourceRevision == revision, self.available, !self.conflictView.isResolving,
                  let state = self.editor?.state, state.prompt == prompt, state.canEdit,
                  state.source.map({ Data($0.utf8) }) == source,
                  state.pendingDecision == nil, state.conflict == nil,
                  let current = state.form?.fieldSettings.first(where: { $0.name == response.name }),
                  current == staged else { return }
            self.formEdit(.field(response))
        }
        updateActions()
    }

    private func endFieldDialog() {
        fieldDialogRevision &+= 1
        fieldDialogName = nil
        fieldDialogPrompt = nil
        fieldDialogSource = nil
        fieldDialog?.destroy()
        fieldDialog = nil
    }

    private func configureEditor(in detail: GTK.Widget) {
        gtk_widget_set_name(readOnly, "library-read-only")
        gtk_info_bar_set_message_type(mp_info_bar(readOnlyBar), GTK_MESSAGE_INFO)
        gtk_info_bar_add_child(mp_info_bar(readOnlyBar), readOnly)
        gtk_box_append(mp_box(detail), readOnlyBar)
        gtk_box_append(mp_box(detail), conflictView.widget)
        configureForm()
        let editPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        let overlay = gtk_overlay_new()!
        // A scroll boundary contains height-for-width metadata such as tag
        // chips, keeping GtkPaned measurements stable and short windows usable.
        let formScroll = scrolled(formBox, width: 200)
        gtk_widget_set_name(formScroll, "library-form-scroll")
        gtk_scrolled_window_set_policy(mp_scrolled_window(formScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_overlay_set_child(mp_overlay(overlay), formScroll)
        gtk_widget_set_halign(editorEmpty, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(editorEmpty, GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(editorEmpty, "dim-label")
        gtk_overlay_add_overlay(mp_overlay(overlay), editorEmpty)
        gtk_box_append(mp_box(editPage), overlay)
        let sourcePage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_name(fallbackBar, "library-form-fallback")
        gtk_info_bar_set_message_type(mp_info_bar(fallbackBar), GTK_MESSAGE_WARNING)
        gtk_info_bar_add_child(mp_info_bar(fallbackBar), fallback)
        gtk_widget_set_visible(fallbackBar, 0)
        gtk_box_append(mp_box(sourcePage), fallbackBar)
        gtk_box_append(mp_box(sourcePage), scrolled(source.widget, width: 200))
        gtk_widget_set_name(validation, "library-validation")
        gtk_label_set_selectable(mp_label(validation), 1)
        let issuesScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_max_content_height(mp_scrolled_window(issuesScroll), 120)
        gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(issuesScroll), 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(issuesScroll), validation)
        gtk_revealer_set_child(mp_revealer(issuesRevealer), issuesScroll)
        gtk_widget_set_name(preview, "library-preview")
        mp_accessible_label(preview, LinuxStrings.preview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(preview), GTK_WRAP_WORD_CHAR)
        gtk_widget_set_name(editorStack, "library-editor-stack")
        gtk_stack_add_named(mp_stack(editorStack), editPage, "edit")
        gtk_stack_add_named(mp_stack(editorStack), scrolled(preview, width: 200), "preview")
        gtk_stack_add_named(mp_stack(editorStack), sourcePage, "source")
        gtk_widget_set_vexpand(editorStack, 1)
        gtk_stack_set_hhomogeneous(mp_stack(editorStack), 0)
        gtk_stack_set_vhomogeneous(mp_stack(editorStack), 0)
        gtk_box_append(mp_box(detail), editorStack)
        gtk_box_append(mp_box(detail), issuesRevealer)
        gtk_box_append(mp_box(detail), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_widget_add_css_class(bar, "toolbar")
        gtk_widget_set_name(validationSummary, "library-validation-summary")
        gtk_widget_add_css_class(validationSummary, "flat")
        GTK.onSignal(validationSummary, "clicked") { [weak self] in
            guard let self else { return }
            self.setMode(.edit)
            gtk_revealer_set_reveal_child(mp_revealer(self.issuesRevealer),
                gtk_revealer_get_reveal_child(mp_revealer(self.issuesRevealer)) == 0 ? 1 : 0)
        }
        gtk_box_append(mp_box(bar), validationSummary)
        gtk_widget_set_name(editorStatus, "library-editor-status")
        gtk_widget_set_hexpand(editorStatus, 1)
        gtk_widget_add_css_class(editorStatus, "dim-label")
        gtk_box_append(mp_box(bar), editorStatus)
        gtk_box_append(mp_box(detail), bar)
        assistantPanel.onHighlight = { [weak self] range in
            guard let self, !self.isDestroyed else { return }
            // Quote ranges are byte offsets into the complete source file.
            if range != nil { self.setMode(.source) }
            self.source.highlight(range)
        }
        assistantPanel.onAvailabilityChange = { [weak self] in self?.updateActions() }
        source.onEdit = { [weak self] text in
            guard let self, !self.isDestroyed, self.available, !self.conflictView.isResolving else { return }
            self.assistantMessage = nil
            self.editor?.edit(text)
            // Revoke acceptance at each native edit before another event can run.
            self.assistantProvider()?.contextChanged()
        }
        body.onEdit = { [weak self] text in
            guard let self, !self.isDestroyed else { return }
            self.formEdit(.body(text))
        }
        source.onCompositionEnded = { [weak self] in self?.render() }
        source.onCompositionChanged = { [weak self] in self?.updateActions() }
        body.onCompositionEnded = { [weak self] in self?.render() }
        body.onCompositionChanged = { [weak self] in self?.updateActions() }
        for entry in [titleEntry, descriptionEntry, tagEntry] {
            if let text = mp_entry_text_delegate(entry) {
                GTK.onPreeditChanged(text) { [weak self] active in
                    self?.formPreedit = active
                    self?.updateActions()
                }
            }
        }
    }

    private func configureInspector() {
        gtk_widget_set_name(inspectorPane, "library-inspector")
        let switcher = gtk_stack_switcher_new()!
        gtk_widget_add_css_class(switcher, "mp-inspector-switcher")
        gtk_stack_switcher_set_stack(mp_stack_switcher(switcher), mp_stack(inspectorStack))
        gtk_widget_set_halign(switcher, GTK_ALIGN_FILL)
        gtk_box_append(mp_box(inspectorPane), switcher)
        gtk_widget_set_name(inspectorStack, "library-inspector-stack")
        gtk_stack_set_hhomogeneous(mp_stack(inspectorStack), 0)
        gtk_stack_set_vhomogeneous(mp_stack(inspectorStack), 0)
        gtk_widget_set_name(fields, "library-fields")
        mp_accessible_label(fields, LinuxEditorStrings.parsedFields)
        gtk_list_box_set_selection_mode(mp_list_box(fields), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(fields, "boxed-list")
        let fieldsScroll = scrolled(fields, width: 240)
        gtk_scrolled_window_set_policy(mp_scrolled_window(fieldsScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        for edge in [gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(fields, 12) }
        gtk_stack_add_titled(mp_stack(inspectorStack), fieldsScroll, "fields", LinuxEditorStrings.fields)
        gtk_stack_add_titled(mp_stack(inspectorStack), history.widget, "history", LinuxEditorStrings.history)
        let assistantPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(mp_box(assistantPage), assistantPanel.widget)
        gtk_stack_add_titled(mp_stack(inspectorStack), assistantPage, "assistant", LinuxAssistantStrings.title)
        gtk_widget_set_vexpand(inspectorStack, 1)
        // A scroll boundary keeps GTK 4.8's Paned measurements stable while
        // Assistant status and comparison content change their natural height.
        let scroll = scrolled(inspectorStack, width: 240)
        gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_box_append(mp_box(inspectorPane), scroll)
        GTK.onNotify(UnsafeMutableRawPointer(inspectorStack), "visible-child") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isHistorySelected { self.loadHistory() }
            if self.inspectorPage == "assistant" { self.assistantPanel.show() }
        }
        GTK.onNotify(UnsafeMutableRawPointer(inspectorPane), "visible") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isHistorySelected { self.loadHistory() }
            self.updateActions()
        }
        history.onLoad = { [weak self] in self?.loadHistory() }
        history.onSelect = { [weak self] revision in self?.editor?.selectRevision(revision) }
        history.onRestore = { [weak self] revision in self?.commands.restore(revision) }
    }

    private func renderEditor() {
        guard let editor else { return }
        let state = editor.state
        let busy = state.status == .loading || state.status == .saving || state.status == .commandRunning
        let row = browser?.state.selectedPrompt
        let conflictSelection = row?.conflictOrigin != nil && row?.selection == state.prompt && state.stamp != nil
            && isVisible ? state.prompt : nil
        if conflictSelection != nil { conflictModel = conflictProvider() }
        conflictView.bind(model: conflictModel, selection: conflictSelection, stamp: state.stamp,
            available: available && !busy && state.pendingDecision == nil && state.queuedActions.isEmpty)
        let editorAvailable = available && !conflictView.isResolving
        gtk_widget_set_visible(editorEmpty, state.prompt == nil ? 1 : 0)
        assistantPanel.bind(model: assistantProvider(), editor: editor, available: editorAvailable)
        applyEditorMode()
        updateForm(state, editable: editorAvailable && state.canEdit)
        source.update(state, revision: sourceRevision, available: editorAvailable)
        body.update(state, revision: sourceRevision, available: editorAvailable)
        gtk_label_set_text(mp_label(readOnly), state.readOnlyReason.map(LinuxEditorStrings.readOnly) ?? "")
        gtk_widget_set_visible(readOnly, state.readOnlyReason == nil ? 0 : 1)
        gtk_widget_set_visible(readOnlyBar, state.readOnlyReason == nil ? 0 : 1)
        gtk_label_set_text(mp_label(validation), state.issues.map(LinuxEditorStrings.issue).joined(separator: "\n"))
        let text = state.prompt == nil ? LinuxStrings.selectLibraryPrompt
            : state.previewOutputFailure?.description
                ?? (state.previewFailure == nil ? state.preview : state.issues.map(\.message).joined(separator: "\n"))
        if renderedPreview.map({ $0.utf8.elementsEqual(text.utf8) }) != true {
            renderedPreview = text
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), text, Int32(text.utf8.count))
        }
        if renderedFields != state.fields {
            clear(fields)
            renderedFields = state.fields
            if state.fields.isEmpty { gtk_list_box_append(mp_list_box(fields), GTK.label(LinuxEditorStrings.noFields)) }
            for field in state.fields {
                let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
                for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                             gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(row, 10) }
                let name = GTK.label(field.name)
                gtk_widget_add_css_class(name, "monospace")
                gtk_box_append(mp_box(row), name)
                let description = GTK.label(LinuxLibraryStrings.field(field))
                gtk_label_set_selectable(mp_label(description), 1)
                gtk_widget_add_css_class(description, "dim-label")
                gtk_box_append(mp_box(row), description)
                gtk_list_box_append(mp_list_box(fields), row)
            }
        }
        let summary = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_box_append(mp_box(summary), gtk_image_new_from_icon_name(state.issues.isEmpty
            ? "emblem-ok-symbolic" : "dialog-warning-symbolic"))
        gtk_box_append(mp_box(summary), GTK.label(LinuxLibraryStrings.issues(state.issues.count)))
        gtk_button_set_child(mp_button(validationSummary), summary)
        mp_accessible_label(validationSummary, LinuxLibraryStrings.issues(state.issues.count))
        commands.update(state, available: editorAvailable)
        history.update(state, available: editorAvailable, canRestore: commands.canRun && !commands.hasDialog)
        if assistantMessagePrompt != state.prompt || assistantMessageStamp != state.stamp
            || (busy && renderedEditorStatus != state.status) { assistantMessage = nil }
        renderedEditorStatus = state.status
        var status = assistantMessage ?? commands.message ?? LinuxEditorStrings.status(state)
        if assistantMessage != nil, state.isDirty { status += LinuxLibraryStrings.newerEdits }
        if assistantMessage == nil, commands.message == nil, state.provenanceMaintenanceFailed {
            status += (status.isEmpty ? "" : " ") + LinuxEditorStrings.provenanceWarning
        }
        gtk_label_set_text(mp_label(editorStatus), status)
        // Focus waits for the loaded document: which native editor is visible
        // depends on whether its front matter parsed.
        if let pending = focusAfterOpen {
            if state.prompt == pending && state.source != nil && state.status != .loading {
                focusAfterOpen = nil
                gtk_widget_grab_focus(visibleEditor)
            } else if state.prompt != pending && state.status != .loading {
                focusAfterOpen = nil
            }
        }
        if state.prompt == nil { historyPrompt = nil }
        if isHistorySelected, state.prompt != historyPrompt { loadHistory() }
    }

    private var isHistorySelected: Bool {
        gtk_widget_get_visible(inspectorPane) != 0 && inspectorPage == "history"
    }

    private func loadHistory() {
        guard !isDestroyed, available, let editor, let prompt = editor.state.prompt,
              editor.state.stamp != nil else { return }
        guard editor.state.status != .loading, editor.state.status != .saving,
              editor.state.status != .commandRunning else {
            historyReloadPending = true
            return
        }
        historyReloadPending = false
        historyPrompt = prompt
        editor.loadHistory()
    }

    @discardableResult
    private func savePrompt() -> Bool {
        guard isVisible, available, !conflictView.isResolving, let editor, editor.state.canSave else { return false }
        if editor.state.conflict != nil {
            dismissedConflict = nil
            updateDialog()
        } else { editor.save() }
        return true
    }

    private func resolveConflict(_ action: ConflictResolutionAction) {
        guard isVisible, available, let editor, let model = conflictModel, !model.state.isBusy,
              let preview = model.state.preview, preview.copy == editor.state.prompt,
              preview.copy == browser?.selection else { return }
        if editor.state.isDirty || editor.state.conflict != nil {
            guard editor.state.pendingDecision?.action != .revert,
                  !editor.state.queuedActions.contains(.revert) else { return }
            let revision = bindingRevision
            editor.request(.revert) { [weak self, weak model] result in
                guard let self, let model, !self.isDestroyed, self.isVisible,
                      self.bindingRevision == revision, self.conflictModel === model,
                      result == .allowed, self.browser?.selection == preview.copy else { return }
                // A save can change the candidate. Never apply the earlier
                // button press to bytes the user has not compared yet.
                self.conflictView.refreshComparison(.afterEditing)
            }
        } else { conflictView.resolve(action) }
    }

    private func updateDialog() {
        guard let editor else { return }
        let state = editor.state
        let awaitingConflict = state.conflict.map {
            $0.kind == .modified && $0.theirsSource == nil && $0.readOnlyReason == nil && $0.failure == nil
        } ?? false
        let awaitingReply = state.status == .saving || state.status == .loading || state.status == .commandRunning
            || state.conflict?.isLoading == true || awaitingConflict
        if state.conflict == nil || awaitingReply { dismissedConflict = nil }
        guard isVisible else { return }
        let desired: LinuxEditorDialogState?
        if awaitingReply { desired = nil }
        else if let conflict = state.conflict, conflict != dismissedConflict { desired = .conflict(conflict, status: state.status) }
        else if let decision = state.pendingDecision { desired = .decision(decision, status: state.status) }
        else if let request = newPromptRequest { desired = .newPrompt(request) }
        else { desired = nil }
        guard desired != activeDialog else { return }
        endDialog()
        guard let desired else { return }
        activeDialog = desired
        let revision = dialogRevision
        dialog = LinuxEditorDialog(parent: window, state: desired) { [weak self] response in
            guard let self, !self.isDestroyed, self.dialogRevision == revision,
                  self.activeDialog == desired else { return }
            // Cancelling a conflict can leave Core unchanged. Refresh the
            // modal action gate even when no model publication follows.
            defer { self.updateActions() }
            self.endDialog()
            switch (desired, response) {
            case (.decision(let decision, _), .decision(let choice)):
                self.editor?.resolveDecision(choice, id: decision.id)
            case (.conflict, .conflict(let choice)): self.editor?.resolveConflict(choice)
            case (.conflict(let conflict, _), .dismissConflict):
                self.dismissedConflict = conflict
                if let decision = self.editor?.state.pendingDecision {
                    self.editor?.resolveDecision(.cancel, id: decision.id)
                }
            case (.newPrompt(let request), _): self.resolveNewPrompt(response, request: request)
            default: break
            }
        }
    }

    private func endDialog() {
        dialogRevision &+= 1
        activeDialog = nil
        dialog?.destroy()
        dialog = nil
    }

    private func renderSections(_ state: LibraryBrowserState) {
        if renderedSections != state.sections {
            let hadFocus = containsFocus(sidebar)
            clear(sidebar)
            renderedSections = state.sections
            for section in state.sections {
                let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                gtk_widget_set_margin_start(row, Int32(section.depth * 12))
                for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom] { edge(row, 6) }
                let icon: String
                switch section.id {
                case .all: icon = "view-list-symbolic"
                case .favourites: icon = "starred-symbolic"
                case .recent: icon = "document-open-recent-symbolic"
                case .conflicts: icon = "dialog-warning-symbolic"
                case .folder: icon = "folder-symbolic"
                case .group: icon = "system-users-symbolic"
                case .tag: icon = "bookmark-new-symbolic"
                }
                gtk_box_append(mp_box(row), gtk_image_new_from_icon_name(icon))
                let title = rowLabel(section.title)
                gtk_widget_set_hexpand(title, 1)
                gtk_box_append(mp_box(row), title)
                let count = GTK.label(String(section.count))
                gtk_widget_add_css_class(count, "dim-label")
                gtk_label_set_xalign(mp_label(count), 1)
                gtk_box_append(mp_box(row), count)
                let accessibleTitle: String
                if case .folder(let path) = section.id { accessibleTitle = path.string }
                else { accessibleTitle = section.title }
                mp_accessible_label(row, accessibleTitle + ", " + LinuxLibraryStrings.count(section.count))
                if browser?.moveDestination(for: section.id) != nil { commands.installDrop(on: row, section: section.id) }
                gtk_list_box_append(mp_list_box(sidebar), row)
            }
            select(in: sidebar, position: state.sections.firstIndex { $0.id == state.selectedSection }, focus: hadFocus)
        } else if renderedSection != state.selectedSection {
            select(in: sidebar, position: state.sections.firstIndex { $0.id == state.selectedSection })
        }
        renderedSection = state.selectedSection
    }

    private func renderRows(_ state: LibraryBrowserState) {
        let hadFocus = containsFocus(list)
        if renderedRowsSection == nil || renderedRows != state.rows
            || (renderedRowsSection == .recent) != (state.selectedSection == .recent) {
            clear(list)
            renderedRows = state.rows
            for row in state.rows {
                let content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom] { edge(content, 6) }
                let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3)!
                gtk_widget_set_hexpand(text, 1)
                gtk_box_append(mp_box(text), rowLabel(row.title))
                let metadata = ([row.folder.string] + row.tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
                var detail = row.previewLine.flatMap { $0.isEmpty ? nil : $0 } ?? metadata
                if state.selectedSection == .recent, let lastUsed = row.lastUsedAt {
                    detail = LinuxStrings.lastUsed(lastUsed) + (detail.isEmpty ? "" : " · " + detail)
                }
                let subtitle = rowLabel(detail)
                gtk_widget_add_css_class(subtitle, "dim-label")
                gtk_box_append(mp_box(text), subtitle)
                gtk_box_append(mp_box(content), text)
                var badges = [String]()
                for (visible, icon, label) in [(row.favorite, "starred-symbolic", LinuxLibraryStrings.favorite),
                                               (row.isReadOnly, "changes-prevent-symbolic", LinuxStrings.readOnly),
                                               (!row.canRender, "dialog-warning-symbolic", LinuxStrings.invalidPrompt)] where visible {
                    let image = gtk_image_new_from_icon_name(icon)!
                    mp_accessible_label(image, label)
                    gtk_widget_set_tooltip_text(image, label)
                    gtk_box_append(mp_box(content), image)
                    badges.append(label)
                }
                mp_accessible_label(content, ([row.title, row.relativePath.string] + badges).joined(separator: ", "))
                gtk_widget_set_tooltip_text(content, row.relativePath.string)
                commands.installDrag(on: content, selection: row.selection)
                gtk_list_box_append(mp_list_box(list), content)
            }
        }
        renderedRowsSection = state.selectedSection
        select(in: list, position: state.rows.firstIndex { $0.selection == state.selection }, focus: hadFocus)
    }

    private func canFavorite(_ state: LibraryBrowserState) -> Bool {
        available && !conflictView.isResolving && state.selectedPrompt?.canRender == true && state.selectedPrompt?.isReadOnly == false
            && (editor?.state.prompt?.relativePath != state.selection?.relativePath
                || (editor?.state.canEdit == true && editor?.state.previewFailure == nil))
    }

    @discardableResult
    private func toggleFavorite() -> Bool {
        guard isVisible, let browser, canFavorite(browser.state) else { return false }
        message = LinuxStrings.favoriteMessage(browser.toggleFavorite())
        messageSelection = browser.selection
        render()
        return true
    }

    private func keyPressed(_ key: UInt32, modifiers: UInt32) -> Bool {
        guard isVisible, !focusedHasPreedit else { return false }
        let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
        let modifiers = modifiers & relevant
        guard commandsAvailable else { return false }
        if key == UInt32(GDK_KEY_Escape), modifiers == 0 {
            if containsFocus(filter) {
                browser?.setFilter("")
                mp_entry_set_text(filter, "")
                gtk_search_bar_set_search_mode(mp_search_bar(searchBar), 0)
                updateActions()
                return true
            }
            if inspectorPage == "assistant", gtk_widget_get_visible(inspectorPane) != 0, assistantPanel.isVisible {
                assistantPanel.close()
                showInspector("fields")
                return true
            }
            return false
        }
        if modifiers == 0 {
            if key == UInt32(GDK_KEY_F9) { return activate(.sidebar) }
            if key == UInt32(GDK_KEY_F2) { return activate(.rename) }
            if containsFocus(list), key == UInt32(GDK_KEY_Delete) { return activate(.delete) }
            if containsFocus(list), key == UInt32(GDK_KEY_Return) { return activate(.edit) }
        }
        if modifiers == GDK_CONTROL_MASK.rawValue {
            let action: LinuxLibraryAction?
            switch key {
            case UInt32(GDK_KEY_n), UInt32(GDK_KEY_N): action = .newPrompt
            case UInt32(GDK_KEY_s), UInt32(GDK_KEY_S): action = .save
            case UInt32(GDK_KEY_d), UInt32(GDK_KEY_D): action = .favorite
            case UInt32(GDK_KEY_f), UInt32(GDK_KEY_F):
                action = .search
            case UInt32(GDK_KEY_1): action = .edit
            case UInt32(GDK_KEY_2): action = .preview
            case UInt32(GDK_KEY_3): action = .source
            case UInt32(GDK_KEY_w), UInt32(GDK_KEY_W): action = .close
            case UInt32(GDK_KEY_r), UInt32(GDK_KEY_R): action = .review
            case UInt32(GDK_KEY_i), UInt32(GDK_KEY_I): action = .improve
            default: action = nil
            }
            if let action { return activate(action) }
        }
        if modifiers == GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue,
           [UInt32(GDK_KEY_s), UInt32(GDK_KEY_S)].contains(key) { return activate(.duplicate) }
        return false // GTK owns list arrows, text editing and Tab traversal.
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
        let widget = row.flatMap { mp_row_widget($0) }
        gtk_widget_grab_focus(position == nil ? list : widget)
    }

    private func configureList(_ widget: GTK.Widget, name: String, label: String) {
        gtk_widget_set_name(widget, name)
        mp_accessible_label(widget, label)
        gtk_list_box_set_selection_mode(mp_list_box(widget), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(mp_list_box(widget), 0)
    }

    private func clear(_ list: GTK.Widget) {
        while let row = gtk_list_box_get_row_at_index(mp_list_box(list), 0) {
            gtk_list_box_remove(mp_list_box(list), mp_row_widget(row))
        }
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
