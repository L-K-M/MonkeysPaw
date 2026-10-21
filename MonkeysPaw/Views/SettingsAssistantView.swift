import MonkeysPawCore
import SwiftUI

/// The model owns behavior and secrets; this wrapper publishes safe UI state.
final class AssistantSettingsViewState: ObservableObject {
    @Published private(set) var state: AssistantSettingsModel.State
    private var model: AssistantSettingsModel?

    init(model: AssistantSettingsModel, mainThread: MainThread, onProviderChange: @escaping () -> Void = {}) {
        self.model = model
        state = model.state
        model.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self, let model = self.model else { return }
                let previous = self.state.operation
                self.state = model.state
                if previous != self.state.operation {
                    // Cancel before a saved credential can change, including a
                    // byte-identical profile or a failed credential rollback.
                    switch self.state.operation ?? previous {
                    case .saving, .selecting, .deleting: onProviderChange()
                    case .loading, nil: break
                    }
                }
            }
        }
    }

    var canChangeProfiles: Bool { model != nil && state.operation == nil && !state.isReadOnly }
    var canEditDraft: Bool {
        model != nil && state.draft != nil && !state.isReadOnly
            && (state.operation == nil || state.operation == .saving)
    }
    var canSave: Bool { canChangeProfiles && state.draft != nil }
    var canTest: Bool { canSave && !state.isTesting }
    var profileSelection: ProviderProfileID? { state.isNewProfile ? nil : state.draft?.id }
    var canActivateDraft: Bool {
        canChangeProfiles && profileSelection != nil && profileSelection != state.selectedProfileID
    }
    var activeProfileMessage: String {
        guard let profile = state.profiles.first(where: { $0.id == state.selectedProfileID }) else {
            return SettingsAssistantStrings.inactive
        }
        return SettingsAssistantStrings.activeProfile(profile.displayName)
    }
    var storageMessage: String { SettingsAssistantStrings.storage(state.keyStorage) }
    var keyEditMessage: String { SettingsAssistantStrings.keyEdit(state.keyEdit) }
    var storageWarning: String? { state.keyStorage.tier == .file ? SettingsAssistantStrings.unencrypted : nil }
    var progressMessage: String? {
        if let operation = state.operation { return SettingsAssistantStrings.progress(operation) }
        return state.isTesting ? SettingsAssistantStrings.testing : nil
    }
    var testMessage: String? { state.testResult.map(SettingsAssistantStrings.testResult) }
    var errorMessages: [String] {
        var errors = [state.readOnlyError, state.error].compactMap { $0 }
        if case .failed(let error) = state.keyStorage { errors.append(error) }
        return errors.reduce(into: [String]()) { messages, error in
            let message = SettingsAssistantStrings.settingsError(error)
            if !messages.contains(message) { messages.append(message) }
        }
    }

    func addProfile() { if canChangeProfiles { model?.addProfile() } }
    func selectProfile(_ id: ProviderProfileID?) { if canChangeProfiles { model?.selectProfile(id) } }
    func activateProfile() { if canActivateDraft { model?.selectProfile(profileSelection) } }
    func renameProfile(_ name: String) { if canEditDraft { model?.renameProfile(name) } }
    func setKind(_ kind: ProviderKind) { if canEditDraft { model?.setKind(kind) } }
    func setBaseURL(_ url: String) { if canEditDraft { model?.setBaseURL(url) } }
    func setModelID(_ id: String) { if canEditDraft { model?.setModelID(id) } }
    func setKeyInput(_ input: String) { if canEditDraft { model?.setKeyInput(input) } }
    func keepKey() { if canEditDraft { model?.keepKey() } }
    func clearKey() { if canEditDraft { model?.clearKey() } }
    func save() { if canSave { model?.save() } }
    func testConnection() { if canTest { model?.testConnection() } }
    func cancelTest() { model?.cancelTest() }
    func deleteProfile() {
        guard canChangeProfiles, let id = state.draft?.id else { return }
        // A12 discards an unsaved draft locally through this same intent.
        model?.deleteProfile(id)
    }
    func refresh() {
        guard state.operation == nil else { return }
        cancelTest()
        model?.refresh()
    }

    func retire() {
        model?.onChange = nil
        model?.cancelTest()
        model = nil
    }
}

struct SettingsAssistantView: View {
    @ObservedObject var presentation: AssistantSettingsViewState

    var body: some View {
        Form {
            profiles
            if presentation.state.draft != nil { editor }
            else if presentation.state.operation == nil {
                Section { Text(SettingsAssistantStrings.empty) }
            }
            status
        }
        .formStyle(.grouped)
    }

    private var profiles: some View {
        Section {
            List(selection: Binding(get: { presentation.profileSelection }, set: presentation.selectProfile)) {
                ForEach(presentation.state.profiles, id: \.id) { profile in
                    Text(SettingsAssistantStrings.profileRow(profile.displayName,
                        isActive: profile.id == presentation.state.selectedProfileID))
                        .tag(profile.id)
                }
            }
            .frame(height: 100)
            .disabled(!presentation.canChangeProfiles)
            .accessibilityLabel(SettingsAssistantStrings.profiles)
            HStack {
                Button(action: presentation.addProfile) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(SettingsAssistantStrings.add)
                .help(SettingsAssistantStrings.add)
                Button(action: presentation.deleteProfile) {
                    Image(systemName: "minus")
                }
                    .accessibilityLabel(SettingsAssistantStrings.delete)
                    .help(SettingsAssistantStrings.delete)
                    .disabled(presentation.state.draft == nil)
                Spacer()
                if presentation.canActivateDraft {
                    Button(SettingsAssistantStrings.makeActive, action: presentation.activateProfile)
                }
                Button(SettingsAssistantStrings.disable) { presentation.selectProfile(nil) }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(!presentation.canChangeProfiles)
        } header: {
            Text(SettingsAssistantStrings.profiles)
        } footer: {
            Text(presentation.activeProfileMessage)
            if presentation.state.isNewProfile { Text(SettingsAssistantStrings.newProfile) }
        }
    }

    private var editor: some View {
        Section {
            LabeledContent(SettingsAssistantStrings.name) {
                TextField(SettingsAssistantStrings.name, text: Binding(
                    get: { presentation.state.draft?.displayName ?? "" }, set: presentation.renameProfile))
                    .labelsHidden().accessibilityLabel(SettingsAssistantStrings.name)
            }
            Picker(SettingsAssistantStrings.kind, selection: Binding(
                get: { presentation.state.draft?.kind ?? .anthropic }, set: presentation.setKind)) {
                Text(SettingsAssistantStrings.anthropic).tag(ProviderKind.anthropic)
                Text(SettingsAssistantStrings.compatible).tag(ProviderKind.openaiCompatible)
            }
            LabeledContent(SettingsAssistantStrings.baseURL) {
                TextField(SettingsAssistantStrings.baseURL, text: Binding(
                    get: { presentation.state.draft?.baseURL ?? "" }, set: presentation.setBaseURL))
                    .labelsHidden().accessibilityLabel(SettingsAssistantStrings.baseURL)
            }
            LabeledContent(SettingsAssistantStrings.modelID) {
                HStack {
                    TextField(SettingsAssistantStrings.modelID, text: Binding(
                        get: { presentation.state.draft?.modelID ?? "" }, set: presentation.setModelID))
                        .labelsHidden().accessibilityLabel(SettingsAssistantStrings.modelID)
                    modelMenu
                }
            }
            LabeledContent(SettingsAssistantStrings.key) {
                SettingsAssistantKeyField(reset: presentation.state.keyInputReset,
                    isEditable: presentation.canEditDraft, onInput: presentation.setKeyInput)
                    .frame(height: 24)
            }
            HStack {
                Button(SettingsAssistantStrings.keepKey, action: presentation.keepKey)
                Button(SettingsAssistantStrings.clearKey, action: presentation.clearKey)
            }
        } header: {
            Text(SettingsAssistantStrings.profile)
        } footer: {
            Text(SettingsAssistantStrings.manualModel)
            Text(presentation.keyEditMessage)
            Text(presentation.storageMessage)
            if let warning = presentation.storageWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!presentation.canEditDraft)
    }

    private var modelMenu: some View {
        Menu(SettingsAssistantStrings.chooseModel) {
            ForEach(presentation.state.availableModels, id: \.id) { model in
                Button(SettingsAssistantStrings.modelLabel(model)) { presentation.setModelID(model.id) }
            }
        }
        .fixedSize()
        .disabled(presentation.state.availableModels.isEmpty)
    }

    private var status: some View {
        Section {
            HStack {
                Button(SettingsAssistantStrings.test, action: presentation.testConnection).disabled(!presentation.canTest)
                Button(SettingsAssistantStrings.save, action: presentation.save)
                    .disabled(!presentation.canSave).keyboardShortcut(.defaultAction)
                if presentation.state.isTesting {
                    Button(SettingsAssistantStrings.cancelTest, action: presentation.cancelTest)
                }
                Button(SettingsAssistantStrings.refresh, action: presentation.refresh)
                    .disabled(presentation.state.operation != nil)
            }
            if let progress = presentation.progressMessage {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(presentation.errorMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let message = presentation.testMessage {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
