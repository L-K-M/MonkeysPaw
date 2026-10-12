import MonkeysPawCore
import SwiftUI

/// Each model's view hook has one owner; independent service observers survive.
final class SettingsViewState: ObservableObject {
    @Published private(set) var general: GeneralSettingsModel.State
    @Published private(set) var togglePicker: ShortcutsSettingsModel.ActionState
    @Published private(set) var shortcutError: ShortcutRebindError?
    @Published private(set) var shortcutInstructions: String?
    @Published private(set) var captureError: ShortcutRebindError?
    @Published var isChoosingFolder = false
    let repeatLast: ShortcutsSettingsModel.ActionState
    let generalModel: GeneralSettingsModel
    let shortcutsModel: ShortcutsSettingsModel
    var onChooseFolder: (() -> Void)?
    private let openSetup: () -> Void

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         mainThread: MainThread, openSetup: @escaping () -> Void) {
        generalModel = general
        shortcutsModel = shortcuts
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
    }

    var canUseDefault: Bool { !general.isDefaultLibrary || general.settingsError != nil }

    var generalMessages: [String] {
        var messages: [String] = []
        if let outcome = general.lastSwitchMessage, let message = GeneralSettingsStrings.message(for: outcome) {
            messages.append(message)
        }
        if case .settingsNotSaved = general.lastSwitchMessage { return messages }
        if let error = general.settingsError { messages.append(GeneralSettingsStrings.settingsError(error)) }
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
        .padding(16)
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
