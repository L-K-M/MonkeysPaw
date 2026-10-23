#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GTK owns the widgets. Each Settings window owns one presentation model;
/// only the native password entry holds typed text, never a stored key.
final class LinuxAssistantSettingsPage {
    enum Retirement { case hidden, destroyed }
    let widget: GTK.Widget
    private let makeModel: () -> AssistantSettingsModel?
    private var model: AssistantSettingsModel?
    private var isShown = false
    private var needsRefresh = false
    private var isRendering = false
    private var keyInputReset: UUID?
    private var renderedProfiles: [ProviderProfile] = []
    private var renderedActiveID: ProviderProfileID?
    private var renderedModels: [ModelDescriptor] = []
    private var pendingInputs: [GTK.Widget: UUID] = [:]

    private let profiles: GTK.Widget
    private let activeProfile: GTK.Widget
    private let draftMessage: GTK.Widget
    private let editor: GTK.Widget
    private let name: GTK.Widget
    private let kind: GTK.Widget
    private let baseURL: GTK.Widget
    private let modelID: GTK.Widget
    private let modelPicker: GTK.Widget
    private let key: GTK.Widget
    private let keyEdit: GTK.Widget
    private let storage: GTK.Widget
    private let storageWarning: GTK.Widget
    private let progress: GTK.Widget
    private let error: GTK.Widget
    private let testResult: GTK.Widget
    private var add: GTK.Widget!
    private var delete: GTK.Widget!
    private var disable: GTK.Widget!
    private var activate: GTK.Widget!
    private var keepKey: GTK.Widget!
    private var clearKey: GTK.Widget!
    private var save: GTK.Widget!
    private var test: GTK.Widget!
    private var cancelTest: GTK.Widget!
    private var refresh: GTK.Widget!
    private var syncSection: GTK.Widget!
    private var syncStatus: GTK.Widget!
    private var syncNotice: GTK.Widget!
    private var syncReveal: GTK.Widget!
    private var syncEntry: GTK.Widget!
    private var syncGenerate: GTK.Widget!
    private var syncEnter: GTK.Widget!
    private var syncRemove: GTK.Widget!
    private var syncDismissReveal: GTK.Widget!

    init(makeModel: @escaping () -> AssistantSettingsModel?) {
        self.makeModel = makeModel
        let (scroll, column) = LinuxSettingsLayout.page(named: "settings-assistant-page")
        widget = scroll

        let profilesGroup = LinuxSettingsLayout.group(LinuxAssistantSettingsStrings.profiles, in: column)
        profiles = gtk_list_box_new()!
        gtk_widget_set_name(profiles, "settings-assistant-profiles")
        gtk_list_box_set_selection_mode(mp_list_box(profiles), GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(profiles, "boxed-list")
        mp_accessible_label(profiles, LinuxAssistantSettingsStrings.profiles)
        let profileScroll = gtk_scrolled_window_new()!
        gtk_widget_set_size_request(profileScroll, -1, 100)
        gtk_scrolled_window_set_child(mp_scrolled_window(profileScroll), profiles)
        gtk_box_append(mp_box(profilesGroup), profileScroll)
        let profileButtons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(profilesGroup), profileButtons)
        activeProfile = LinuxSettingsLayout.caption(name: "settings-assistant-active", in: profilesGroup)
        draftMessage = LinuxSettingsLayout.caption(name: "settings-assistant-draft-message", in: profilesGroup)

        editor = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        gtk_box_append(mp_box(column), editor)
        let editorHeading = GTK.label(LinuxSettingsStrings.profileDetails)
        gtk_widget_add_css_class(editorHeading, "heading")
        gtk_box_append(mp_box(editor), editorHeading)
        let editorList = LinuxSettingsLayout.list(in: editor)
        name = Self.entryRow("settings-assistant-name", title: LinuxAssistantSettingsStrings.name, in: editorList)
        let kindRow = LinuxSettingsLayout.row(in: editorList)
        LinuxSettingsLayout.rowText(LinuxAssistantSettingsStrings.kind, in: kindRow)
        kind = gtk_combo_box_text_new()!
        gtk_widget_set_name(kind, "settings-assistant-kind")
        mp_accessible_label(kind, LinuxAssistantSettingsStrings.kind)
        for title in [LinuxAssistantSettingsStrings.anthropic, LinuxAssistantSettingsStrings.compatible] {
            gtk_combo_box_text_append_text(mp_combo_box_text(kind), title)
        }
        gtk_widget_set_valign(kind, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(kindRow), kind)
        baseURL = Self.entryRow("settings-assistant-base-url", title: LinuxAssistantSettingsStrings.baseURL, in: editorList)
        modelID = Self.entryRow("settings-assistant-model-id", title: LinuxAssistantSettingsStrings.modelID, in: editorList)
        let modelRow = LinuxSettingsLayout.row(in: editorList)
        LinuxSettingsLayout.rowText(LinuxAssistantSettingsStrings.chooseModel, in: modelRow)
        modelPicker = gtk_combo_box_text_new()!
        gtk_combo_box_text_append_text(mp_combo_box_text(modelPicker), LinuxAssistantSettingsStrings.chooseModel)
        gtk_widget_set_name(modelPicker, "settings-assistant-model-picker")
        mp_accessible_label(modelPicker, LinuxAssistantSettingsStrings.chooseModel)
        gtk_widget_set_valign(modelPicker, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(modelRow), modelPicker)
        key = Self.entryRow("settings-assistant-key", title: LinuxAssistantSettingsStrings.key, in: editorList)
        gtk_entry_set_visibility(mp_entry(key), 0)
        gtk_entry_set_input_purpose(mp_entry(key), GTK_INPUT_PURPOSE_PASSWORD)
        gtk_entry_set_placeholder_text(mp_entry(key), LinuxAssistantSettingsStrings.keyPlaceholder)
        LinuxSettingsLayout.caption(LinuxAssistantSettingsStrings.manualModel, in: editor)
        let keyButtons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(editor), keyButtons)
        keyEdit = LinuxSettingsLayout.caption(name: "settings-assistant-key-edit", in: editor)
        storage = LinuxSettingsLayout.caption(name: "settings-assistant-storage", in: column)
        storageWarning = LinuxSettingsLayout.caption(name: "settings-assistant-storage-warning", in: column)
        gtk_widget_add_css_class(storageWarning, "error")
        mp_accessible_label(storageWarning, LinuxAssistantSettingsStrings.unencrypted)
        LinuxSettingsLayout.caption(LinuxAssistantSettingsStrings.outbound, in: column)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(column), actions)
        progress = LinuxSettingsLayout.caption(name: "settings-assistant-progress", in: column)
        error = LinuxSettingsLayout.caption(name: "settings-assistant-error", in: column)
        gtk_widget_add_css_class(error, "error")
        testResult = LinuxSettingsLayout.caption(name: "settings-assistant-test-result", in: column)

        add = button("settings-assistant-add", title: LinuxAssistantSettingsStrings.add, in: profileButtons) { $0.addProfile() }
        delete = button("settings-assistant-delete", title: LinuxAssistantSettingsStrings.delete, in: profileButtons) {
            if let id = $0.state.draft?.id { $0.deleteProfile(id) }
        }
        disable = button("settings-assistant-disable", title: LinuxAssistantSettingsStrings.disable, in: profileButtons) {
            Self.selectProfile(nil, in: $0)
        }
        activate = button("settings-assistant-activate", title: LinuxAssistantSettingsStrings.makeActive, in: profileButtons) {
            Self.selectProfile($0.state.draft?.id, in: $0)
        }
        keepKey = button("settings-assistant-keep-key", title: LinuxAssistantSettingsStrings.keepKey, in: keyButtons) { $0.keepKey() }
        clearKey = button("settings-assistant-clear-key", title: LinuxAssistantSettingsStrings.clearKey, in: keyButtons) { $0.clearKey() }
        save = button("settings-assistant-save", title: LinuxAssistantSettingsStrings.save, in: actions) { $0.save() }
        test = button("settings-assistant-test", title: LinuxAssistantSettingsStrings.test, in: actions) { $0.testConnection() }
        cancelTest = button("settings-assistant-cancel-test", title: LinuxAssistantSettingsStrings.cancelTest, in: actions) { $0.cancelTest() }
        refresh = button("settings-assistant-refresh", title: LinuxAssistantSettingsStrings.refresh, in: column) { $0.refresh() }
        gtk_widget_set_halign(refresh, GTK_ALIGN_START)

        let syncGroup = LinuxSettingsLayout.group(LinuxAssistantSettingsStrings.syncGroup, in: column)
        syncSection = syncGroup
        syncStatus = LinuxSettingsLayout.caption(name: "settings-assistant-sync-status", in: syncGroup)
        syncNotice = LinuxSettingsLayout.caption(name: "settings-assistant-sync-notice", in: syncGroup)
        gtk_widget_add_css_class(syncNotice, "error")
        syncReveal = gtk_label_new(nil)!
        gtk_widget_set_name(syncReveal, "settings-assistant-sync-reveal")
        gtk_label_set_selectable(mp_label(syncReveal), 1)
        gtk_label_set_wrap(mp_label(syncReveal), 1)
        gtk_widget_set_visible(syncReveal, 0)
        gtk_box_append(mp_box(syncGroup), syncReveal)
        let syncList = LinuxSettingsLayout.list(in: syncGroup)
        syncEntry = Self.entryRow("settings-assistant-sync-entry",
            title: LinuxAssistantSettingsStrings.syncKeyField, in: syncList)
        gtk_entry_set_visibility(mp_entry(syncEntry), 0)
        gtk_entry_set_input_purpose(mp_entry(syncEntry), GTK_INPUT_PURPOSE_PASSWORD)
        gtk_entry_set_placeholder_text(mp_entry(syncEntry), LinuxAssistantSettingsStrings.syncEntryPlaceholder)
        let syncButtons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(syncGroup), syncButtons)
        syncGenerate = GTK.button(LinuxAssistantSettingsStrings.syncGenerate) { [weak self] in
            self?.model?.syncKey?.generate()
        }
        gtk_widget_set_name(syncGenerate, "settings-assistant-sync-generate")
        mp_accessible_label(syncGenerate, LinuxAssistantSettingsStrings.syncGenerate)
        gtk_box_append(mp_box(syncButtons), syncGenerate)
        syncEnter = GTK.button(LinuxAssistantSettingsStrings.syncEnter) { [weak self] in
            guard let self else { return }
            let text = String(cString: mp_entry_text(self.syncEntry))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mp_entry_set_text(self.syncEntry, "")
            self.model?.syncKey?.enterKey(text)
        }
        gtk_widget_set_name(syncEnter, "settings-assistant-sync-enter")
        mp_accessible_label(syncEnter, LinuxAssistantSettingsStrings.syncEnter)
        gtk_box_append(mp_box(syncButtons), syncEnter)
        syncRemove = GTK.button(LinuxAssistantSettingsStrings.syncRemove) { [weak self] in
            self?.model?.syncKey?.remove()
        }
        gtk_widget_set_name(syncRemove, "settings-assistant-sync-remove")
        mp_accessible_label(syncRemove, LinuxAssistantSettingsStrings.syncRemove)
        gtk_box_append(mp_box(syncButtons), syncRemove)
        syncDismissReveal = GTK.button(LinuxAssistantSettingsStrings.syncDismissReveal) { [weak self] in
            self?.model?.syncKey?.dismissRevealed()
        }
        gtk_widget_set_name(syncDismissReveal, "settings-assistant-sync-dismiss")
        mp_accessible_label(syncDismissReveal, LinuxAssistantSettingsStrings.syncDismissReveal)
        gtk_box_append(mp_box(syncButtons), syncDismissReveal)

        GTK.onRow(profiles, "row-selected") { [weak self] index in
            guard let self, !self.isRendering, self.canChangeProfiles, let index,
                  self.renderedProfiles.indices.contains(index) else { return }
            if let model = self.model { Self.selectProfile(self.renderedProfiles[index].id, in: model) }
        }
        onInput(name) { $0.renameProfile($1) }
        onInput(baseURL) { $0.setBaseURL($1) }
        onInput(modelID) { $0.setModelID($1) }
        onInput(key) { $0.setKeyInput($1) }
        GTK.onSignal(kind, "changed") { [weak self] in
            guard let self, !self.isRendering, self.canEditDraft else { return }
            self.model?.setKind(gtk_combo_box_get_active(mp_combo_box(self.kind)) == 0 ? .anthropic : .openaiCompatible)
        }
        GTK.onSignal(modelPicker, "changed") { [weak self] in
            guard let self, !self.isRendering, self.canEditDraft else { return }
            let index = Int(gtk_combo_box_get_active(mp_combo_box(self.modelPicker))) - 1
            guard self.renderedModels.indices.contains(index) else { return }
            self.model?.setModelID(self.renderedModels[index].id)
        }
        render()
    }

    deinit {
        model?.onChange = nil
        model?.cancelTest()
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        if model == nil { model = makeModel() }
        else { needsRefresh = true }
        model?.onChange = { [weak self] in
            self?.refreshIfNeeded()
            self?.render()
        }
        model?.syncKey?.onChange = { [weak self] in self?.render() }
        refreshIfNeeded()
        render()
    }

    /// Accepted saves can finish on their worker; retired callbacks cannot touch GTK.
    func retire(_ reason: Retirement) {
        guard isShown || reason == .destroyed else { return }
        isShown = false
        model?.onChange = nil
        model?.syncKey?.onChange = nil
        model?.cancelTest()
        model?.keepKey()
        mp_entry_set_text(syncEntry, "")
        keyInputReset = nil
        pendingInputs.removeAll()
        if reason == .destroyed {
            model = nil
        } else {
            needsRefresh = true
            render()
        }
    }

    private func refreshIfNeeded() {
        guard isShown, needsRefresh, let model, model.state.operation == nil else { return }
        needsRefresh = false
        model.refresh()
    }

    private var canChangeProfiles: Bool {
        guard isShown, let state = model?.state else { return false }
        return state.operation == nil && !state.isReadOnly
    }

    private var canEditDraft: Bool {
        guard isShown, let state = model?.state else { return false }
        return state.draft != nil && !state.isReadOnly && (state.operation == nil || state.operation == .saving)
    }

    private static func selectProfile(_ id: ProviderProfileID?, in model: AssistantSettingsModel) {
        // Refresh still discards staged edits without reporting a provider mutation.
        if id == model.state.selectedProfileID { model.refresh() }
        else { model.selectProfile(id) }
    }

    private func render() {
        isRendering = true
        defer { isRendering = false }
        let state = isShown ? model?.state : nil
        let draft = state?.draft
        if draft == nil || !canEditDraft, let root = gtk_widget_get_root(widget),
           let focus = gtk_root_get_focus(root), gtk_widget_is_ancestor(focus, editor) != 0 {
            // GTK 4.8 loses GtkText's focus-out if its page is hidden/disabled first.
            gtk_root_set_focus(root, nil)
        }
        let savedProfiles = state?.profiles ?? []
        if savedProfiles != renderedProfiles || state?.selectedProfileID != renderedActiveID {
            while let child = gtk_widget_get_first_child(profiles) { gtk_list_box_remove(mp_list_box(profiles), child) }
            renderedProfiles = savedProfiles
            renderedActiveID = state?.selectedProfileID
            for profile in savedProfiles {
                gtk_list_box_append(mp_list_box(profiles), GTK.label(LinuxAssistantSettingsStrings.profileRow(
                    profile.displayName, isActive: profile.id == state?.selectedProfileID)))
            }
        }
        let selectedIndex = savedProfiles.firstIndex { $0.id == draft?.id }
        gtk_list_box_select_row(mp_list_box(profiles), selectedIndex.flatMap {
            gtk_list_box_get_row_at_index(mp_list_box(profiles), Int32($0))
        })
        let active = savedProfiles.first { $0.id == state?.selectedProfileID }
        setMessage(activeProfile, active.map { LinuxAssistantSettingsStrings.activeProfile($0.displayName) }
            ?? LinuxAssistantSettingsStrings.inactive)
        setMessage(draftMessage, state?.isNewProfile == true ? LinuxAssistantSettingsStrings.newProfile
            : (draft == nil && state?.operation == nil ? LinuxAssistantSettingsStrings.empty : nil))
        gtk_widget_set_visible(editor, draft == nil ? 0 : 1)
        setEntry(name, draft?.displayName ?? "")
        setEntry(baseURL, draft?.baseURL ?? "")
        setEntry(modelID, draft?.modelID ?? "")
        gtk_combo_box_set_active(mp_combo_box(kind), draft?.kind == .openaiCompatible ? 1 : 0)
        // Reset emits "changed" synchronously. Suppression preserves staged Clear.
        if state == nil || keyInputReset != state?.keyInputReset {
            keyInputReset = state?.keyInputReset
            mp_entry_set_text(key, "")
        }
        let models = state?.availableModels ?? []
        if !models.elementsEqual(renderedModels, by: { left, right in
            left.id.utf8.elementsEqual(right.id.utf8)
                && left.displayName.map { Data($0.utf8) } == right.displayName.map { Data($0.utf8) }
        }) {
            renderedModels = models
            gtk_combo_box_text_remove_all(mp_combo_box_text(modelPicker))
            gtk_combo_box_text_append_text(mp_combo_box_text(modelPicker), LinuxAssistantSettingsStrings.chooseModel)
            for model in models { gtk_combo_box_text_append_text(mp_combo_box_text(modelPicker), LinuxAssistantSettingsStrings.modelLabel(model)) }
        }
        let modelIndex = models.firstIndex { $0.id.utf8.elementsEqual((draft?.modelID ?? "").utf8) }
        gtk_combo_box_set_active(mp_combo_box(modelPicker), modelIndex.map { Int32($0 + 1) } ?? 0)
        setMessage(keyEdit, state.map { LinuxAssistantSettingsStrings.keyEdit($0.keyEdit) })
        setMessage(storage, state.map { LinuxAssistantSettingsStrings.storage($0.keyStorage) })
        setMessage(storageWarning, state?.keyStorage.tier == .file ? LinuxAssistantSettingsStrings.unencrypted : nil)
        let progressMessage = state?.operation.map(LinuxAssistantSettingsStrings.progress)
            ?? (state?.isTesting == true ? LinuxAssistantSettingsStrings.testing : nil)
        setMessage(progress, progressMessage)
        var failures = [state?.readOnlyError, state?.error].compactMap { $0 }
        if case .failed(let failure) = state?.keyStorage { failures.append(failure) }
        let messages = failures.map(LinuxAssistantSettingsStrings.settingsError).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        setMessage(error, messages.isEmpty ? nil : messages.joined(separator: "\n"))
        setMessage(testResult, state?.testResult.map(LinuxAssistantSettingsStrings.testResult))

        let sync = model?.syncKey
        gtk_widget_set_visible(syncSection, isShown && sync != nil ? 1 : 0)
        if let keyState = sync?.state {
            setMessage(syncStatus, LinuxAssistantSettingsStrings.syncStatus(keyState.status))
            setMessage(syncNotice, keyState.notice.map(LinuxAssistantSettingsStrings.syncNotice))
            gtk_label_set_text(mp_label(syncReveal), keyState.revealedKey.map {
                LinuxAssistantSettingsStrings.syncReveal + "\n" + $0
            } ?? "")
            gtk_widget_set_visible(syncReveal, keyState.revealedKey != nil ? 1 : 0)
            let busy = keyState.busy
            gtk_widget_set_sensitive(syncGenerate, !busy ? 1 : 0)
            gtk_widget_set_sensitive(syncEnter, !busy ? 1 : 0)
            gtk_widget_set_sensitive(syncEntry, !busy ? 1 : 0)
            gtk_widget_set_sensitive(syncRemove, !busy && keyState.status != .noAccount
                && keyState.status != .missing ? 1 : 0)
            gtk_widget_set_sensitive(syncDismissReveal, keyState.revealedKey != nil ? 1 : 0)
        }

        for control in [profiles, add!, disable!] { gtk_widget_set_sensitive(control, canChangeProfiles ? 1 : 0) }
        gtk_widget_set_sensitive(delete, canChangeProfiles && draft != nil ? 1 : 0)
        gtk_widget_set_sensitive(editor, canEditDraft ? 1 : 0)
        gtk_widget_set_sensitive(modelPicker, canEditDraft && !models.isEmpty ? 1 : 0)
        gtk_widget_set_visible(activate, selectedIndex != nil && draft?.id != state?.selectedProfileID ? 1 : 0)
        gtk_widget_set_sensitive(activate, canChangeProfiles ? 1 : 0)
        let canSave = canChangeProfiles && draft != nil
        gtk_widget_set_sensitive(save, canSave ? 1 : 0)
        gtk_widget_set_sensitive(test, canSave && state?.isTesting != true ? 1 : 0)
        gtk_widget_set_visible(cancelTest, state?.isTesting == true ? 1 : 0)
        gtk_widget_set_sensitive(refresh, state != nil && state?.operation == nil ? 1 : 0)
    }

    private func button(_ name: String, title: String, in box: GTK.Widget,
                        intent: @escaping (AssistantSettingsModel) -> Void) -> GTK.Widget {
        let button = GTK.button(title) { [weak self] in
            guard let self, self.isShown, let model = self.model else { return }
            intent(model)
        }
        gtk_widget_set_name(button, name)
        mp_accessible_label(button, title)
        gtk_box_append(mp_box(box), button)
        return button
    }

    private func onInput(_ entry: GTK.Widget, intent: @escaping (AssistantSettingsModel, String) -> Void) {
        GTK.onSignal(entry, "changed") { [weak self] in
            guard let self, !self.isRendering, self.canEditDraft, let model = self.model else { return }
            // Password resets follow the model's explicit commit/discard token.
            guard entry != self.key else {
                intent(model, String(cString: mp_entry_text(entry)))
                return
            }
            let revision = UUID()
            self.pendingInputs[entry] = revision
            intent(model, String(cString: mp_entry_text(entry)))
            // Model intents hop through GLib. Preserve native text until this
            // field's newest intent has run, even across unrelated publications.
            GTK.onMainLoop { [weak self, weak model] in
                guard let self, let model, self.model === model,
                      self.pendingInputs[entry] == revision else { return }
                self.pendingInputs[entry] = nil
                self.render()
            }
        }
    }

    private func setEntry(_ entry: GTK.Widget, _ text: String) {
        guard pendingInputs[entry] == nil else { return }
        guard !String(cString: mp_entry_text(entry)).utf8.elementsEqual(text.utf8) else { return }
        mp_entry_set_text(entry, text)
    }

    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }

    private static func entryRow(_ name: String, title: String, in list: GTK.Widget) -> GTK.Widget {
        let row = LinuxSettingsLayout.row(in: list)
        LinuxSettingsLayout.rowText(title, in: row)
        let entry = gtk_entry_new()!
        gtk_widget_set_name(entry, name)
        mp_accessible_label(entry, title)
        gtk_widget_set_hexpand(entry, 1)
        gtk_widget_set_valign(entry, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(row), entry)
        return entry
    }
}
#endif
