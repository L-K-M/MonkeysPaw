#if os(Linux)
import CGtk
import MonkeysPawCore

/// A reusable view over General and Shortcuts presentation state.
/// GTK owns the window and children; Swift keeps guarded borrowed pointers.
final class LinuxSettingsWindow {
    private let window: GTK.Widget
    private let general: GeneralSettingsModel
    private let shortcuts: ShortcutsSettingsModel
    private let chooser: LinuxFolderChoosing
    private var isDestroyed = false
    private var isChoosing = false
    private var chooserRevision = 0

    private var libraryPath: GTK.Widget!
    private var libraryDefault: GTK.Widget!
    private var libraryMessage: GTK.Widget!
    private var settingsError: GTK.Widget!
    private var chooseButton: GTK.Widget!
    private var defaultButton: GTK.Widget!
    private var toggleBinding: GTK.Widget!
    private var toggleRegistration: GTK.Widget!
    private var toggleVerification: GTK.Widget!
    private var shortcutInstructions: GTK.Widget!
    private var shortcutError: GTK.Widget!
    private var changeButton: GTK.Widget!
    private var verifyButton: GTK.Widget!
    private var repeatBinding: GTK.Widget!

    private var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, general: GeneralSettingsModel,
         shortcuts: ShortcutsSettingsModel, chooser: LinuxFolderChoosing) {
        self.general = general
        self.shortcuts = shortcuts
        self.chooser = chooser
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.settings)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            self.isDestroyed = true
            self.cancelFolderChoice()
            self.general.onChange = nil
            self.shortcuts.onChange = nil
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isVisible else { return }
            self.cancelFolderChoice()
        }

        let notebook = gtk_notebook_new()!
        gtk_widget_set_name(notebook, "settings-tabs")
        gtk_notebook_append_page(mp_notebook(notebook), generalPage(), GTK.label(LinuxStrings.generalTab))
        gtk_notebook_append_page(mp_notebook(notebook), shortcutsPage(), GTK.label(LinuxStrings.shortcutsTab))
        gtk_window_set_child(mp_window(window), notebook)
        general.onChange = { [weak self] in self?.renderGeneral() }
        shortcuts.onChange = { [weak self] in self?.renderShortcuts() }
        renderGeneral()
        renderShortcuts()
    }

    deinit {
        chooser.cancel()
        general.onChange = nil
        shortcuts.onChange = nil
    }

    func show() {
        guard !isDestroyed else { return }
        general.refresh()
        shortcuts.refresh()
        gtk_window_present(mp_window(window))
    }

    func hide() {
        guard !isDestroyed else { return }
        gtk_widget_set_visible(window, 0)
        cancelFolderChoice()
    }

    private func generalPage() -> GTK.Widget {
        let page = pageBox()
        gtk_box_append(mp_box(page), GTK.label(LinuxStrings.libraryFolder))
        libraryPath = namedLabel("settings-library-path", in: page)
        gtk_label_set_selectable(mp_label(libraryPath), 1)
        gtk_label_set_wrap_mode(mp_label(libraryPath), PANGO_WRAP_WORD_CHAR)
        mp_accessible_label(libraryPath, LinuxStrings.libraryFolder)
        libraryDefault = namedLabel("settings-library-default", in: page)
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        chooseButton = GTK.button(LinuxStrings.chooseFolder) { [weak self] in self?.chooseFolder() }
        gtk_widget_set_name(chooseButton, "settings-choose-folder")
        defaultButton = GTK.button(LinuxStrings.useDefault) { [weak self] in
            guard let self, self.isVisible else { return }
            self.general.useDefaultFolder()
        }
        gtk_widget_set_name(defaultButton, "settings-use-default")
        let reveal = GTK.button(LinuxStrings.openFolder) { [weak self] in
            guard let self, self.isVisible else { return }
            self.general.revealFolder()
        }
        gtk_widget_set_name(reveal, "settings-reveal-folder")
        for button in [chooseButton!, defaultButton!, reveal] { gtk_box_append(mp_box(buttons), button) }
        gtk_box_append(mp_box(page), buttons)
        libraryMessage = namedLabel("settings-library-message", in: page)
        settingsError = namedLabel("settings-general-error", in: page)
        return scrolled(page)
    }

    private func shortcutsPage() -> GTK.Widget {
        let page = pageBox()
        gtk_box_append(mp_box(page), GTK.label(LinuxStrings.togglePicker))
        toggleBinding = namedLabel("settings-toggle-binding", in: page)
        toggleRegistration = namedLabel("settings-toggle-registration", in: page)
        toggleVerification = namedLabel("settings-toggle-verification", in: page)
        shortcutInstructions = namedLabel("settings-shortcut-instructions", in: page)
        shortcutError = namedLabel("settings-shortcut-error", in: page)
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        changeButton = GTK.button("") { [weak self] in
            guard let self, self.isVisible else { return }
            self.shortcuts.performPlatformChange()
        }
        gtk_widget_set_name(changeButton, "settings-change-shortcut")
        verifyButton = GTK.button(LinuxStrings.verifyShortcut) { [weak self] in
            guard let self, self.isVisible else { return }
            self.shortcuts.beginVerification()
        }
        gtk_widget_set_name(verifyButton, "settings-verify-shortcut")
        gtk_box_append(mp_box(buttons), changeButton)
        gtk_box_append(mp_box(buttons), verifyButton)
        gtk_box_append(mp_box(page), buttons)
        gtk_box_append(mp_box(page), GTK.label(LinuxStrings.repeatLast))
        repeatBinding = namedLabel("settings-repeat-binding", in: page)
        gtk_box_append(mp_box(page), GTK.label(LinuxStrings.repeatUnavailable))
        return scrolled(page)
    }

    private func renderGeneral() {
        guard !isDestroyed else { return }
        let state = general.state
        gtk_label_set_text(mp_label(libraryPath), state.activeLibraryPath)
        gtk_label_set_text(mp_label(libraryDefault), state.isDefaultLibrary
            ? LinuxStrings.defaultLibraryFolder : LinuxStrings.customLibraryFolder)
        setMessage(libraryMessage, state.lastSwitchMessage.flatMap(GeneralSettingsStrings.message))
        setMessage(settingsError, state.settingsError.map(GeneralSettingsStrings.settingsError))
        gtk_widget_set_sensitive(defaultButton, state.isDefaultLibrary && state.settingsError == nil ? 0 : 1)
        gtk_widget_set_sensitive(chooseButton, isChoosing ? 0 : 1)
    }

    private func renderShortcuts() {
        guard !isDestroyed else { return }
        let state = shortcuts.togglePicker
        gtk_label_set_text(mp_label(toggleBinding), LinuxStrings.shortcutBinding(state.binding))
        gtk_label_set_text(mp_label(toggleRegistration), LinuxStrings.shortcutRegistration(state.registration))
        gtk_label_set_text(mp_label(toggleVerification), LinuxStrings.shortcutVerification(state.verification))
        gtk_label_set_text(mp_label(repeatBinding), LinuxStrings.shortcutBinding(shortcuts.repeatLast.binding))
        setMessage(shortcutError, shortcuts.error.map(LinuxStrings.shortcutError))

        var instructions = shortcuts.instructions
        let title: String?
        switch state.changePath {
        case .systemSettings: title = LinuxStrings.configureShortcuts
        case .setup: title = LinuxStrings.setupShortcut
        case .systemSettingsGuidance(let text), .manualInstructions(let text):
            instructions = instructions ?? text
            title = LinuxStrings.showInstructions
        // Carbon is the only in-app mechanism. Linux has no recorder.
        case .inApp, .unavailable: title = nil
        }
        gtk_button_set_label(mp_button(changeButton), title ?? "")
        gtk_widget_set_visible(changeButton, title == nil ? 0 : 1)
        setMessage(shortcutInstructions, instructions)
        let canVerify = state.registrationStatus == .registered || state.registrationStatus == .needsAction
        gtk_widget_set_sensitive(verifyButton, canVerify ? 1 : 0)
    }

    private func chooseFolder() {
        guard isVisible, !isChoosing else { return }
        isChoosing = true
        chooserRevision += 1
        let revision = chooserRevision
        renderGeneral()
        chooser.chooseFolder(parent: window, currentPath: general.state.activeLibraryPath) { [weak self] path in
            // An injected chooser may complete off-thread. Retire responses
            // after hide/destroy, including ones queued before cancellation.
            GTK.onMainLoop { [weak self] in
                guard let self, self.isVisible, self.isChoosing, self.chooserRevision == revision else { return }
                self.isChoosing = false
                self.renderGeneral()
                if let path { self.general.chooseFolder(path) }
            }
        }
    }

    private func cancelFolderChoice() {
        chooserRevision += 1
        isChoosing = false
        chooser.cancel()
        if !isDestroyed { renderGeneral() }
    }

    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }

    private func namedLabel(_ name: String, in page: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, name)
        gtk_box_append(mp_box(page), label)
        return label
    }

    private func pageBox() -> GTK.Widget {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(box, 12) }
        return box
    }

    private func scrolled(_ page: GTK.Widget) -> GTK.Widget {
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), page)
        return scroll
    }
}
#endif
