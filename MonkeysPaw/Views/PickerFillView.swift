import MonkeysPawCore
import SwiftUI

struct PickerFillView: View {
    @ObservedObject var presentation: PickerViewState
    let model: FillModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.fields.indices, id: \.self) { position in
                    PickerFillFieldView(field: model.fields[position], position: position,
                         model: model, wantsFocus: model.state == .editing && model.focusIndex == position,
                        focusRevision: presentation.focusRevision, resetRevision: presentation.inputResetRevision)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(Strings.fillForm)
    }
}

private struct PickerFillFieldView: View {
    let field: FillFieldState
    let position: Int
    let model: FillModel
    // Pass focus as a value: mutating the same Core model reference alone
    // does not invalidate SwiftUI's child-view comparison.
    let wantsFocus: Bool
    let focusRevision: UInt64
    let resetRevision: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(.callout).fontWeight(.medium)
            control
            if let description = field.description, !description.isEmpty {
                PickerFieldDescription(text: description, name: field.name)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text:
            PickerTextInput(value: field.value, label: field.label, identifier: identifier,
                wantsFocus: wantsFocus, focusRevision: focusRevision, onChange: setValue, onFocus: focus,
                resetRevision: resetRevision)
                .frame(height: 26)
        case .multiline:
            PickerMultilineInput(value: field.value, label: field.label, identifier: identifier,
                wantsFocus: wantsFocus, focusRevision: focusRevision, onChange: setValue, onFocus: focus,
                resetRevision: resetRevision)
                .frame(height: 80)
        case .choice:
            PickerChoiceInput(value: field.value, options: field.options, label: field.label,
                identifier: identifier, wantsFocus: wantsFocus, focusRevision: focusRevision,
                onChange: setValue, onFocus: focus)
                .frame(height: 26)
        }
    }

    private var identifier: String { "fill-field-" + field.name }
    private func setValue(_ value: String) { model.setValue(value, name: field.name) }
    private func focus() { model.focusField(at: position) }
}
