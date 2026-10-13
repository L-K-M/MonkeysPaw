#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GTK owns this reusable window. Model subscriptions and borrowed widget
/// pointers are retired before a graph replacement or native destruction.
final class LinuxLibraryWindow {
    struct ImportBinding {
        let state: LinuxLibraryImportState
        let chooser: LinuxImportChoosing
    }

    private let window: GTK.Widget
    private let openFolder: () -> Void
    private weak var browser: LibraryBrowserModel?
    private weak var editor: EditorModel?
    private var observer: UUID?
    private var editorObserver: UUID?
    private var bindingRevision: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var previousPrompt: LibraryPromptSelection?
    private var copySelection: LibraryPromptSelection?
    private var revealAfterOpen: [LibraryPromptSelection] = []
    private var closeRequested = false
    private var available = true
    private var activeDialog: LinuxEditorDialogState?
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
    private let sidebar: GTK.Widget
    private let list: GTK.Widget
    private let preview: GTK.Widget
    private let previewTitle: GTK.Widget
    private let favorite: GTK.Widget
    private let status: GTK.Widget
    private let empty: GTK.Widget
    private let tabs = gtk_notebook_new()!
    private let source = LinuxLibrarySourceEditor()
    private let readOnly = GTK.label("")
    private let validation = GTK.label("")
    private let fields = gtk_grid_new()!
    private let editorStatus = GTK.label("")
    private let save = GTK.button(LinuxEditorStrings.save) {}
    private let revert = GTK.button(LinuxEditorStrings.revert) {}
    private let saveCopy = GTK.button(LinuxEditorStrings.saveAsCopy) {}
    private let history = LinuxLibraryHistoryView()
    private let commands: LinuxLibraryCommands
    private var historyPrompt: LibraryPromptSelection?
    private var historyReloadPending = false
    private var historyPage: Int32 = -1
    private var renderedFields: [PromptField]?
    private var renderedPreview: String?
    private var importView: LinuxLibraryImportView?

    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, browser: LibraryBrowserModel, editor: EditorModel,
         imports: ImportBinding? = nil,
         openFolder: @escaping () -> Void) {
        self.openFolder = openFolder
        window = gtk_application_window_new(application)!
        commands = LinuxLibraryCommands(parent: window)
        filter = gtk_entry_new()!
        sidebar = gtk_list_box_new()!
        list = gtk_list_box_new()!
        preview = gtk_text_view_new()!
        previewTitle = GTK.label(LinuxStrings.preview)
        favorite = GTK.button(LinuxStrings.addFavorite) {}
        status = GTK.label("")
        empty = GTK.label(LinuxStrings.noLibraryMatches)
        commands.onChange = { [weak self] in self?.render() }

        GTK.hideOnClose(window)
        GTK.onCloseRequested(window) { [weak self] in self?.requestClose() }
        gtk_window_set_title(mp_window(window), LinuxStrings.library)
        gtk_window_set_default_size(mp_window(window),
            Int32(Limits.panelSize.width + Limits.panelSize.height), Int32(Limits.setupWindowSize.height))
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            self.isDestroyed = true
            self.unbind()
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isVisible { self.updateDialog() }
            else { self.commands.cancelDialog() }
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
        if let imports {
            let view = LinuxLibraryImportView(parent: window, list: list, chooser: imports.chooser)
            importView = view
            gtk_box_append(mp_box(content), view.actions)
        }

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
            self.selectPrompt(self.renderedRows[position].selection)
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
        configureEditor(in: detail)
        gtk_box_append(mp_box(panes), detail)
        gtk_box_append(mp_box(content), panes)
        if let importView { gtk_box_append(mp_box(content), importView.report) }
        gtk_widget_set_name(status, "library-status")
        gtk_box_append(mp_box(content), status)
        gtk_box_append(mp_box(content), GTK.label(LinuxStrings.libraryHint))
        gtk_window_set_child(mp_window(window), content)
        rebind(browser: browser, editor: editor, imports: imports?.state)
    }

    deinit { unbind() }

    func rebind(browser: LibraryBrowserModel, editor: EditorModel, imports: LinuxLibraryImportState?) {
        guard !isDestroyed else { return }
        precondition((importView == nil) == (imports == nil),
                     "Import-enabled windows require the current graph's import state")
        unbind()
        self.browser = browser
        self.editor = editor
        commands.bind(editor: editor, browser: browser)
        historyPrompt = nil
        historyReloadPending = false
        if let imports { importView?.bind(imports) }
        previousPrompt = nil
        copySelection = nil
        revealAfterOpen = []
        closeRequested = false
        dismissedConflict = nil
        gtk_notebook_set_current_page(mp_notebook(tabs), 0)
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
        render()
        gtk_window_present(mp_window(window))
        if editor?.state.prompt == nil, let selection = browser?.selection { selectPrompt(selection) }
        updateDialog()
        gtk_widget_grab_focus(filter)
    }

    func hide() { requestClose() }

    func tearDown() {
        guard !isDestroyed else { return }
        unbind()
        gtk_widget_set_visible(window, 0)
    }

    private func unbind() {
        endDialog()
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
        gtk_notebook_set_current_page(mp_notebook(tabs), 0)
        if !revealAfterOpen.contains(selection) { revealAfterOpen.append(selection) }
        selectPrompt(selection)
    }

    func setLibraryAvailable(_ available: Bool) {
        let becameAvailable = available && !self.available
        self.available = available
        if becameAvailable, !isDestroyed, isHistorySelected { loadHistory() }
        render()
    }

    private func selectPrompt(_ selection: LibraryPromptSelection) {
        guard !isDestroyed, let editor else { return }
        let action = EditorDiscardAction.open(selection)
        guard editor.state.pendingDecision?.action != action, !editor.state.queuedActions.contains(action) else { return }
        let revision = bindingRevision
        editor.request(action) { [weak self] result in
            guard let self, !self.isDestroyed, self.bindingRevision == revision else { return }
            let reveal = self.revealAfterOpen.contains(selection)
            self.revealAfterOpen.removeAll { $0 == selection }
            if result == .allowed {
                if reveal { self.browser?.setFilter(""); self.browser?.selectSection(.all) }
                self.copySelection = nil
                self.browser?.selectPrompt(self.editor?.state.prompt)
                if reveal { gtk_widget_grab_focus(self.source.widget) }
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
        gtk_button_set_label(mp_button(favorite), favoriteTitle)
        mp_accessible_label(favorite, favoriteTitle)
        gtk_widget_set_sensitive(favorite, canFavorite(state) ? 1 : 0)
        gtk_label_set_text(mp_label(status), message ?? "")
        gtk_widget_set_visible(status, message == nil ? 0 : 1)
        updateDialog()
    }

    private func configureEditor(in detail: GTK.Widget) {
        gtk_widget_set_name(readOnly, "library-read-only")
        gtk_box_append(mp_box(detail), readOnly)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        for (button, name) in [(save, "library-save"), (revert, "library-revert"), (saveCopy, "library-save-copy")] {
            gtk_widget_set_name(button, name)
            gtk_box_append(mp_box(actions), button)
        }
        GTK.onSignal(save, "clicked") { [weak self] in self?.savePrompt() }
        GTK.onSignal(saveCopy, "clicked") { [weak self] in
            guard let self, self.isVisible, self.available else { return }
            self.editor?.saveAsCopy()
        }
        GTK.onSignal(revert, "clicked") { [weak self] in
            guard let self, self.isVisible, self.available else { return }
            self.editor?.revert()
        }
        gtk_box_append(mp_box(actions), commands.widget)
        gtk_box_append(mp_box(detail), actions)
        let editPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_box_append(mp_box(editPage), scrolled(source.widget, width: Limits.panelSize.width / 2))
        gtk_widget_set_name(validation, "library-validation")
        gtk_label_set_selectable(mp_label(validation), 1)
        let issuesScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_max_content_height(mp_scrolled_window(issuesScroll), 120)
        gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(issuesScroll), 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(issuesScroll), validation)
        gtk_box_append(mp_box(editPage), issuesScroll)
        gtk_widget_set_name(preview, "library-preview")
        mp_accessible_label(preview, LinuxStrings.preview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(preview), GTK_WRAP_WORD_CHAR)
        gtk_widget_set_name(fields, "library-fields")
        mp_accessible_label(fields, LinuxEditorStrings.parsedFields)
        gtk_grid_set_column_spacing(grid, 12)
        gtk_grid_set_row_spacing(grid, 8)
        gtk_widget_set_name(tabs, "library-editor-tabs")
        gtk_notebook_append_page(mp_notebook(tabs), editPage, GTK.label(LinuxStrings.edit))
        gtk_notebook_append_page(mp_notebook(tabs), scrolled(preview, width: Limits.panelSize.width / 2), GTK.label(LinuxStrings.preview))
        gtk_notebook_append_page(mp_notebook(tabs), scrolled(fields, width: Limits.panelSize.width / 2), GTK.label(LinuxEditorStrings.fields))
        historyPage = gtk_notebook_append_page(mp_notebook(tabs), history.widget, GTK.label(LinuxEditorStrings.history))
        GTK.onNotify(UnsafeMutableRawPointer(tabs), "page") { [weak self] in
            guard let self, !self.isDestroyed, self.isHistorySelected else { return }
            self.loadHistory()
        }
        history.onLoad = { [weak self] in self?.loadHistory() }
        history.onSelect = { [weak self] revision in self?.editor?.selectRevision(revision) }
        history.onRestore = { [weak self] revision in self?.commands.restore(revision) }
        gtk_box_append(mp_box(detail), tabs)
        gtk_widget_set_name(editorStatus, "library-editor-status")
        gtk_box_append(mp_box(detail), editorStatus)
        source.onEdit = { [weak self] text in
            guard let self, !self.isDestroyed, self.available else { return }
            self.editor?.edit(text)
        }
        source.onCompositionEnded = { [weak self] in self?.render() }
    }

    private var grid: UnsafeMutablePointer<GtkGrid> {
        UnsafeMutableRawPointer(fields).assumingMemoryBound(to: GtkGrid.self)
    }

    private func renderEditor() {
        guard let editor else { return }
        let state = editor.state
        gtk_label_set_text(mp_label(previewTitle), state.prompt?.relativePath.string ?? LinuxStrings.selectLibraryPrompt)
        source.update(state, revision: sourceRevision, available: available)
        gtk_label_set_text(mp_label(readOnly), state.readOnlyReason.map(LinuxEditorStrings.readOnly) ?? "")
        gtk_widget_set_visible(readOnly, state.readOnlyReason == nil ? 0 : 1)
        gtk_label_set_text(mp_label(validation), state.issues.map(LinuxEditorStrings.issue).joined(separator: "\n"))
        let text = state.prompt == nil ? LinuxStrings.selectLibraryPrompt
            : state.previewFailure == nil ? state.preview : state.issues.map(\.message).joined(separator: "\n")
        if renderedPreview.map({ $0.utf8.elementsEqual(text.utf8) }) != true {
            renderedPreview = text
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), text, Int32(text.utf8.count))
        }
        if renderedFields != state.fields {
            while let child = gtk_widget_get_first_child(fields) { gtk_widget_unparent(child) }
            renderedFields = state.fields
            if state.fields.isEmpty { gtk_grid_attach(grid, GTK.label(LinuxEditorStrings.noFields), 0, 0, 5, 1) }
            else {
                for (column, title) in LinuxEditorStrings.fieldColumns.enumerated() {
                    gtk_grid_attach(grid, GTK.label(title), Int32(column), 0, 1, 1)
                }
                for (row, field) in state.fields.enumerated() {
                    let values = [[field.name, field.label, field.description].compactMap { $0 }.joined(separator: "\n"),
                        field.kind.rawValue, field.defaultValue, field.options.map { $0.label + " = " + $0.value }.joined(separator: "\n"),
                        LinuxEditorStrings.behavior(field)]
                    for (column, value) in values.enumerated() {
                        let label = GTK.label(value)
                        gtk_label_set_selectable(mp_label(label), 1)
                        gtk_widget_set_valign(label, GTK_ALIGN_START)
                        gtk_grid_attach(grid, label, Int32(column), Int32(row + 1), 1, 1)
                    }
                }
            }
        }
        gtk_widget_set_sensitive(save, available && state.canSave ? 1 : 0)
        gtk_widget_set_sensitive(saveCopy, available && state.canSave ? 1 : 0)
        gtk_widget_set_sensitive(revert, available && state.prompt != nil && state.status != .loading
            && state.status != .saving && state.status != .commandRunning ? 1 : 0)
        commands.update(state, available: available)
        history.update(state, available: available, canRestore: commands.canRun && !commands.hasDialog)
        gtk_label_set_text(mp_label(editorStatus), commands.message ?? LinuxEditorStrings.status(state))
        if state.prompt == nil { historyPrompt = nil }
        if isHistorySelected, state.prompt != historyPrompt { loadHistory() }
    }

    private var isHistorySelected: Bool {
        historyPage >= 0 && gtk_notebook_get_current_page(mp_notebook(tabs)) == historyPage
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
        guard isVisible, available, let editor, editor.state.canSave else { return false }
        if editor.state.conflict != nil {
            dismissedConflict = nil
            updateDialog()
        } else { editor.save() }
        return true
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
        else { desired = nil }
        guard desired != activeDialog else { return }
        endDialog()
        guard let desired else { return }
        activeDialog = desired
        let revision = dialogRevision
        dialog = LinuxEditorDialog(parent: window, state: desired) { [weak self] response in
            guard let self, !self.isDestroyed, self.dialogRevision == revision,
                  self.activeDialog == desired else { return }
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

    private func canFavorite(_ state: LibraryBrowserState) -> Bool {
        available && state.selectedPrompt?.canRender == true && state.selectedPrompt?.isReadOnly == false
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
        guard isVisible, let browser else { return false }
        // Native IME cancellation belongs to the focused filter's input method.
        if filterPreedit, containsFocus(filter) { return false }
        if source.hasPreedit, containsFocus(source.widget) { return false }
        let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
        let modifiers = modifiers & relevant
        guard activeDialog == nil, !commands.hasDialog else { return false }
        if key == UInt32(GDK_KEY_Escape), modifiers == 0 {
            if !browser.filter.isEmpty { browser.setFilter(""); render(); return true }
            return requestClose()
        }
        if [UInt32(GDK_KEY_s), UInt32(GDK_KEY_S)].contains(key), modifiers == GDK_CONTROL_MASK.rawValue {
            return savePrompt()
        }
        if [UInt32(GDK_KEY_w), UInt32(GDK_KEY_W)].contains(key), modifiers == GDK_CONTROL_MASK.rawValue {
            return requestClose()
        }
        if [UInt32(GDK_KEY_d), UInt32(GDK_KEY_D)].contains(key), modifiers == GDK_CONTROL_MASK.rawValue {
            return toggleFavorite()
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
