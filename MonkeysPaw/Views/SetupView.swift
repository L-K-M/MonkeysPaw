import MonkeysPawCore
import SwiftUI

final class SetupViewState: ObservableObject {
    @Published private(set) var rows: [SetupRow]
    @Published private(set) var state: SetupModel.State
    let model: SetupModel
    /// The window supplies its native close path so Done follows the same
    /// route as the title-bar button.
    var requestClose: (() -> Void)?

    init(model: SetupModel) {
        self.model = model
        rows = model.rows
        state = model.state
        model.onChange = { [weak self] in
            guard let self else { return }
            self.rows = self.model.rows
            self.state = self.model.state
        }
    }

    func close() { requestClose?() }
}

struct SetupView: View {
    @ObservedObject var presentation: SetupViewState

    var body: some View {
        WelcomeWindowView(title: Strings.setupTitle, explanation: WelcomeStrings.setupExplanation) {
            rows
            selfTestResults
        } secondaryActions: {
            secondaryButtons
        } defaultAction: {
            doneButton
        }
    }

    private var rows: some View {
        // Rows for the other desktop (portal, ydotool, KDE) only add noise here.
        ForEach(presentation.rows.filter(\.appliesHere), id: \.kind) { row in
            WelcomeStatusRow(symbol: Self.symbol(for: row.status)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.rowTitle(row.kind)).font(.headline)
                    if row.kind == .hotkey { Text(Strings.defaultHotkey).font(.caption) }
                    Text(Strings.status(row.status)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.kind == .accessibility, case .needsAction = row.status {
                    Button(Strings.fix) { presentation.model.fix(row.kind) }
                }
            }
        }
    }

    @ViewBuilder private var selfTestResults: some View {
        if case .tested(let report) = presentation.state {
            Divider()
            ForEach(report.results, id: \.backend) { result in
                WelcomeStatusRow(symbol: Self.symbol(for: result.status)) {
                    Text("\(Strings.backend(result.backend)): \(Strings.selfTestStatus(result.status))")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        Button(SetupStrings.pressShortcut) { presentation.model.beginHotkeyVerification() }
        Button(presentation.state == .testing ? Strings.testing : Strings.runSelfTest) {
            presentation.model.runSelfTest()
        }
        .disabled(presentation.state == .testing)
        Button(Strings.refresh) { presentation.model.refresh() }
    }

    private var doneButton: some View {
        Button(Strings.done) { presentation.close() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("setup-done")
    }

    private static func symbol(for status: SetupStatus) -> WelcomeStatusSymbol {
        switch status {
        case .ok: return .ready
        case .needsAction: return .needsAttention
        case .unknown, .notApplicable: return .unchecked
        }
    }

    private static func symbol(for status: SelfTestStatus) -> WelcomeStatusSymbol {
        switch status {
        case .pasted: return .ready
        case .sentButNotReceived, .failed: return .needsAttention
        }
    }
}

extension SetupRow {
    /// macOS hides checks that only apply to Linux desktops.
    var appliesHere: Bool {
        if case .notApplicable = status { return false }
        return true
    }
}
