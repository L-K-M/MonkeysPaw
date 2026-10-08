import MonkeysPawCore
import SwiftUI

final class SetupViewState: ObservableObject {
    @Published private(set) var rows: [SetupRow]
    @Published private(set) var state: SetupModel.State
    let model: SetupModel

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
}

struct SetupView: View {
    @ObservedObject var presentation: SetupViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.setupTitle).font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(presentation.rows, id: \.kind) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(color(for: row.status)).frame(width: 8, height: 8).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Strings.rowTitle(row.kind)).font(.headline)
                                if row.kind == .hotkey { Text(Strings.registeredHotkey).font(.caption) }
                                Text(Strings.status(row.status)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.kind == .accessibility, case .needsAction = row.status {
                                Button(Strings.fix) { presentation.model.fix(row.kind) }
                            }
                        }
                    }
                    if case .tested(let report) = presentation.state {
                        Divider()
                        ForEach(report.results, id: \.backend) { result in
                            Text("\(Strings.backend(result.backend)): \(Strings.selfTestStatus(result.status))")
                        }
                    }
                }
            }
            HStack {
                Button(SetupStrings.pressShortcut) { presentation.model.beginHotkeyVerification() }
                Button(presentation.state == .testing ? Strings.testing : Strings.runSelfTest) {
                    presentation.model.runSelfTest()
                }
                .disabled(presentation.state == .testing)
                Spacer()
                Button(Strings.refresh) { presentation.model.refresh() }
            }
        }
        .padding(24)
    }

    private func color(for status: SetupStatus) -> Color {
        switch status {
        case .ok: return .green
        case .needsAction: return .orange
        case .unknown, .notApplicable: return .gray
        }
    }
}
