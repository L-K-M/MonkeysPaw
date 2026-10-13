import MonkeysPawCore
import SwiftUI

/// The model owns behavior and secrets; this wrapper publishes safe UI state.
final class AssistantSettingsViewState: ObservableObject {
    @Published private(set) var state: AssistantSettingsModel.State
    private var model: AssistantSettingsModel?

    init(model: AssistantSettingsModel, mainThread: MainThread) {
        self.model = model
        state = model.state
        model.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self, let model = self.model else { return }
                self.state = model.state
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
        model?.deleteProfile(id)
    }
    func refresh() { if state.operation == nil { model?.refresh() } }

    func retire() {
        model?.onChange = nil
        model?.cancelTest()
        model = nil
    }
}

struct SettingsAssistantView: View {
    @ObservedObject var presentation: AssistantSettingsViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                profiles
                if presentation.state.isNewProfile {
                    Text(SettingsAssistantStrings.newProfile).font(.caption)
                }
                if presentation.state.draft != nil { editor }
                else if presentation.state.operation == nil { Text(SettingsAssistantStrings.empty) }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsAssistantStrings.profiles).font(.headline)
            List(selection: Binding(get: { presentation.state.selectedProfileID }, set: presentation.selectProfile)) {
                ForEach(presentation.state.profiles, id: \.id) { profile in
                    Text(SettingsAssistantStrings.profileRow(profile.displayName,
                        isActive: profile.id == presentation.state.selectedProfileID))
                        .tag(profile.id)
                }
            }
            .frame(height: 100)
            .disabled(!presentation.canChangeProfiles)
            .accessibilityLabel(SettingsAssistantStrings.profiles)
            Text(presentation.activeProfileMessage).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(SettingsAssistantStrings.add, action: presentation.addProfile)
                Button(SettingsAssistantStrings.delete, action: presentation.deleteProfile)
                    .disabled(presentation.state.draft == nil)
                Button(SettingsAssistantStrings.disable) { presentation.selectProfile(nil) }
            }
            .disabled(!presentation.canChangeProfiles)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(SettingsAssistantStrings.name, text: Binding(
                get: { presentation.state.draft?.displayName ?? "" }, set: presentation.renameProfile))
                .accessibilityLabel(SettingsAssistantStrings.name)
            Picker(SettingsAssistantStrings.kind, selection: Binding(
                get: { presentation.state.draft?.kind ?? .anthropic }, set: presentation.setKind)) {
                Text(SettingsAssistantStrings.anthropic).tag(ProviderKind.anthropic)
                Text(SettingsAssistantStrings.compatible).tag(ProviderKind.openaiCompatible)
            }
            TextField(SettingsAssistantStrings.baseURL, text: Binding(
                get: { presentation.state.draft?.baseURL ?? "" }, set: presentation.setBaseURL))
                .accessibilityLabel(SettingsAssistantStrings.baseURL)
            TextField(SettingsAssistantStrings.modelID, text: Binding(
                get: { presentation.state.draft?.modelID ?? "" }, set: presentation.setModelID))
                .accessibilityLabel(SettingsAssistantStrings.modelID)
            Menu(SettingsAssistantStrings.chooseModel) {
                ForEach(presentation.state.availableModels, id: \.id) { model in
                    Button(SettingsAssistantStrings.modelLabel(model)) { presentation.setModelID(model.id) }
                }
            }
            .disabled(presentation.state.availableModels.isEmpty)
            Text(SettingsAssistantStrings.manualModel).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(SettingsAssistantStrings.key).font(.headline)
            SettingsAssistantKeyField(reset: presentation.state.keyInputReset,
                isEditable: presentation.canEditDraft, onInput: presentation.setKeyInput)
                .frame(height: 24)
            HStack {
                Button(SettingsAssistantStrings.keepKey, action: presentation.keepKey)
                Button(SettingsAssistantStrings.clearKey, action: presentation.clearKey)
            }
            Text(presentation.keyEditMessage).font(.caption).foregroundStyle(.secondary)
            Text(presentation.storageMessage)
            if let warning = presentation.storageWarning {
                Text(warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!presentation.canEditDraft)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(SettingsAssistantStrings.save, action: presentation.save).disabled(!presentation.canSave)
                Button(SettingsAssistantStrings.test, action: presentation.testConnection).disabled(!presentation.canTest)
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
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let message = presentation.testMessage {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
