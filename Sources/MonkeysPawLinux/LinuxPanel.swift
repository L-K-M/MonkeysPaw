#if os(Linux)
import CGtk
import MonkeysPawCore

/// GTK renders Core state and forwards intents. Environment callbacks own
/// leave-the-panel actions; this view never opens files or calls services.
final class LinuxPanel: PanelWindow {
    private final class Preedit {
        var isActive = false
    }

    private struct FieldControl {
        let name: String
        let kind: FieldKind
        let widget: GTK.Widget
        let preedit: Preedit?
    }

    private let window: GTK.Widget
    private var isDestroyed = false
    private weak var picker: PickerModel?
    private weak var boundFill: FillModel?
    private var initialFocus: GTK.Widget?
    private var blurRevision = 0
    private var activationToken: String?
    private var isRendering = false
    private var renderedResults: [PickerResultRow] = []
    private var renderedFocus: Int?
    private var controls: [FieldControl] = []
    private var transientStatus: String?
    private var queryPreedit: Preedit?
    private var openSettings: (() -> Void)?

    private var queryEntry: GTK.Widget!
    private var stack: GTK.Widget!
    private var resultsList: GTK.Widget!
    private var noMatchesBox: GTK.Widget!
    private var noMatchesLabel: GTK.Widget!
    private var createButton: GTK.Widget!
    private var assistantButton: GTK.Widget!
    private var assistantHint: GTK.Widget!
    private var folderButton: GTK.Widget!
    private var formBox: GTK.Widget!
    private var preview: GTK.Widget!
    private var hint: GTK.Widget!
    private var status: GTK.Widget!
    private var actions: GTK.Widget!
    private var useButton: GTK.Widget!
    private var copyButton: GTK.Widget!
    private var forgetButton: GTK.Widget!
    private var editButton: GTK.Widget!
    private var libraryButton: GTK.Widget!

    var clipboardOwner: GTK.Widget { window }
    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }
    var isActiveAndVisible: Bool { isVisible && gtk_window_is_active(mp_window(window)) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), AppIdentity.displayName)
        gtk_window_set_default_size(mp_window(window),
                                    Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        gtk_widget_set_focusable(window, 1)
        GTK.onSignal(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            // GTK owns the window; its Swift wrapper and queued UI work can outlive it.
            self.isDestroyed = true
            self.blurRevision += 1
        }

        // The window survives library switches. Install its controllers once;
        // they always use the current binding rather than a captured picker.
        GTK.observeKeys(window) { [weak self] key, modifiers in self?.keyPressed(key, modifiers: modifiers) ?? false }
        GTK.onCloseRequested(window) { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if let picker = self.picker { picker.dismiss() } else { self.hide() }
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "is-active") { [weak self] in self?.focusChanged() }
        GTK.onNotify(UnsafeMutableRawPointer(window), "focus-widget") { [weak self] in self?.fieldFocusChanged() }
    }

    func rebind(picker: PickerModel, session: DesktopSession, openSetup: @escaping () -> Void,
                openSettings: @escaping () -> Void,
                requestedIntent: @escaping (PickerModel.Intent) -> Void,
                createPrompt: @escaping (String) -> Void) {
        guard !isDestroyed else { return }
        self.picker?.onChange = nil
        self.picker = nil
        blurRevision += 1 // Retire a blur timeout queued by the previous view.
        isRendering = true
        gtk_window_set_focus(mp_window(window), nil)
        boundFill = nil
        controls = []
        initialFocus = nil
        renderedResults = []
        renderedFocus = nil
        transientStatus = nil
        queryPreedit = nil
        gtk_window_set_child(mp_window(window), nil)
        isRendering = false
        self.picker = picker
        self.openSettings = openSettings
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 12) }

        queryEntry = gtk_entry_new()!
        queryPreedit = observePreedit(in: mp_entry_text_delegate(queryEntry))
        gtk_widget_set_name(queryEntry, "picker-query")
        gtk_entry_set_placeholder_text(mp_entry(queryEntry), LinuxStrings.searchPrompts)
        mp_accessible_label(queryEntry, LinuxStrings.searchPrompts)
        initialFocus = queryEntry
        gtk_box_append(mp_box(content), queryEntry)
        GTK.onSignal(queryEntry, "changed") { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering else { return }
            self.transientStatus = nil
            picker.setQuery(String(cString: mp_entry_text(self.queryEntry)))
        }

        let split = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_widget_set_vexpand(split, 1)
        stack = gtk_stack_new()!
        gtk_widget_set_hexpand(stack, 1)
        let pickerPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        resultsList = gtk_list_box_new()!
        gtk_widget_set_name(resultsList, "picker-results")
        gtk_list_box_set_selection_mode(mp_list_box(resultsList), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(mp_list_box(resultsList), 0)
        let listScroll = scrolled(resultsList)
        gtk_box_append(mp_box(pickerPage), listScroll)
        GTK.onRow(resultsList, "row-selected") { [weak self, weak picker] position in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering, let position,
                  picker.selectionIndex != position else { return }
            picker.selectResult(at: position)
        }
        GTK.onRow(resultsList, "row-activated") { [weak self, weak picker] position in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering, let position else { return }
            picker.selectResult(at: position)
            picker.use(mode: .paste(.standard))
        }

        noMatchesBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        noMatchesLabel = GTK.label("")
        gtk_box_append(mp_box(noMatchesBox), noMatchesLabel)
        createButton = GTK.button("", { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  let noMatches = picker.noMatches else { return }
            createPrompt(noMatches.createTitle)
        })
        gtk_box_append(mp_box(noMatchesBox), createButton)
        assistantButton = GTK.button("", {})
        gtk_widget_set_sensitive(assistantButton, 0)
        gtk_widget_set_tooltip_text(assistantButton, LinuxStrings.assistantNotConfigured)
        // Labels are supplied by the Core no-match state during rendering.
        gtk_widget_set_name(assistantButton, "picker-assistant")
        gtk_box_append(mp_box(noMatchesBox), assistantButton)
        assistantHint = GTK.label(LinuxStrings.assistantNotConfigured)
        gtk_box_append(mp_box(noMatchesBox), assistantHint)
        folderButton = GTK.button("", { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.openLibrary()
        })
        gtk_widget_set_name(folderButton, "picker-open-folder")
        gtk_box_append(mp_box(noMatchesBox), folderButton)
        gtk_box_append(mp_box(pickerPage), noMatchesBox)
        gtk_stack_add_named(mp_stack(stack), pickerPage, "picker")

        formBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_stack_add_named(mp_stack(stack), scrolled(formBox), "fill")
        gtk_box_append(mp_box(split), stack)
        preview = gtk_text_view_new()!
        gtk_widget_set_name(preview, "picker-preview")
        mp_accessible_label(preview, LinuxStrings.preview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(preview), GTK_WRAP_WORD_CHAR)
        let previewScroll = scrolled(preview)
        gtk_widget_set_hexpand(previewScroll, 1)
        gtk_box_append(mp_box(split), previewScroll)
        gtk_box_append(mp_box(content), split)

        status = GTK.label("")
        gtk_widget_set_name(status, "picker-status")
        gtk_box_append(mp_box(content), status)
        actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        useButton = GTK.button(LinuxStrings.usePrompt) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.usePreferred()
        }
        copyButton = GTK.button(LinuxStrings.copy) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.use(mode: .copyOnly)
        }
        gtk_widget_set_name(useButton, "picker-use")
        gtk_widget_set_name(copyButton, "picker-copy")
        forgetButton = GTK.button(LinuxStrings.forgetValues) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.transientStatus = nil
            picker.forgetSelectedValues()
        }
        gtk_widget_set_name(forgetButton, "picker-forget-values")
        mp_accessible_label(forgetButton, LinuxStrings.forgetValues)
        editButton = GTK.button(LinuxStrings.edit) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.editSelected()
        }
        libraryButton = GTK.button(LinuxStrings.library) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.openLibrary()
        }
        gtk_widget_set_name(libraryButton, "picker-library")
        let settingsButton = GTK.button(LinuxStrings.openSettings) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            openSettings()
        }
        gtk_widget_set_name(settingsButton, "picker-settings")
        for button in [useButton!, copyButton!, forgetButton!, editButton!, libraryButton!,
                       GTK.button(LinuxStrings.cancel, { [weak self, weak picker] in
                           guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
                           picker.dismiss()
                       }),
                       GTK.button(LinuxStrings.setup, { [weak self, weak picker] in
                           guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
                           openSetup()
                       }), settingsButton] { gtk_box_append(mp_box(actions), button) }
        gtk_box_append(mp_box(content), actions)
        hint = GTK.label(LinuxStrings.pickerHint)
        gtk_box_append(mp_box(content), hint)
        gtk_box_append(mp_box(content), GTK.label(LinuxStrings.pickerSession(session)))
        gtk_window_set_child(mp_window(window), content)

        picker.onChange = { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            if picker.state == .picker, let intent = picker.takeRequestedIntent() {
                requestedIntent(intent)
                return
            }
            self.render()
        }
        render()
    }

    private func render() {
        guard !isDestroyed, let picker, picker.state != .closed else { return }
        if case .done = picker.state { return } // Delivery owns the hide.
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        let editing = picker.state != .delivering
        if !editing || (picker.state == .fill && boundFill !== picker.fillModel)
            || (picker.state == .picker && boundFill != nil) {
            // Let native text controls receive focus-out while still enabled.
            // Disabling/hiding their page first loses that event on GTK 4.8.
            gtk_window_set_focus(mp_window(window), nil)
        }
        gtk_widget_set_sensitive(queryEntry, picker.state == .picker ? 1 : 0)
        gtk_widget_set_sensitive(stack, editing ? 1 : 0)
        gtk_widget_set_sensitive(actions, editing ? 1 : 0)
        let hasPrompt = picker.fillModel != nil || picker.selectionIndex.map { picker.results.indices.contains($0) } == true
        gtk_widget_set_visible(forgetButton, hasPrompt ? 1 : 0)
        gtk_widget_set_sensitive(forgetButton, editing ? 1 : 0)
        renderStatus(picker)
        guard editing else { return }

        if String(cString: mp_entry_text(queryEntry)) != picker.query { mp_entry_set_text(queryEntry, picker.query) }
        if picker.state == .fill, let fill = picker.fillModel {
            gtk_stack_set_visible_child_name(mp_stack(stack), "fill")
            let newForm = boundFill !== fill
            if newForm { buildForm(fill) }
            for (control, field) in zip(controls, fill.fields) { update(control, value: field.value) }
            switch fill.preview {
            case .rendered(let text): setPreview(text)
            case .blocked(let error, let issues):
                let message = fill.builtinsResolved ? error.description : LinuxStrings.preparingPreview
                setPreview(([message] + issues.map(\.message)).joined(separator: "\n"))
            }
            gtk_widget_set_sensitive(useButton, fill.deliverEnabled ? 1 : 0)
            gtk_widget_set_sensitive(copyButton, fill.canCopyOnly ? 1 : 0)
            if let position = fill.focusIndex, controls.indices.contains(position),
               newForm || renderedFocus != position {
                initialFocus = controls[position].widget
                gtk_widget_grab_focus(controls[position].widget)
            }
            renderedFocus = fill.focusIndex
        } else {
            let wasFill = boundFill != nil
            boundFill = nil
            renderedFocus = nil
            gtk_stack_set_visible_child_name(mp_stack(stack), "picker")
            renderResults(picker)
            switch picker.selectedPreview {
            case .body(let text): setPreview(text)
            case .issues(let issues): setPreview(issues.map(\.message).joined(separator: "\n"))
            case .none: setPreview("")
            }
            initialFocus = queryEntry
            if wasFill { gtk_widget_grab_focus(queryEntry) }
            let enabled = picker.selectionIndex.map {
                picker.results.indices.contains($0) && picker.results[$0].canRender
            } == true && !picker.isResolvingBuiltins
            gtk_widget_set_sensitive(useButton, enabled ? 1 : 0)
            gtk_widget_set_sensitive(copyButton, enabled ? 1 : 0)
        }
        let inFill = picker.state == .fill
        gtk_button_set_label(mp_button(useButton), inFill ? LinuxStrings.deliver : LinuxStrings.usePrompt)
        gtk_widget_set_visible(editButton, inFill ? 0 : 1)
        gtk_widget_set_sensitive(editButton, picker.selectionIndex == nil ? 0 : 1)
        gtk_widget_set_visible(libraryButton, inFill ? 0 : 1)
        gtk_label_set_text(mp_label(hint), inFill ? LinuxStrings.fillHint : LinuxStrings.pickerHint)
    }

    private func renderStatus(_ picker: PickerModel) {
        var warnings = picker.persistenceWarnings
        for warning in picker.fillModel?.persistenceWarnings ?? [] where !warnings.contains(warning) { warnings.append(warning) }
        var messages = [picker.libraryAvailable ? nil : LinuxStrings.libraryUnavailable,
                        picker.isResolvingBuiltins ? LinuxStrings.resolvingBuiltins : nil].compactMap { $0 }
        if let transientStatus, !messages.contains(transientStatus) { messages.append(transientStatus) }
        messages += warnings.map(LinuxStrings.persistenceWarning)
        if let error = picker.forgetValuesError {
            messages.append(LinuxStrings.forgetValuesError(error, state: picker.state))
        }
        gtk_label_set_text(mp_label(status), messages.joined(separator: "\n"))
        gtk_widget_set_visible(status, messages.isEmpty ? 0 : 1)
    }

    private func renderResults(_ picker: PickerModel) {
        if renderedResults != picker.results {
            while let child = gtk_widget_get_first_child(resultsList) { gtk_list_box_remove(mp_list_box(resultsList), child) }
            renderedResults = picker.results
            for result in picker.results {
                let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
                gtk_box_append(mp_box(row), GTK.label((result.favorite ? "★ " : "") + result.title))
                let detail = ([result.folder] + result.tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
                gtk_box_append(mp_box(row), GTK.label(detail))
                gtk_list_box_append(mp_list_box(resultsList), row)
            }
        }
        let row = picker.selectionIndex.flatMap { gtk_list_box_get_row_at_index(mp_list_box(resultsList), Int32($0)) }
        gtk_list_box_select_row(mp_list_box(resultsList), row)
        let noMatches = picker.noMatches
        gtk_widget_set_visible(noMatchesBox, picker.results.isEmpty ? 1 : 0)
        gtk_label_set_text(mp_label(noMatchesLabel), noMatches?.message ?? LinuxStrings.emptyLibrary)
        gtk_button_set_label(mp_button(createButton), noMatches?.createLabel ?? "")
        gtk_widget_set_visible(createButton, noMatches == nil ? 0 : 1)
        gtk_widget_set_sensitive(createButton, picker.libraryAvailable ? 1 : 0)
        gtk_button_set_label(mp_button(assistantButton), noMatches?.writeLabel ?? "")
        gtk_widget_set_visible(assistantButton, noMatches == nil ? 0 : 1)
        gtk_widget_set_visible(assistantHint, noMatches == nil ? 0 : 1)
        gtk_button_set_label(mp_button(folderButton), noMatches?.openLibraryLabel ?? LinuxStrings.library)
    }

    private func buildForm(_ fill: FillModel) {
        while let child = gtk_widget_get_first_child(formBox) { gtk_box_remove(mp_box(formBox), child) }
        controls = []
        boundFill = fill
        for field in fill.fields {
            let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
            gtk_box_append(mp_box(row), GTK.label(field.label))
            let widget: GTK.Widget
            let preedit: Preedit?
            switch field.kind {
            case .text:
                widget = gtk_entry_new()!
                preedit = observePreedit(in: mp_entry_text_delegate(widget))
                mp_entry_set_text(widget, field.value)
                GTK.onSignal(widget, "changed") { [weak self, weak fill] in
                    guard let self, !self.isDestroyed, let fill, self.boundFill === fill,
                          !self.isRendering else { return }
                    fill.setValue(String(cString: mp_entry_text(widget)), name: field.name)
                }
                gtk_box_append(mp_box(row), widget)
            case .multiline:
                widget = gtk_text_view_new()!
                preedit = observePreedit(in: widget)
                gtk_text_view_set_wrap_mode(mp_text_view(widget), GTK_WRAP_WORD_CHAR)
                let buffer = gtk_text_view_get_buffer(mp_text_view(widget))!
                gtk_text_buffer_set_text(buffer, field.value, -1)
                GTK.onSignal(UnsafeMutableRawPointer(buffer), "changed") { [weak self, weak fill] in
                    guard let self, !self.isDestroyed, let fill, self.boundFill === fill,
                          !self.isRendering else { return }
                    fill.setValue(self.text(in: widget), name: field.name)
                }
                gtk_box_append(mp_box(row), scrolled(widget))
            case .choice:
                widget = gtk_combo_box_text_new()!
                preedit = nil
                for option in field.options { gtk_combo_box_text_append(mp_combo_box_text(widget), option.value, option.label) }
                gtk_combo_box_set_active_id(mp_combo_box(widget), field.value)
                GTK.onSignal(widget, "changed") { [weak self, weak fill] in
                    guard let self, !self.isDestroyed, let fill, self.boundFill === fill, !self.isRendering,
                          let value = gtk_combo_box_get_active_id(mp_combo_box(widget)) else { return }
                    fill.setValue(String(cString: value), name: field.name)
                }
                gtk_box_append(mp_box(row), widget)
            }
            gtk_widget_set_name(widget, "fill-field-" + field.name)
            mp_accessible_label(widget, field.label)
            gtk_widget_set_tooltip_text(widget, field.description)
            if let description = field.description, !description.isEmpty {
                let label = GTK.label(description)
                gtk_widget_set_name(label, "fill-description-" + field.name)
                gtk_widget_add_css_class(label, "dim-label")
                gtk_box_append(mp_box(row), label)
                mp_accessible_description(widget, description)
            }
            controls.append(FieldControl(name: field.name, kind: field.kind, widget: widget, preedit: preedit))
            gtk_box_append(mp_box(formBox), row)
        }
        initialFocus = controls.first?.widget ?? queryEntry
    }

    private func update(_ control: FieldControl, value: String) {
        switch control.kind {
        case .text:
            if String(cString: mp_entry_text(control.widget)) != value { mp_entry_set_text(control.widget, value) }
        case .multiline:
            if text(in: control.widget) != value { gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(control.widget)), value, -1) }
        case .choice:
            if gtk_combo_box_get_active_id(mp_combo_box(control.widget)).map({ String(cString: $0) }) != value {
                gtk_combo_box_set_active_id(mp_combo_box(control.widget), value)
            }
        }
    }

    private func text(in view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func setPreview(_ text: String) { gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), text, -1) }

    private func scrolled(_ child: GTK.Widget) -> GTK.Widget {
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), child)
        gtk_widget_set_vexpand(scroll, 1)
        return scroll
    }

    private var focusedControl: Int? {
        guard !isDestroyed, let focus = gtk_window_get_focus(mp_window(window)) else { return nil }
        return controls.firstIndex { $0.widget == focus || gtk_widget_is_ancestor(focus, $0.widget) != 0 }
    }

    private func observePreedit(in widget: GTK.Widget?) -> Preedit? {
        guard !isDestroyed, let widget else { return nil }
        let preedit = Preedit()
        GTK.onPreeditChanged(widget) { [weak self] active in
            guard let self, !self.isDestroyed else { return }
            preedit.isActive = active
        }
        return preedit
    }

    private var focusedHasPreedit: Bool {
        guard !isDestroyed, let focus = gtk_window_get_focus(mp_window(window)) else { return false }
        if focus == queryEntry || gtk_widget_is_ancestor(focus, queryEntry) != 0 {
            return queryPreedit?.isActive == true
        }
        return focusedControl.map { controls[$0].preedit?.isActive == true } ?? false
    }

    private func fieldFocusChanged() {
        guard !isDestroyed, !isRendering, let position = focusedControl else { return }
        picker?.fillModel?.focusField(at: position)
    }

    private func keyPressed(_ key: UInt32, modifiers: UInt32) -> Bool {
        // Capture runs before GtkText/GtkTextView's input method. Composition
        // keys must reach the focused native control without picker intents.
        guard !isDestroyed, let picker, !focusedHasPreedit else { return false }
        let kind = focusedControl.map { controls[$0].kind }
        guard let intent = LinuxPickerKeys.intent(for: key, modifiers: modifiers, state: picker.state, fieldKind: kind) else { return false }
        if intent == .use(.paste(.standard)), let focus = gtk_window_get_focus(mp_window(window)), mp_is_button(focus) != 0 {
            return false // Native button activation must keep its own intent.
        }
        switch intent {
        case .moveUp: picker.moveSelection(.up)
        case .moveDown: picker.moveSelection(.down)
        case .use(let mode): picker.use(mode: mode)
        case .edit: picker.editSelected()
        case .openLibrary: picker.openLibrary()
        case .openSettings: openSettings?()
        case .escape: picker.escape()
        case .focusNext: picker.fillModel?.focusNext()
        case .focusPrevious: picker.fillModel?.focusPrevious()
        case .deliverPreferred: usePreferred()
        case .deliver(let mode): picker.fillModel?.deliver(mode: mode)
        }
        return true
    }

    private func usePreferred() { use(mode: picker?.fillModel?.preferredMode ?? .paste(.standard)) }

    private func use(mode: DeliveryMode) {
        guard !isDestroyed, let picker else { return }
        if picker.state == .fill { picker.fillModel?.deliver(mode: mode) }
        else { picker.use(mode: mode) }
    }

    func showStatus(_ message: String) {
        guard !isDestroyed else { return }
        transientStatus = message
        render()
    }

    private func focusChanged() {
        guard !isDestroyed else { return }
        blurRevision += 1
        let revision = blurRevision
        guard isVisible, !isActiveAndVisible else { return }
        GTK.after(Limits.blurHideDelay.timeInterval) { [weak self] in
            guard let self, !self.isDestroyed, self.blurRevision == revision,
                  self.isVisible, !self.isActiveAndVisible else { return }
            self.picker?.dismiss()
        }
    }

    func useActivationToken(_ token: String?) { activationToken = token }

    func show() {
        guard !isDestroyed else { return }
        blurRevision += 1
        if let activationToken {
            gtk_window_set_startup_id(mp_window(window), activationToken)
            self.activationToken = nil
        }
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(initialFocus ?? window)
    }

    func hideForDelivery() { hide() }

    func hide() {
        guard !isDestroyed else { return }
        blurRevision += 1
        transientStatus = nil
        gtk_widget_set_visible(window, 0)
    }
}
#endif
