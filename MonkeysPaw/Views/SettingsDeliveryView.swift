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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(DeliverySettingsStrings.macOSChord).font(.headline)
                    .accessibilityLabel(DeliverySettingsStrings.defaultChord)
                    .accessibilityValue(DeliverySettingsStrings.macOSChord)
                    .accessibilityIdentifier("settings-paste-chord")
                Text(DeliverySettingsStrings.macOSExplanation)
                Toggle(DeliverySettingsStrings.restoreClipboard, isOn: Binding(
                    get: { presentation.state.preferences.clipboardRestore == .previousText },
                    set: presentation.setRestore))
                    .disabled(!presentation.canEdit)
                    .accessibilityLabel(DeliverySettingsStrings.restoreClipboard)
                    .accessibilityIdentifier("settings-restore-clipboard")
                Text(DeliverySettingsStrings.restoreCaveat).font(.caption)
                Text(SettingsDeliveryStrings.restoreOwnership).font(.caption)
                if let error = presentation.state.settingsError {
                    Text(GeneralSettingsStrings.settingsError(error)).foregroundStyle(.red)
                        .accessibilityIdentifier("settings-delivery-error")
                }
                Divider()
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SettingsDeliveryStrings.status(presentation.state.delivery))
                .accessibilityIdentifier("settings-delivery-status")
            ForEach(presentation.state.permissionRows, id: \.kind) { row in
                Text(SettingsDeliveryStrings.permission(row))
            }
            Text(SettingsDeliveryStrings.automation(presentation.state))
                .accessibilityIdentifier("settings-automation-status")
            if let report = SettingsDeliveryStrings.test(presentation.state.test) {
                Text(report).accessibilityIdentifier("settings-delivery-report")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
