import MonkeysPawCore
import SwiftUI

/// Each model's view hook has one owner; independent service observers survive.
final class SettingsViewState: ObservableObject {
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
    var onChooseFolder: (() -> Void)?
    var onRememberedValuesChange: (() -> Void)?
    /// An installed override may return nil to hide a resolved busy outcome.
    var librarySwitchMessage: (() -> String?)?
    private let openSetup: () -> Void

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         rememberedValues: RememberedValuesSettingsModel,
         delivery: DeliverySettingsModel, updates: UpdateSettingsModel,
         mainThread: MainThread, openSetup: @escaping () -> Void) {
        generalModel = general
        shortcutsModel = shortcuts
        rememberedValuesModel = rememberedValues
        self.rememberedValues = rememberedValues.state
        self.openSetup = openSetup
        self.delivery = DeliverySettingsViewState(model: delivery, mainThread: mainThread)
        self.updates = UpdateSettingsViewState(model: updates, mainThread: mainThread)
        self.general = general.state
        togglePicker = shortcuts.togglePicker
        repeatLast = shortcuts.repeatLast
        updateShortcuts()
        general.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.general = self.generalModel.state
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

    func chooseFolder() { onChooseFolder?() }
    func useDefaultFolder() { generalModel.useDefaultFolder() }
    func revealFolder() { generalModel.revealFolder() }
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

    var body: some View {
        TabView {
            general.tabItem { Text(Strings.generalTab) }
            shortcuts.tabItem { Text(Strings.shortcutsTab) }
            SettingsDeliveryView(presentation: presentation.delivery)
                .tabItem { Text(DeliverySettingsStrings.title) }
            if let assistant = presentation.assistant {
                SettingsAssistantView(presentation: assistant).tabItem { Text(SettingsAssistantStrings.tab) }
            }
        }
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Strings.libraryFolder).font(.headline)
                Text(presentation.general.activeLibraryPath)
                    .textSelection(.enabled)
                    .accessibilityLabel(Strings.libraryFolder)
                    .accessibilityValue(presentation.general.activeLibraryPath)
                Text(presentation.general.isDefaultLibrary ? Strings.defaultLibraryFolder : Strings.chosenLibraryFolder)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(Strings.chooseFolder) { presentation.chooseFolder() }
                        .disabled(presentation.isChoosingFolder)
                    Button(Strings.useDefaultFolder) { presentation.useDefaultFolder() }
                        .disabled(!presentation.canUseDefault)
                    Button(Strings.showInFinder) { presentation.revealFolder() }
                }
                ForEach(presentation.generalMessages, id: \.self) { message in
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Button(Strings.forgetAllValues, action: presentation.requestForgetAll)
                    .disabled(presentation.isChoosingFolder || presentation.rememberedValues.confirmation != .none)
                    .accessibilityLabel(Strings.forgetAllValues)
                    .accessibilityIdentifier("settings-forget-all")
                if let message = presentation.rememberedValues.message {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                        .accessibilityIdentifier("settings-forget-message")
                }
                Divider()
                SettingsUpdateView(presentation: presentation.updates)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ShortcutSettingsRow(presentation: presentation, action: .togglePicker)
                Divider()
                ShortcutSettingsRow(presentation: presentation, action: .repeatLast)
                Divider()
                Button(Strings.openSetup) { presentation.showSetup() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

private struct ShortcutSettingsRow: View {
    @ObservedObject var presentation: SettingsViewState
    let action: HotkeyAction

    private var state: ShortcutsSettingsModel.ActionState { presentation.state(for: action) }
    private var title: String { action == .togglePicker ? Strings.togglePicker : Strings.repeatLast }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(Strings.shortcutBinding(state.binding))
            if let registration = state.registration {
                Text(Strings.shortcutRegistration(registration))
                Text(registration.detail).font(.caption).foregroundStyle(.secondary)
            }
            shortcutChange
            if let error = presentation.displayedShortcutError(for: action) {
                Text(error).foregroundStyle(.red)
            }
            if let instructions = presentation.instructions(for: action) { Text(instructions) }
            HStack {
                Button(SetupStrings.pressShortcut) { presentation.beginVerification(action) }
                    .disabled(!presentation.canVerifyShortcut(action))
                    .accessibilityLabel(Strings.verifyShortcutLabel(title))
                Text(Strings.shortcutVerification(state.verification))
            }
        }
        .accessibilityIdentifier("settings-shortcut-" + action.rawValue)
    }

    @ViewBuilder private var shortcutChange: some View {
        switch state.changePath {
        case .inApp:
            Text(Strings.shortcutCaptureHint).font(.caption).foregroundStyle(.secondary)
            HStack {
                ShortcutRecorder(label: Strings.recordShortcutLabel(title), onCapture: {
                    presentation.setAccelerator($0, for: action)
                }, onError: { presentation.captureFailed($0, for: action) })
                    .frame(height: 32)
                Button(Strings.clearShortcut) { presentation.clearShortcut(action) }
                    .disabled(!presentation.canClearShortcut(action))
                    .accessibilityLabel(Strings.clearShortcutLabel(title))
            }
        case .systemSettings:
            Button(Strings.changeShortcut) { presentation.performPlatformChange(for: action) }
        case .setup:
            Button(Strings.configureShortcut) { presentation.performPlatformChange(for: action) }
        case .systemSettingsGuidance(let text), .manualInstructions(let text):
            Text(text)
        case .unavailable:
            EmptyView()
        }
    }
}
