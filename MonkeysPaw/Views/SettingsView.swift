import MonkeysPawCore
import SwiftUI

/// Each model's view hook has one owner; independent service observers survive.
final class SettingsViewState: ObservableObject {
    enum Tab: Int, CaseIterable { case general, shortcuts, delivery, assistant, account }
    @Published var selectedTab: Tab = .general {
        didSet {
            updateAccountVisibility()
            if selectedTab != oldValue {
                if selectedTab == .assistant { assistant?.refreshSyncKey() }
                onSelectedTabChange?(selectedTab)
            }
        }
    }
    @Published private(set) var general: GeneralSettingsModel.State
    @Published private(set) var togglePicker: ShortcutsSettingsModel.ActionState
    @Published private(set) var repeatLast: ShortcutsSettingsModel.ActionState
    @Published private var shortcutErrors: [HotkeyAction: ShortcutRebindError] = [:]
    @Published private var actionInstructions: [HotkeyAction: String] = [:]
    @Published private var captureErrors: [HotkeyAction: ShortcutRebindError] = [:]
    @Published private(set) var rememberedValues: RememberedValuesSettingsModel.State
    @Published private(set) var assistant: AssistantSettingsViewState? = nil
    @Published var isChoosingFolder = false
    let generalModel: GeneralSettingsModel
    let shortcutsModel: ShortcutsSettingsModel
    let rememberedValuesModel: RememberedValuesSettingsModel
    let delivery: DeliverySettingsViewState
    let updates: UpdateSettingsViewState
    let account: AccountSettingsViewState
    var onChooseFolder: (() -> Void)?
    var onRememberedValuesChange: (() -> Void)?
    var onSelectedTabChange: ((Tab) -> Void)?
    /// An installed override may return nil to hide a resolved busy outcome.
    var librarySwitchMessage: (() -> String?)?
    private let openSetup: () -> Void
    @Published private var windowIsVisible = false

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         rememberedValues: RememberedValuesSettingsModel,
         delivery: DeliverySettingsModel, updates: UpdateSettingsModel,
         mainThread: MainThread, openSetup: @escaping () -> Void,
         makeAccount: @escaping () -> AccountModel? = { nil }, onAccountOpen: @escaping () -> Void = {},
         makeInvite: @escaping () -> InviteModel? = { nil },
         makeGroups: @escaping () -> GroupManagementModel? = { nil }) {
        generalModel = general
        shortcutsModel = shortcuts
        rememberedValuesModel = rememberedValues
        self.rememberedValues = rememberedValues.state
        self.openSetup = openSetup
        self.delivery = DeliverySettingsViewState(model: delivery, mainThread: mainThread)
        self.updates = UpdateSettingsViewState(model: updates, mainThread: mainThread)
        account = AccountSettingsViewState(mainThread: mainThread, makeModel: makeAccount,
            onOpen: onAccountOpen, makeInvite: makeInvite, makeGroups: makeGroups)
        self.general = general.state
        togglePicker = shortcuts.togglePicker
        repeatLast = shortcuts.repeatLast
        updateShortcuts()
        general.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.general = self.generalModel.state
                self.account.refreshBinding()
            }
        }
        shortcuts.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.updateShortcuts()
            }
        }
        rememberedValues.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.rememberedValues = self.rememberedValuesModel.state
                self.onRememberedValuesChange?()
            }
        }
    }

    private func updateShortcuts() {
        togglePicker = shortcutsModel.togglePicker
        repeatLast = shortcutsModel.repeatLast
        shortcutErrors = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.compactMap { action in
            shortcutsModel.error(for: action).map { (action, $0) }
        })
        actionInstructions = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.compactMap { action in
            shortcutsModel.instructions(for: action).map { (action, $0) }
        })
    }

    var shortcutError: ShortcutRebindError? { shortcutErrors[.togglePicker] }
    var shortcutInstructions: String? { instructions(for: .togglePicker) }
    var captureError: ShortcutRebindError? { captureErrors[.togglePicker] }

    func state(for action: HotkeyAction) -> ShortcutsSettingsModel.ActionState {
        action == .togglePicker ? togglePicker : repeatLast
    }

    func instructions(for action: HotkeyAction) -> String? { actionInstructions[action] }

    var canUseDefault: Bool { !general.isDefaultLibrary || general.settingsError != nil }
    var canEditCreepy: Bool { windowIsVisible && !general.isReadOnly }

    var generalMessages: [String] {
        let outcome = general.lastSwitchMessage
        let switchMessage = outcome.flatMap { state in
            if state == .deliveryInFlight, let librarySwitchMessage { return librarySwitchMessage() }
            return GeneralSettingsStrings.message(for: state)
        }
        return Self.generalMessages(for: outcome, switchMessage: switchMessage,
            settingsError: general.settingsError)
    }

    /// Only failure outcomes belong in General's red message list. A missing
    /// switch mapping must not hide a settings error; mapped save failures
    /// already include it and avoid duplicate copy.
    static func generalMessages(for outcome: LibrarySwitchOutcome?, switchMessage: String?,
                                settingsError: SettingsError?) -> [String] {
        var messages: [String] = []
        if let outcome, outcome != .switched, let message = switchMessage {
            messages.append(message)
            if case .settingsNotSaved = outcome { return messages }
        }
        if let error = settingsError { messages.append(GeneralSettingsStrings.settingsError(error)) }
        return messages
    }

    var displayedShortcutError: String? {
        displayedShortcutError(for: .togglePicker)
    }

    func displayedShortcutError(for action: HotkeyAction) -> String? {
        (captureErrors[action] ?? shortcutErrors[action]).map(Strings.shortcutError)
    }

    var canVerifyShortcut: Bool {
        canVerifyShortcut(.togglePicker)
    }

    func canVerifyShortcut(_ action: HotkeyAction) -> Bool {
        let status = state(for: action).registrationStatus
        return status == .registered || status == .needsAction
    }

    func canClearShortcut(_ action: HotkeyAction) -> Bool {
        state(for: action).changePath == .inApp && state(for: action).binding != .unbound
    }

    func refresh() {
        generalModel.refresh()
        shortcutsModel.refresh()
    }

    func openAssistant(_ model: AssistantSettingsModel, mainThread: MainThread,
                       onProviderChange: @escaping () -> Void = {}) {
        assistant = AssistantSettingsViewState(model: model, mainThread: mainThread, onProviderChange: onProviderChange)
    }

    func retireAssistant() {
        assistant?.retire()
        assistant = nil
    }

    func windowShown() {
        if !windowIsVisible {
            assistant?.refreshSyncKey()
            windowIsVisible = true
        }
        updateAccountVisibility()
    }

    func windowHidden() {
        if windowIsVisible { windowIsVisible = false }
        account.hide()
    }

    func updateAccountVisibility() {
        if windowIsVisible, selectedTab == .account { account.show() }
        else { account.hide() }
    }

    func chooseFolder() { onChooseFolder?() }
    func useDefaultFolder() { generalModel.useDefaultFolder() }
    func revealFolder() { generalModel.revealFolder() }
    func setCreepy(_ enabled: Bool) {
        guard canEditCreepy else { return }
        generalModel.setCreepy(enabled ? .enabled : .disabled)
        general = generalModel.state
    }
    func requestForgetAll() { rememberedValuesModel.requestForgetAll() }
    func confirmForgetAll() { rememberedValuesModel.confirmForgetAll() }
    func cancelForgetAll() { rememberedValuesModel.cancelForgetAll() }
    func beginVerification() { beginVerification(.togglePicker) }
    func beginVerification(_ action: HotkeyAction) { shortcutsModel.beginVerification(action) }
    func performPlatformChange() { performPlatformChange(for: .togglePicker) }
    func performPlatformChange(for action: HotkeyAction) { shortcutsModel.performPlatformChange(for: action) }
    func showSetup() { openSetup() }

    func setAccelerator(_ text: String) {
        setAccelerator(text, for: .togglePicker)
    }

    func setAccelerator(_ text: String, for action: HotkeyAction) {
        captureErrors.removeValue(forKey: action)
        shortcutsModel.setAccelerator(text, for: action)
    }

    func clearShortcut(_ action: HotkeyAction) {
        captureErrors.removeValue(forKey: action)
        shortcutsModel.clear(action)
    }

    func captureFailed(_ error: ShortcutRebindError) { captureFailed(error, for: .togglePicker) }
    func captureFailed(_ error: ShortcutRebindError, for action: HotkeyAction) { captureErrors[action] = error }
}

struct SettingsView: View {
    @ObservedObject var presentation: SettingsViewState
    let pane: SettingsViewState.Tab

    @ViewBuilder
    var body: some View {
        switch pane {
        case .general: general
        case .shortcuts: shortcuts
        case .delivery:
            SettingsDeliveryView(presentation: presentation.delivery)
        case .assistant:
            if let assistant = presentation.assistant {
                SettingsAssistantView(presentation: assistant)
            } else {
                ProgressView(SettingsAssistantStrings.progress(.loading))
            }
        case .account:
            SettingsAccountView(presentation: presentation.account)
        }
    }

    private var general: some View {
        Form {
            libraryFolder
            creepy
            Section {
                Text(Strings.rememberedValuesExplanation)
                Button(Strings.forgetAllValues, action: presentation.requestForgetAll)
                    .disabled(presentation.isChoosingFolder || presentation.rememberedValues.confirmation != .none)
                    .accessibilityLabel(Strings.forgetAllValues)
                    .accessibilityIdentifier("settings-forget-all")
                if let message = presentation.rememberedValues.message {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                        .accessibilityIdentifier("settings-forget-message")
                }
            } header: {
                Text(Strings.rememberedValues)
            }
            SettingsUpdateView(presentation: presentation.updates)
        }
        .formStyle(.grouped)
    }

    private var libraryFolder: some View {
        Section {
            LabeledContent(Strings.libraryLocation) {
                Label(presentation.general.activeLibraryPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(presentation.general.activeLibraryPath)
                    .accessibilityLabel(Strings.libraryFolder)
                    .accessibilityValue(presentation.general.activeLibraryPath)
            }
            HStack {
                Button(Strings.chooseFolder, action: presentation.chooseFolder)
                    .disabled(presentation.isChoosingFolder)
                Button(Strings.useDefaultFolder, action: presentation.useDefaultFolder)
                    .disabled(!presentation.canUseDefault)
                Button(Strings.showInFinder, action: presentation.revealFolder)
            }
            ForEach(presentation.generalMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(Strings.libraryFolder)
        } footer: {
            Text(presentation.general.isDefaultLibrary ? Strings.defaultLibraryFolder : Strings.chosenLibraryFolder)
        }
    }

    private var creepy: some View {
        Section {
            Toggle(GeneralSettingsStrings.creepy, isOn: Binding(
                get: { presentation.general.creepy == .enabled },
                set: presentation.setCreepy))
                .disabled(!presentation.canEditCreepy)
                .help(GeneralSettingsStrings.creepyHelp)
                .accessibilityLabel(GeneralSettingsStrings.creepy)
                .accessibilityIdentifier("settings-creepy")
        } footer: {
            Text(GeneralSettingsStrings.creepyHelp)
        }
    }

    private var shortcuts: some View {
        Form {
            ShortcutSettingsRow(presentation: presentation, action: .togglePicker)
            ShortcutSettingsRow(presentation: presentation, action: .repeatLast)
            Section {
                Button(Strings.openSetup) { presentation.showSetup() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettingsRow: View {
    @ObservedObject var presentation: SettingsViewState
    let action: HotkeyAction

    private var state: ShortcutsSettingsModel.ActionState { presentation.state(for: action) }
    private var title: String { action == .togglePicker ? Strings.togglePicker : Strings.repeatLast }

    var body: some View {
        Section {
            if state.changePath == .inApp {
                LabeledContent(Strings.shortcutBindingLabel) { inAppRecorder }
            } else {
                LabeledContent(Strings.shortcutBindingLabel) { Text(Strings.shortcutBinding(state.binding)) }
                shortcutChange
            }
            if let registration = state.registration {
                LabeledContent(Strings.shortcutStatusLabel) {
                    Label(Strings.shortcutStatus(registration), systemImage: registrationSymbol)
                        .foregroundStyle(registrationColor)
                }
            }
            if let error = presentation.displayedShortcutError(for: action) {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Button(Strings.testShortcut) { presentation.beginVerification(action) }
                    .disabled(!presentation.canVerifyShortcut(action))
                    .accessibilityLabel(Strings.verifyShortcutLabel(title))
                Label(Strings.shortcutVerification(state.verification), systemImage: verificationSymbol)
                    .foregroundStyle(state.verification == .verified ? Color.green : Color.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // Registered and unbound states already read clearly in the Status row.
                if let registration = state.registration, registration.status == .needsAction
                    || registration.status == .failed { Text(registration.detail) }
                if state.changePath == .inApp { Text(Strings.shortcutCaptureHint) }
                if let guidance = changeGuidance { Text(guidance) }
                if let instructions = presentation.instructions(for: action) { Text(instructions) }
            }
        }
        .accessibilityIdentifier("settings-shortcut-" + action.rawValue)
    }

    /// A compact recorder showing the shortcut, with a clear button beside it.
    private var inAppRecorder: some View {
        HStack(spacing: 6) {
            ShortcutRecorder(label: Strings.recordShortcutLabel(title),
                title: Strings.shortcutSymbols(state.binding) ?? Strings.recordShortcut,
                onCapture: { presentation.setAccelerator($0, for: action) },
                onError: { presentation.captureFailed($0, for: action) })
                .frame(width: 150)
            Button { presentation.clearShortcut(action) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!presentation.canClearShortcut(action))
            .help(Strings.clearShortcut)
            .accessibilityLabel(Strings.clearShortcutLabel(title))
        }
    }

    @ViewBuilder private var shortcutChange: some View {
        switch state.changePath {
        case .inApp:
            EmptyView()
        case .systemSettings:
            Button(Strings.changeShortcut) { presentation.performPlatformChange(for: action) }
        case .setup:
            Button(Strings.configureShortcut) { presentation.performPlatformChange(for: action) }
        case .systemSettingsGuidance, .manualInstructions, .unavailable:
            EmptyView()
        }
    }

    private var changeGuidance: String? {
        switch state.changePath {
        case .systemSettingsGuidance(let text), .manualInstructions(let text): return text
        default: return nil
        }
    }

    private var registrationSymbol: String {
        switch state.registrationStatus {
        case .registered: return "checkmark.circle.fill"
        case .needsAction, .failed: return "exclamationmark.circle.fill"
        case .unbound, nil: return "questionmark.circle"
        }
    }

    private var registrationColor: Color {
        switch state.registrationStatus {
        case .registered: return .green
        case .needsAction, .failed: return .orange
        case .unbound, nil: return .secondary
        }
    }

    private var verificationSymbol: String {
        state.verification == .verified ? "checkmark.circle.fill" : "questionmark.circle"
    }
}
