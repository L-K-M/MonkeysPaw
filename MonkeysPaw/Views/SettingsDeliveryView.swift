import MonkeysPawCore
import SwiftUI

final class DeliverySettingsViewState: ObservableObject {
    @Published private(set) var state: DeliverySettingsModel.State
    let model: DeliverySettingsModel
    private let mainThread: MainThread
    private var isShown = false
    private var isRetired = false

    init(model: DeliverySettingsModel, mainThread: MainThread) {
        self.model = model
        self.mainThread = mainThread
        state = model.state
    }

    var canEdit: Bool { isShown && !isRetired && !state.isReadOnly }
    var canTest: Bool { isShown && !isRetired && state.test != .testing }

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

    func setRestore(_ enabled: Bool) {
        guard canEdit else { return }
        model.setClipboardRestore(enabled ? .previousText : .off)
        // Repeated save failures may not publish; render the committed choice.
        state = model.state
    }

    func testPaste() { if canTest { model.runSelfTest() } }
    func openSetup() { if isShown && !isRetired { model.openSetup() } }
}

struct SettingsDeliveryView: View {
    @ObservedObject var presentation: DeliverySettingsViewState

    var body: some View {
        Form {
            Section {
                LabeledContent(DeliverySettingsStrings.defaultChord) {
                    Text(SettingsDeliveryStrings.pasteChord)
                }
                    .accessibilityLabel(DeliverySettingsStrings.defaultChord)
                    .accessibilityValue(DeliverySettingsStrings.macOSChord)
                    .accessibilityIdentifier("settings-paste-chord")
                Text(DeliverySettingsStrings.macOSExplanation)
            } header: {
                Text(DeliverySettingsStrings.title)
            }
            Section {
                Toggle(DeliverySettingsStrings.restoreClipboard, isOn: Binding(
                    get: { presentation.state.preferences.clipboardRestore == .previousText },
                    set: presentation.setRestore))
                    .disabled(!presentation.canEdit)
                    .accessibilityLabel(DeliverySettingsStrings.restoreClipboard)
                    .accessibilityIdentifier("settings-restore-clipboard")
                if let error = presentation.state.settingsError {
                    Label(GeneralSettingsStrings.settingsError(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings-delivery-error")
                }
            } footer: {
                Text(DeliverySettingsStrings.restoreCaveat + " " + SettingsDeliveryStrings.restoreOwnership)
            }
            Section {
                diagnostics
                HStack {
                    Button(DeliverySettingsStrings.testPaste, action: presentation.testPaste)
                        .disabled(!presentation.canTest)
                        .accessibilityLabel(DeliverySettingsStrings.testPaste)
                        .accessibilityIdentifier("settings-test-paste")
                    Button(DeliverySettingsStrings.openSetup, action: presentation.openSetup)
                        .accessibilityLabel(DeliverySettingsStrings.openSetup)
                        .accessibilityIdentifier("settings-delivery-open-setup")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(SettingsDeliveryStrings.status(presentation.state.delivery), systemImage: backendSymbol)
                .accessibilityIdentifier("settings-delivery-status")
            ForEach(presentation.state.permissionRows, id: \.kind) { row in
                Label(SettingsDeliveryStrings.permission(row), systemImage: permissionSymbol(row.status))
                    .foregroundStyle(permissionColor(row.status))
            }
            Label(SettingsDeliveryStrings.automation(presentation.state), systemImage: automationSymbol)
                .accessibilityIdentifier("settings-automation-status")
            if let report = SettingsDeliveryStrings.test(presentation.state.test) {
                Text(report).accessibilityIdentifier("settings-delivery-report")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var backendSymbol: String {
        guard let delivery = presentation.state.delivery else { return "questionmark.circle" }
        return delivery.cachedFailures.isEmpty ? "questionmark.circle" : "exclamationmark.circle.fill"
    }

    private var automationSymbol: String {
        if presentation.state.delivery?.cachedFailures.contains(where: { $0.backend == .appleScript }) == true {
            return "exclamationmark.circle.fill"
        }
        if case .tested(let report) = presentation.state.test,
           let result = report.results.first(where: { $0.backend == .appleScript }) {
            return result.status == .pasted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        }
        return "questionmark.circle"
    }

    private func permissionSymbol(_ status: SetupStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .needsAction: return "exclamationmark.circle.fill"
        case .unknown, .notApplicable: return "questionmark.circle"
        }
    }

    private func permissionColor(_ status: SetupStatus) -> Color {
        switch status {
        case .ok: return .green
        case .needsAction: return .orange
        case .unknown, .notApplicable: return .secondary
        }
    }
}
