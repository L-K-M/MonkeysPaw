import MonkeysPawCore
import SwiftUI

/// Republishes Core's callback state. The view forwards intents only to PanelModel.
final class PanelViewState: ObservableObject {
    @Published private(set) var state: PanelModel.State
    let model: PanelModel

    init(model: PanelModel) {
        self.model = model
        state = model.state
        model.onChange = { [weak self] in
            guard let self else { return }
            self.state = self.model.state
        }
    }
}

struct PanelView: View {
    @ObservedObject var presentation: PanelViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Strings.cannedPromptTitle).font(.title2)
            Text(presentation.model.prompt)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
            HStack {
                Button(Strings.paste) { presentation.model.confirm(mode: .paste(.standard)) }
                    .keyboardShortcut(.defaultAction)
                Button(Strings.copy) { presentation.model.confirm(mode: .copyOnly) }
                    .keyboardShortcut(.return, modifiers: .option)
                Spacer()
                Button(Strings.cancel) { presentation.model.cancel() }
            }
            .disabled(presentation.state != .idle)
            Text(Strings.panelHint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
