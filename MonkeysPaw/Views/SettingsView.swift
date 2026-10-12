import MonkeysPawCore
import SwiftUI

/// Each model's view hook has one owner; independent service observers survive.
final class SettingsViewState: ObservableObject {
    @Published private(set) var general: GeneralSettingsModel.State
    @Published private(set) var togglePicker: ShortcutsSettingsModel.ActionState
    @Published private(set) var shortcutError: ShortcutRebindError?
    @Published private(set) var shortcutInstructions: String?
    @Published private(set) var captureError: ShortcutRebindError?
    @Published private(set) var rememberedValues: RememberedValuesSettingsModel.State
    @Published var isChoosingFolder = false
    let repeatLast: ShortcutsSettingsModel.ActionState
    let generalModel: GeneralSettingsModel
    let shortcutsModel: ShortcutsSettingsModel
    let rememberedValuesModel: RememberedValuesSettingsModel
    var onChooseFolder: (() -> Void)?
    var onRememberedValuesChange: (() -> Void)?
    var librarySwitchMessage: (() -> String?)?
    private let openSetup: () -> Void

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         rememberedValues: RememberedValuesSettingsModel,
         mainThread: MainThread, openSetup: @escaping () -> Void) {
        generalModel = general
        shortcutsModel = shortcuts
        rememberedValuesModel = rememberedValues
        self.rememberedValues = rememberedValues.state
        self.openSetup = openSetup
        self.general = general.state
        togglePicker = shortcuts.togglePicker
        repeatLast = shortcuts.repeatLast
        shortcutError = shortcuts.error
        shortcutInstructions = shortcuts.instructions
        general.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.general = self.generalModel.state
            }
        }
        shortcuts.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.togglePicker = self.shortcutsModel.togglePicker
                self.shortcutError = self.shortcutsModel.error
                self.shortcutInstructions = self.shortcutsModel.instructions
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

    var canUseDefault: Bool { !general.isDefaultLibrary || general.settingsError != nil }

    var generalMessages: [String] {
        let switchMessage = general.lastSwitchMessage.flatMap { outcome in
            if outcome == .deliveryInFlight, let message = librarySwitchMessage?() { return message }
            return GeneralSettingsStrings.message(for: outcome)
        }
        return Self.generalMessages(for: general.lastSwitchMessage, switchMessage: switchMessage,
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
        (captureError ?? shortcutError).map(Strings.shortcutError)
    }

    var canVerifyShortcut: Bool {
        togglePicker.registrationStatus == .registered || togglePicker.registrationStatus == .needsAction
    }

    func refresh() {
        generalModel.refresh()
        shortcutsModel.refresh()
    }

    func chooseFolder() { onChooseFolder?() }
    func useDefaultFolder() { generalModel.useDefaultFolder() }
    func revealFolder() { generalModel.revealFolder() }
    func requestForgetAll() { rememberedValuesModel.requestForgetAll() }
    func confirmForgetAll() { rememberedValuesModel.confirmForgetAll() }
    func cancelForgetAll() { rememberedValuesModel.cancelForgetAll() }
    func beginVerification() { shortcutsModel.beginVerification() }
    func performPlatformChange() { shortcutsModel.performPlatformChange() }
    func showSetup() { openSetup() }

    func setAccelerator(_ text: String) {
        captureError = nil
        shortcutsModel.setAccelerator(text)
    }

    func captureFailed(_ error: ShortcutRebindError) { captureError = error }
}

struct SettingsView: View {
    @ObservedObject var presentation: SettingsViewState

    var body: some View {
        TabView {
            general.tabItem { Text(Strings.generalTab) }
            shortcuts.tabItem { Text(Strings.shortcutsTab) }
        }
    }

    private var general: some View {
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
            Spacer()
        }
        .padding(20)
    }

    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Strings.togglePicker).font(.headline)
                Text(Strings.shortcutBinding(presentation.togglePicker.binding))
                if let registration = presentation.togglePicker.registration {
                    Text("\(Strings.hotkeyMechanism(registration.mechanism)): \(Strings.registrationStatus(registration.status))")
                    Text(registration.detail).font(.caption).foregroundStyle(.secondary)
                }
                shortcutChange
                if let error = presentation.displayedShortcutError {
                    Text(error).foregroundStyle(.red)
                }
                if let instructions = presentation.shortcutInstructions { Text(instructions) }
                HStack {
                    Button(SetupStrings.pressShortcut) { presentation.beginVerification() }
                        .disabled(!presentation.canVerifyShortcut)
                    Text(Strings.shortcutVerification(presentation.togglePicker.verification))
                }
                Divider()
                Text(Strings.repeatLast).font(.headline)
                Text(Strings.shortcutBinding(presentation.repeatLast.binding))
                Text(Strings.repeatUnavailable).font(.caption).foregroundStyle(.secondary)
                Divider()
                Button(Strings.openSetup) { presentation.showSetup() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    @ViewBuilder private var shortcutChange: some View {
        switch presentation.togglePicker.changePath {
        case .inApp:
            Text(Strings.shortcutCaptureHint).font(.caption).foregroundStyle(.secondary)
            ShortcutRecorder(onCapture: presentation.setAccelerator, onError: presentation.captureFailed)
                .frame(height: 32)
        case .systemSettings:
            Button(Strings.changeShortcut) { presentation.performPlatformChange() }
        case .setup:
            Button(Strings.configureShortcut) { presentation.performPlatformChange() }
        case .systemSettingsGuidance(let text), .manualInstructions(let text):
            Text(text)
        case .unavailable:
            EmptyView()
        }
    }
}
