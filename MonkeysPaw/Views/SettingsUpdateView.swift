import MonkeysPawCore
import SwiftUI

final class UpdateSettingsViewState: ObservableObject {
    @Published private(set) var state: UpdateSettingsModel.State
    let model: UpdateSettingsModel
    private let mainThread: MainThread
    private var isShown = false
    private var isRetired = false

    init(model: UpdateSettingsModel, mainThread: MainThread) {
        self.model = model
        self.mainThread = mainThread
        state = model.state
    }

    var canEdit: Bool { isShown && !isRetired && !state.isReadOnly }
    var canCheck: Bool {
        isShown && !isRetired && state.update?.currentVersion != nil && state.update?.isChecking == false
    }
    var canViewRelease: Bool { canCheck && state.update?.canOpenRelease == true }

    func show() {
        guard !isRetired else { return }
        isShown = true
        model.onChange = { [weak self] in
            self?.mainThread.run { [weak self] in
                guard let self, self.isShown, !self.isRetired else { return }
                self.state = self.model.state
            }
        }
        model.refresh()
        state = model.state
    }

    func hide() {
        isShown = false
        model.onChange = nil
    }

    func retire() {
        hide()
        isRetired = true
        model.retire()
    }

    func setAutomatic(_ enabled: Bool) {
        guard canEdit else { return }
        model.setAutomaticUpdateChecks(enabled ? .enabled : .disabled)
        state = model.state
    }

    func checkNow() { if canCheck { model.checkNow() } }
    func viewRelease() { if canViewRelease { model.viewRelease() } }
}

struct SettingsUpdateView: View {
    @ObservedObject var presentation: UpdateSettingsViewState

    var body: some View {
        Section {
            Toggle(SettingsUpdateStrings.automatic, isOn: Binding(
                get: { presentation.state.automaticUpdateChecks == .enabled },
                set: presentation.setAutomatic))
                .disabled(!presentation.canEdit)
                .accessibilityLabel(SettingsUpdateStrings.automatic)
                .accessibilityIdentifier("settings-automatic-updates")
            LabeledContent(SettingsUpdateStrings.currentVersion) {
                Text(presentation.state.update?.currentVersion?.description ?? SettingsUpdateStrings.unavailableVersion)
            }
                .accessibilityIdentifier("settings-update-version")
            LabeledContent(SettingsUpdateStrings.lastCheck) {
                Text(SettingsUpdateStrings.checkDate(presentation.state.update?.lastSuccessfulCheck))
            }
            Text(SettingsUpdateStrings.result(presentation.state.update))
                .accessibilityIdentifier("settings-update-result")
            errors
            HStack {
                Button(SettingsUpdateStrings.checkNow, action: presentation.checkNow)
                    .disabled(!presentation.canCheck)
                    .accessibilityLabel(SettingsUpdateStrings.checkNow)
                    .accessibilityIdentifier("settings-check-updates")
                Button(SettingsUpdateStrings.viewRelease, action: presentation.viewRelease)
                    .disabled(!presentation.canViewRelease)
                    .accessibilityLabel(SettingsUpdateStrings.viewRelease)
                    .accessibilityIdentifier("settings-view-release")
            }
        } header: {
            Text(SettingsUpdateStrings.title)
        } footer: {
            Text(SettingsUpdateStrings.disclosure)
        }
    }

    /// One form row per error; no empty row when everything is fine.
    @ViewBuilder private var errors: some View {
        if let error = presentation.state.settingsError {
            errorRow(GeneralSettingsStrings.settingsError(error))
        }
        if let error = presentation.state.update?.stateError {
            errorRow(SettingsUpdateStrings.stateError(error))
        }
        if presentation.state.update?.releasePageOpeningFailed == true {
            errorRow(SettingsUpdateStrings.openingFailed)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
