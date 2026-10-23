#if os(Linux)
import CGtk
import MonkeysPawCore

/// A staged placeholder-settings editor over one PromptFieldSettings draft.
/// Apply emits the draft exactly once; Cancel and native close emit nil.
/// Option rows mutate the projected options in place so Core keeps each
/// retained option's original declaration metadata on write.
final class LinuxFieldSettingsDialog {
    private let window: GTK.Widget
    private var draft: PromptFieldSettings
    private var isDestroyed = false
    private var hasResponded = false
    private var hasPreedit = false
    private var respond: ((PromptFieldSettings?) -> Void)?
    private let kind = gtk_combo_box_text_new()!
    private let labelEntry = gtk_entry_new()!
    private let descriptionEntry = gtk_entry_new()!
    private let defaultToggle = gtk_check_button_new_with_label(LinuxEditorStrings.fieldDefault)!
    private let defaultEntry = gtk_text_view_new()!
    private let optionsSection = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    private let optionRows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
    private var optionEntries: [(label: GTK.Widget, value: GTK.Widget)] = []
    private let optionalToggle = gtk_check_button_new_with_label(LinuxEditorStrings.optional)!
    private let rememberToggle = gtk_check_button_new_with_label(LinuxEditorStrings.remember)!
    private let validation = GTK.label("")
    private let apply = gtk_button_new_with_label(LinuxEditorStrings.apply)!

    init(parent: GTK.Widget, settings: PromptFieldSettings, respond: @escaping (PromptFieldSettings?) -> Void) {
        draft = settings
        window = gtk_window_new()!
        gtk_widget_set_name(window, "library-field-settings-dialog")
        gtk_window_set_title(mp_window(window), LinuxEditorStrings.fieldSettingsTitle(settings.name))
        gtk_window_set_transient_for(mp_window(window), mp_window(parent))
        gtk_window_set_modal(mp_window(window), 1)
        gtk_window_set_destroy_with_parent(mp_window(window), 1)
        GTK.onSignal(window, "destroy") { [weak self] in self?.isDestroyed = true }
        self.respond = respond
        GTK.onCloseRequested(window) { [weak self] in self?.finish(nil) }
        GTK.observeKeys(window) { [weak self] key, modifiers in
            let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
                | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
            guard self?.hasPreedit == false, key == UInt32(GDK_KEY_Escape), modifiers & relevant == 0 else { return false }
            self?.finish(nil)
            return true
        }

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 16) }
        let name = GTK.label("{{" + settings.name + "}}")
        gtk_widget_set_name(name, "field-settings-name")
        gtk_widget_add_css_class(name, "monospace")
        gtk_widget_add_css_class(name, "dim-label")
        gtk_box_append(mp_box(content), name)

        // A scroll boundary keeps every control reachable in short windows;
        // the response buttons stay outside so they can never scroll away.
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_width(mp_scrolled_window(scroll), 380)
        gtk_scrolled_window_set_max_content_height(mp_scrolled_window(scroll), 440)
        gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(scroll), 1)
        gtk_widget_set_vexpand(scroll, 1)
        let form = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), form)

        let kinds: [FieldKind] = [.text, .multiline, .choice]
        gtk_widget_set_name(kind, "field-settings-kind")
        mp_accessible_label(kind, LinuxEditorStrings.fieldType)
        for item in kinds { gtk_combo_box_text_append_text(mp_combo_box_text(kind), LinuxEditorStrings.fieldKind(item)) }
        gtk_combo_box_set_active(mp_combo_box(kind), Int32(kinds.firstIndex(of: draft.kind) ?? 0))
        field(LinuxEditorStrings.fieldType, kind, in: form)
        GTK.onSignal(kind, "changed") { [weak self] in
            guard let self, kinds.indices.contains(Int(gtk_combo_box_get_active(mp_combo_box(self.kind)))) else { return }
            self.draft.kind = kinds[Int(gtk_combo_box_get_active(mp_combo_box(self.kind)))]
            gtk_widget_set_visible(self.optionsSection, self.draft.kind == .choice ? 1 : 0)
            self.updateValidation()
        }

        for (title, entry, widgetName) in [
            (LinuxEditorStrings.fieldLabel, labelEntry, "field-settings-label"),
            (LinuxEditorStrings.description, descriptionEntry, "field-settings-description"),
        ] {
            gtk_widget_set_name(entry, widgetName)
            mp_accessible_label(entry, title)
            gtk_widget_set_hexpand(entry, 1)
            watch(entry)
            field(title, entry, in: form)
        }
        mp_entry_set_text(labelEntry, draft.label)
        mp_entry_set_text(descriptionEntry, draft.description ?? "")
        GTK.onSignal(labelEntry, "changed") { [weak self] in
            guard let self else { return }
            self.draft.label = String(cString: mp_entry_text(self.labelEntry))
        }
        GTK.onSignal(descriptionEntry, "changed") { [weak self] in
            guard let self else { return }
            let text = String(cString: mp_entry_text(self.descriptionEntry))
            self.draft.description = text.isEmpty ? nil : text
        }

        gtk_widget_set_name(defaultToggle, "field-settings-default-toggle")
        mp_accessible_label(defaultToggle, LinuxEditorStrings.fieldDefault)
        gtk_check_button_set_active(mp_check_button(defaultToggle), draft.defaultValue == nil ? 0 : 1)
        gtk_box_append(mp_box(form), defaultToggle)
        GTK.onSignal(defaultToggle, "toggled") { [weak self] in
            guard let self else { return }
            let active = gtk_check_button_get_active(mp_check_button(self.defaultToggle)) != 0
            self.draft.defaultValue = active ? self.defaultText : nil
            gtk_widget_set_sensitive(self.defaultEntry, active ? 1 : 0)
            self.updateValidation()
        }
        gtk_widget_set_name(defaultEntry, "field-settings-default")
        mp_accessible_label(defaultEntry, LinuxEditorStrings.defaultValue)
        gtk_widget_set_hexpand(defaultEntry, 1)
        gtk_text_view_set_wrap_mode(mp_text_view(defaultEntry), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(mp_text_view(defaultEntry), 0)
        gtk_text_buffer_set_enable_undo(gtk_text_view_get_buffer(mp_text_view(defaultEntry)), 1)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(defaultEntry)), draft.defaultValue ?? "", -1)
        gtk_widget_set_sensitive(defaultEntry, draft.defaultValue == nil ? 0 : 1)
        let defaultScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(mp_scrolled_window(defaultScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(mp_scrolled_window(defaultScroll), 72)
        gtk_scrolled_window_set_child(mp_scrolled_window(defaultScroll), defaultEntry)
        gtk_widget_add_css_class(defaultScroll, "frame")
        gtk_box_append(mp_box(form), defaultScroll)
        GTK.onPreeditChanged(defaultEntry) { [weak self] active in self?.hasPreedit = active }
        GTK.onSignal(UnsafeMutableRawPointer(gtk_text_view_get_buffer(mp_text_view(defaultEntry))!), "changed") { [weak self] in
            guard let self, gtk_check_button_get_active(mp_check_button(self.defaultToggle)) != 0 else { return }
            self.draft.defaultValue = self.defaultText
            self.updateValidation()
        }

        gtk_widget_set_name(optionsSection, "field-settings-options")
        let optionsHeading = GTK.label(LinuxEditorStrings.options)
        gtk_widget_add_css_class(optionsHeading, "heading")
        gtk_label_set_xalign(mp_label(optionsHeading), 0)
        gtk_box_append(mp_box(optionsSection), optionsHeading)
        gtk_widget_set_name(optionRows, "field-settings-option-rows")
        gtk_box_append(mp_box(optionsSection), optionRows)
        let addOption = GTK.button(LinuxEditorStrings.addOption) { [weak self] in
            self?.addOption()
        }
        gtk_widget_set_name(addOption, "field-settings-option-add")
        mp_accessible_label(addOption, LinuxEditorStrings.addOption)
        gtk_widget_set_halign(addOption, GTK_ALIGN_START)
        gtk_box_append(mp_box(optionsSection), addOption)
        gtk_widget_set_visible(optionsSection, draft.kind == .choice ? 1 : 0)
        gtk_box_append(mp_box(form), optionsSection)
        rebuildOptionRows()

        for (toggle, widgetName, active) in [
            (optionalToggle, "field-settings-optional", draft.optional),
            (rememberToggle, "field-settings-remember", draft.remember),
        ] {
            gtk_widget_set_name(toggle, widgetName)
            gtk_check_button_set_active(mp_check_button(toggle), active ? 1 : 0)
            gtk_box_append(mp_box(form), toggle)
        }
        GTK.onSignal(optionalToggle, "toggled") { [weak self] in
            guard let self else { return }
            self.draft.optional = gtk_check_button_get_active(mp_check_button(self.optionalToggle)) != 0
        }
        GTK.onSignal(rememberToggle, "toggled") { [weak self] in
            guard let self else { return }
            self.draft.remember = gtk_check_button_get_active(mp_check_button(self.rememberToggle)) != 0
        }

        gtk_box_append(mp_box(content), scroll)
        gtk_widget_set_name(validation, "field-settings-validation")
        gtk_widget_add_css_class(validation, "dim-label")
        gtk_box_append(mp_box(content), validation)
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let cancel = GTK.button(LinuxEditorStrings.cancel) { [weak self] in self?.finish(nil) }
        gtk_widget_set_name(cancel, "field-settings-cancel")
        mp_accessible_label(cancel, LinuxEditorStrings.cancel)
        gtk_widget_set_name(apply, "field-settings-apply")
        mp_accessible_label(apply, LinuxEditorStrings.apply)
        gtk_widget_add_css_class(apply, "suggested-action")
        GTK.onSignal(apply, "clicked") { [weak self] in self?.applyStaged() }
        gtk_box_append(mp_box(buttons), cancel)
        gtk_box_append(mp_box(buttons), apply)
        gtk_box_append(mp_box(content), buttons)
        gtk_window_set_child(mp_window(window), content)
        updateValidation()
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(labelEntry)
    }

    private func field(_ title: String, _ control: GTK.Widget, in form: GTK.Widget) {
        gtk_box_append(mp_box(form), GTK.label(title))
        gtk_box_append(mp_box(form), control)
    }

    private var defaultText: String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(defaultEntry))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let text = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(text) }
        return String(cString: text)
    }

    /// Native close and programmatic destroy both funnel here; only a user
    /// response may emit, and only once.
    private func finish(_ response: PromptFieldSettings?) {
        guard !isDestroyed, !hasResponded else { return }
        hasResponded = true
        respond?(response)
    }

    private func applyStaged() {
        guard draft.validationIssue == nil else { return }
        finish(draft)
    }

    private func addOption() {
        draft.options.append(PromptFieldOptionSettings(label: "", value: ""))
        rebuildOptionRows()
        updateValidation()
        if let last = optionEntries.last { gtk_widget_grab_focus(last.label) }
    }

    /// Rows map one-to-one to draft.options; edits mutate the projected
    /// options so added rows carry no original index and kept rows retain it.
    private func rebuildOptionRows() {
        optionEntries = []
        while let child = gtk_widget_get_first_child(optionRows) { gtk_box_remove(mp_box(optionRows), child) }
        for index in draft.options.indices {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
            gtk_widget_set_name(row, "field-settings-option-row")
            let label = optionEntry(at: index, name: "field-settings-option-label",
                                    accessible: LinuxEditorStrings.optionLabel, \.label)
            let value = optionEntry(at: index, name: "field-settings-option-value",
                                    accessible: LinuxEditorStrings.optionValue, \.value)
            optionEntries.append((label, value))
            gtk_box_append(mp_box(row), label)
            gtk_box_append(mp_box(row), value)
            let remove = gtk_button_new_from_icon_name("list-remove-symbolic")!
            gtk_widget_set_name(remove, "field-settings-option-remove")
            mp_accessible_label(remove, LinuxEditorStrings.removeOption)
            gtk_widget_set_tooltip_text(remove, LinuxEditorStrings.removeOption)
            GTK.onSignal(remove, "clicked") { [weak self] in
                guard let self, let position = self.optionEntries.firstIndex(where: { $0.label == label }),
                      self.draft.options.indices.contains(position) else { return }
                self.draft.options.remove(at: position)
                self.rebuildOptionRows()
                self.updateValidation()
            }
            gtk_box_append(mp_box(row), remove)
            gtk_box_append(mp_box(optionRows), row)
        }
    }

    private func optionEntry(at index: Int, name: String, accessible: String,
                             _ keyPath: WritableKeyPath<PromptFieldOptionSettings, String>) -> GTK.Widget {
        let entry = gtk_entry_new()!
        gtk_widget_set_name(entry, name)
        mp_accessible_label(entry, accessible)
        gtk_widget_set_hexpand(entry, 1)
        mp_entry_set_text(entry, draft.options[index][keyPath: keyPath])
        watch(entry)
        GTK.onSignal(entry, "changed") { [weak self] in
            guard let self, let position = self.optionEntries.firstIndex(where: { $0.label == entry || $0.value == entry }),
                  self.draft.options.indices.contains(position) else { return }
            self.draft.options[position][keyPath: keyPath] = String(cString: mp_entry_text(entry))
            self.updateValidation()
        }
        return entry
    }

    /// Input-method composition owns Escape until it commits; a single-line
    /// entry's activate applies a valid draft, matching other native dialogs.
    private func watch(_ entry: GTK.Widget) {
        GTK.onSignal(entry, "activate") { [weak self] in self?.applyStaged() }
        guard let delegate = mp_entry_text_delegate(entry) else { return }
        GTK.onPreeditChanged(delegate) { [weak self] active in self?.hasPreedit = active }
    }

    private func updateValidation() {
        let issue = draft.validationIssue
        gtk_widget_set_sensitive(apply, issue == nil ? 1 : 0)
        gtk_label_set_text(mp_label(validation), issue.map(LinuxEditorStrings.fieldIssue) ?? "")
        gtk_widget_set_visible(validation, issue == nil ? 0 : 1)
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        gtk_window_destroy(mp_window(window))
    }
}
#endif
