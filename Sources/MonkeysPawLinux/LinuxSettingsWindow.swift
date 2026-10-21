#if os(Linux)
import CGtk
import MonkeysPawCore

/// A reusable view over Settings presentation state.
/// GTK owns the window and children; Swift keeps guarded borrowed pointers.
final class LinuxSettingsWindow {
    enum Page { case current, account }
    private let window: GTK.Widget
    private let stack: GTK.Widget
    private let general: GeneralSettingsModel
    private let shortcuts: ShortcutsSettingsModel
    private let rememberedValues: RememberedValuesSettingsModel
    private let assistant: LinuxAssistantSettingsPage
    private let delivery: LinuxSettingsDeliveryPage
    private let updates: LinuxSettingsUpdatePage
    private let account: LinuxAccountSettingsPage
    private let chooser: LinuxFolderChoosing
    private let openSetup: () -> Void
    private let librarySwitchMessage: () -> String?
    private(set) var isDestroyed = false
    private var isChoosing = false
    private var chooserRevision = 0

    private var libraryPath: GTK.Widget!
    private var libraryDefault: GTK.Widget!
    private var libraryMessage: GTK.Widget!
    private var settingsError: GTK.Widget!
    private var chooseButton: GTK.Widget!
    private var defaultButton: GTK.Widget!
    private var forgetAllButton: GTK.Widget!
    private var forgetConfirmation: GTK.Widget!
    private var forgetCancelButton: GTK.Widget!
    private var forgetMessage: GTK.Widget!
    private struct ShortcutRow {
        let binding: GTK.Widget
        let registration: GTK.Widget
        let verification: GTK.Widget
        let instructions: GTK.Widget
        let error: GTK.Widget
        let change: GTK.Widget
        let verify: GTK.Widget
    }
    private var shortcutRows: [HotkeyAction: ShortcutRow] = [:]

    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, general: GeneralSettingsModel,
         shortcuts: ShortcutsSettingsModel, rememberedValues: RememberedValuesSettingsModel,
         delivery: DeliverySettingsModel, updates: UpdateSettingsModel, session: DesktopSession,
         makeAssistant: @escaping () -> AssistantSettingsModel?,
         chooser: LinuxFolderChoosing, openSetup: @escaping () -> Void,
         librarySwitchMessage: @escaping () -> String? = { nil },
         makeAccount: @escaping () -> AccountModel? = { nil },
         makeInvite: @escaping () -> InviteModel? = { nil },
         makeGroups: @escaping () -> GroupManagementModel? = { nil },
         accountStartupPending: @escaping () -> Bool = { false }) {
        self.general = general
        self.shortcuts = shortcuts
        self.rememberedValues = rememberedValues
        assistant = LinuxAssistantSettingsPage(makeModel: makeAssistant)
        self.delivery = LinuxSettingsDeliveryPage(model: delivery, session: session)
        self.updates = LinuxSettingsUpdatePage(model: updates)
        account = LinuxAccountSettingsPage(makeModel: makeAccount, makeInvite: makeInvite,
            makeGroups: makeGroups, accountStartupPending: accountStartupPending)
        self.chooser = chooser
        self.openSetup = openSetup
        self.librarySwitchMessage = librarySwitchMessage
        window = gtk_application_window_new(application)!
        LinuxStyle.install(on: window)
        stack = gtk_stack_new()!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.settings)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            self.isDestroyed = true
            self.cancelFolderChoice()
            self.rememberedValues.cancelForgetAll()
            self.general.onChange = nil
            self.shortcuts.onChange = nil
            self.rememberedValues.onChange = nil
            self.assistant.retire(.destroyed)
            self.delivery.retire()
            self.updates.retire()
            self.account.retire(.destroyed)
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isDestroyed, !self.isVisible else { return }
            // Both hide() and native close retire here, once per visible lifetime.
            self.cancelFolderChoice()
            self.rememberedValues.cancelForgetAll()
            self.assistant.retire(.hidden)
            self.delivery.hide()
            self.updates.hide()
            self.account.retire(.hidden)
        }

        let headerBar = gtk_header_bar_new()!
        let switcher = gtk_stack_switcher_new()!
        gtk_widget_set_name(switcher, "settings-page-switcher")
        gtk_widget_add_css_class(switcher, "mp-settings-switcher")
        gtk_stack_switcher_set_stack(mp_stack_switcher(switcher), mp_stack(stack))
        mp_accessible_label(switcher, LinuxSettingsStrings.pageSwitcher)
        gtk_header_bar_set_title_widget(mp_header_bar(headerBar), switcher)
        gtk_window_set_titlebar(mp_window(window), headerBar)

        gtk_widget_set_name(stack, "settings-stack")
        gtk_stack_add_titled(mp_stack(stack), generalPage(), "general", LinuxStrings.generalTab)
        gtk_stack_add_titled(mp_stack(stack), shortcutsPage(), "shortcuts", LinuxStrings.shortcutsTab)
        gtk_stack_add_titled(mp_stack(stack), self.delivery.widget, "delivery", DeliverySettingsStrings.title)
        gtk_stack_add_titled(mp_stack(stack), assistant.widget, "assistant", LinuxAssistantSettingsStrings.tab)
        gtk_stack_add_titled(mp_stack(stack), account.widget, "account", LinuxAccountSettingsStrings.tab)
        GTK.onSignal(account.widget, "map") { [weak self] in self?.account.show() }
        GTK.onSignal(account.widget, "unmap") { [weak self] in self?.account.retire(.hidden) }
        gtk_window_set_child(mp_window(window), stack)
        general.onChange = { [weak self] in self?.renderGeneral() }
        shortcuts.onChange = { [weak self] in self?.renderShortcuts() }
        rememberedValues.onChange = { [weak self] in self?.renderRememberedValues() }
        renderGeneral()
        renderShortcuts()
        renderRememberedValues()
    }

    deinit {
        if isChoosing { chooser.cancel() }
        general.onChange = nil
        shortcuts.onChange = nil
        rememberedValues.onChange = nil
        rememberedValues.cancelForgetAll()
        assistant.retire(isDestroyed ? .destroyed : .hidden)
        delivery.hide()
        updates.hide()
        account.retire(isDestroyed ? .destroyed : .hidden)
    }

    func show(page: Page = .current) {
        guard !isDestroyed else { return }
        if page == .account {
            gtk_stack_set_visible_child_name(mp_stack(stack), "account")
        }
        general.refresh()
        renderGeneral()
        shortcuts.refresh()
        assistant.show()
        delivery.show()
        updates.show()
        gtk_window_present(mp_window(window))
    }

    func hide() {
        guard !isDestroyed else { return }
        gtk_widget_set_visible(window, 0)
        cancelFolderChoice()
        rememberedValues.cancelForgetAll()
    }

    func showInvite() {
        guard !isDestroyed else { return }
        gtk_stack_set_visible_child_name(mp_stack(stack), "account")
        show()
        account.show()
    }

    func stageInvite(_ input: inout String) {
        showInvite()
        account.stageInvite(&input)
    }

    // Account follows the replaceable library graph, independently of General.
    func suspendAccount() { account.retire(.hidden) }

    func refreshLibrarySwitchMessage() { renderGeneral() }

    func refreshAccountStartup() { account.refreshStartup() }

    func rebindAccount() {
        guard !isDestroyed else { return }
        account.retire(.hidden)
        if isVisible, gtk_widget_get_mapped(account.widget) != 0 { account.show() }
    }

    private func generalPage() -> GTK.Widget {
        let (page, column) = LinuxSettingsLayout.page(named: "settings-general-page")
        do {
            let library = LinuxSettingsLayout.group(LinuxSettingsStrings.library, in: column)
            let list = LinuxSettingsLayout.list(in: library)
            let row = LinuxSettingsLayout.row(in: list)
            let text = LinuxSettingsLayout.rowText(LinuxStrings.libraryFolder, in: row)
            libraryPath = LinuxSettingsLayout.label("", name: "settings-library-path", emphasis: .secondary, in: text)
            gtk_label_set_selectable(mp_label(libraryPath), 1)
            mp_accessible_label(libraryPath, LinuxStrings.libraryFolder)
            libraryDefault = LinuxSettingsLayout.label("", name: "settings-library-default", emphasis: .secondary, in: text)
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
            gtk_widget_set_valign(chooseButton, GTK_ALIGN_CENTER)
            gtk_box_append(mp_box(row), chooseButton)
            for button in [defaultButton!, reveal] {
                gtk_widget_add_css_class(button, "flat")
                gtk_box_append(mp_box(buttons), button)
            }
            gtk_widget_set_halign(buttons, GTK_ALIGN_END)
            gtk_box_append(mp_box(library), buttons)
            libraryMessage = LinuxSettingsLayout.caption(name: "settings-library-message", in: library)
            settingsError = LinuxSettingsLayout.caption(name: "settings-general-error", in: library)
            gtk_widget_add_css_class(settingsError, "error")

            let remembered = LinuxSettingsLayout.group(LinuxSettingsStrings.rememberedValues, in: column)
            let rememberedList = LinuxSettingsLayout.list(in: remembered)
            let forgetRow = LinuxSettingsLayout.row(in: rememberedList)
            LinuxSettingsLayout.rowText(LinuxSettingsStrings.fieldValues, in: forgetRow)
            forgetAllButton = GTK.button(LinuxStrings.forgetAllValues) { [weak self] in
                guard let self, self.isVisible else { return }
                self.rememberedValues.requestForgetAll()
            }
            gtk_widget_set_name(forgetAllButton, "settings-forget-all")
            mp_accessible_label(forgetAllButton, LinuxStrings.forgetAllValues)
            gtk_widget_set_valign(forgetAllButton, GTK_ALIGN_CENTER)
            gtk_box_append(mp_box(forgetRow), forgetAllButton)
            forgetConfirmation = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
            gtk_widget_set_name(forgetConfirmation, "settings-forget-confirmation")
            let confirmationTitle = GTK.label(RememberedValuesStrings.confirmationTitle)
            gtk_widget_add_css_class(confirmationTitle, "heading")
            gtk_box_append(mp_box(forgetConfirmation), confirmationTitle)
            let confirmationMessage = namedLabel("settings-forget-confirmation-message", in: forgetConfirmation)
            gtk_label_set_text(mp_label(confirmationMessage), RememberedValuesStrings.confirmationMessage)
            let confirmButtons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            let confirm = GTK.button(RememberedValuesStrings.forgetAll) { [weak self] in
                guard let self, self.isVisible else { return }
                self.rememberedValues.confirmForgetAll()
            }
            gtk_widget_set_name(confirm, "settings-confirm-forget-all")
            // GNOME's style for an irreversible confirmation.
            gtk_widget_add_css_class(confirm, "destructive-action")
            mp_accessible_label(confirm, RememberedValuesStrings.forgetAll)
            let cancel = GTK.button(RememberedValuesStrings.cancel) { [weak self] in
                guard let self, self.isVisible else { return }
                self.rememberedValues.cancelForgetAll()
            }
            gtk_widget_set_name(cancel, "settings-cancel-forget-all")
            forgetCancelButton = cancel
            mp_accessible_label(cancel, RememberedValuesStrings.cancel)
            gtk_box_append(mp_box(confirmButtons), cancel)
            gtk_box_append(mp_box(confirmButtons), confirm)
            gtk_box_append(mp_box(forgetConfirmation), confirmButtons)
            gtk_box_append(mp_box(remembered), forgetConfirmation)
            forgetMessage = LinuxSettingsLayout.caption(name: "settings-forget-message", in: remembered)

            gtk_box_append(mp_box(column), updates.widget)
        }
        return page
    }

    private func shortcutsPage() -> GTK.Widget {
        let (page, column) = LinuxSettingsLayout.page(named: "settings-shortcuts-page")
        do {
            for action in HotkeyAction.allCases {
                let isPicker = action == .togglePicker
                let name = isPicker ? "toggle" : "repeat"
                let control = isPicker ? "shortcut" : "repeat-shortcut"
                let group = LinuxSettingsLayout.group(
                    isPicker ? LinuxStrings.togglePicker : LinuxStrings.repeatLast, in: column)
                let list = LinuxSettingsLayout.list(in: group)
                let binding = valueLabel("settings-\(name)-binding", in: list)
                let registration = valueLabel("settings-\(name)-registration", in: list, emphasis: .secondary)
                let verification = valueLabel("settings-\(name)-verification", in: list, emphasis: .secondary)
                let actions = LinuxSettingsLayout.row(in: list)
                LinuxSettingsLayout.rowText(in: actions)
                let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                let change = GTK.button("") { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.shortcuts.performPlatformChange(for: action)
                }
                gtk_widget_set_name(change, "settings-change-\(control)")
                let verify = GTK.button(LinuxStrings.verifyShortcut) { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.shortcuts.beginVerification(action)
                }
                gtk_widget_set_name(verify, "settings-verify-\(control)")
                gtk_box_append(mp_box(buttons), change)
                gtk_box_append(mp_box(buttons), verify)
                gtk_widget_set_valign(buttons, GTK_ALIGN_CENTER)
                gtk_box_append(mp_box(actions), buttons)
                let instructions = LinuxSettingsLayout.caption(
                    name: "settings-\(control)-instructions", in: group)
                let error = LinuxSettingsLayout.caption(name: "settings-\(control)-error", in: group)
                gtk_widget_add_css_class(error, "error")
                shortcutRows[action] = ShortcutRow(binding: binding, registration: registration,
                    verification: verification, instructions: instructions, error: error, change: change, verify: verify)
            }
            let setupButton = GTK.button(LinuxStrings.openSetup) { [weak self] in
                guard let self, self.isVisible else { return }
                self.openSetup()
            }
            gtk_widget_set_name(setupButton, "settings-open-setup")
            gtk_widget_set_halign(setupButton, GTK_ALIGN_START)
            gtk_box_append(mp_box(column), setupButton)
        }
        return page
    }

    private func renderGeneral() {
        guard !isDestroyed else { return }
        let state = general.state
        gtk_label_set_text(mp_label(libraryPath), state.activeLibraryPath)
        gtk_label_set_text(mp_label(libraryDefault), state.isDefaultLibrary
            ? LinuxStrings.defaultLibraryFolder : LinuxStrings.customLibraryFolder)
        let switchMessage: String? = state.lastSwitchMessage.flatMap { outcome in
            if outcome == .deliveryInFlight, let message = librarySwitchMessage() { return message }
            return GeneralSettingsStrings.message(for: outcome)
        }
        setMessage(libraryMessage, switchMessage)
        setMessage(settingsError, state.settingsError.map(GeneralSettingsStrings.settingsError))
        gtk_widget_set_sensitive(defaultButton, state.isDefaultLibrary && state.settingsError == nil ? 0 : 1)
        gtk_widget_set_sensitive(chooseButton, isChoosing ? 0 : 1)
    }

    private func renderShortcuts() {
        guard !isDestroyed else { return }
        for action in HotkeyAction.allCases {
            guard let row = shortcutRows[action] else { continue }
            let state = shortcuts.state(for: action)
            gtk_label_set_text(mp_label(row.binding), LinuxStrings.shortcutBinding(state.binding))
            gtk_label_set_text(mp_label(row.registration), LinuxStrings.shortcutRegistration(state.registration))
            gtk_label_set_text(mp_label(row.verification), LinuxStrings.shortcutVerification(state.verification))
            setMessage(row.error, shortcuts.error(for: action).map(LinuxStrings.shortcutError))

            var instructions = shortcuts.instructions(for: action)
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
            gtk_button_set_label(mp_button(row.change), title ?? "")
            gtk_widget_set_visible(row.change, title == nil ? 0 : 1)
            setMessage(row.instructions, instructions)
            let canVerify = state.registrationStatus == .registered || state.registrationStatus == .needsAction
            gtk_widget_set_sensitive(row.verify, canVerify ? 1 : 0)
        }
    }

    private func renderRememberedValues() {
        guard !isDestroyed else { return }
        let state = rememberedValues.state
        let confirming = state.confirmation == .forgetAll
        let wasConfirming = gtk_widget_get_visible(forgetConfirmation) != 0
        gtk_widget_set_visible(forgetConfirmation, confirming ? 1 : 0)
        gtk_widget_set_sensitive(forgetAllButton, confirming ? 0 : 1)
        // Keyboard and screen-reader users land on the safe choice; focus
        // returns to the trigger once the confirmation closes.
        if confirming, !wasConfirming { gtk_widget_grab_focus(forgetCancelButton) }
        if !confirming, wasConfirming { gtk_widget_grab_focus(forgetAllButton) }
        setMessage(forgetMessage, state.message)
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
        // Settings and onboarding share a chooser. Cancel only our request.
        guard isChoosing else { return }
        chooserRevision += 1
        isChoosing = false
        chooser.cancel()
        if !isDestroyed { renderGeneral() }
    }

    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }

    private func valueLabel(_ name: String, in list: GTK.Widget, emphasis: LinuxSettingsLayout.Emphasis = .normal) -> GTK.Widget {
        let row = LinuxSettingsLayout.row(in: list)
        let text = LinuxSettingsLayout.rowText(in: row)
        return LinuxSettingsLayout.label("", name: name, emphasis: emphasis, in: text)
    }

    private func namedLabel(_ name: String, in page: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, name)
        gtk_box_append(mp_box(page), label)
        return label
    }
}
#endif
