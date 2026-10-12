import AppKit
import MonkeysPawCore
import SwiftUI

struct PickerView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 12) {
                controls.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                PickerPreviewView(text: presentation.preview,
                    description: selectedDescription)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !presentation.status.isEmpty {
                Text(presentation.status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(presentation.status)
                    .accessibilityIdentifier("picker-status")
            }
            PickerActionsView(presentation: presentation)
            Text(presentation.state == .fill ? Strings.fillHint : Strings.pickerHint)
                .font(.caption).foregroundStyle(.secondary)
            Text(Strings.pasteTarget(presentation.pasteTarget))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var header: some View {
        if presentation.state == .fill || presentation.state == .delivering {
            Text(selectedTitle).font(.headline)
        } else {
            PickerTextInput(value: presentation.model.query, label: Strings.searchPrompts,
                identifier: "picker-query", kind: nil, wantsFocus: presentation.state == .picker,
                focusRevision: presentation.focusRevision, onChange: presentation.setQuery)
                .frame(height: 26)
        }
    }

    @ViewBuilder private var controls: some View {
        if let fill = presentation.model.fillModel {
            PickerFillView(presentation: presentation, model: fill)
                .id(ObjectIdentifier(fill))
                .disabled(presentation.state == .delivering)
        } else {
            PickerResultsView(presentation: presentation)
                .disabled(presentation.state != .picker)
        }
    }

    private var selectedRow: PickerResultRow? {
        let model = presentation.model
        guard let position = model.selectionIndex, model.results.indices.contains(position) else { return nil }
        return model.results[position]
    }

    private var selectedTitle: String { selectedRow?.title ?? Strings.fillForm }
    private var selectedDescription: String? { selectedRow?.previewLine }
}

private struct PickerResultsView: View {
    private struct IndexedResult: Identifiable {
        let position: Int
        let row: PickerResultRow
        var id: RelativePath { RelativePath(row.relativePath) }
    }

    @ObservedObject var presentation: PickerViewState

    var body: some View {
        if presentation.model.results.isEmpty {
            PickerEmptyView(presentation: presentation)
        } else {
            List(selection: selection) {
                ForEach(indexedResults) { result in
                    PickerResultView(row: result.row).tag(result.position)
                }
            }
            .accessibilityLabel(Strings.promptResults)
        }
    }

    private var indexedResults: [IndexedResult] {
        presentation.model.results.enumerated().map { IndexedResult(position: $0.offset, row: $0.element) }
    }

    private var selection: Binding<Int?> {
        Binding(get: { presentation.model.selectionIndex }, set: { position in
            if let position { presentation.model.selectResult(at: position) }
        })
    }
}

private struct PickerResultView: View {
    let row: PickerResultRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((row.favorite ? "★ " : "") + row.title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityLabel((row.favorite ? Strings.favorite + " " : "") + row.title + " " + detail)
    }

    private var detail: String {
        ([row.folder] + row.tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct PickerEmptyView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let noMatches = presentation.model.noMatches {
                Text(noMatches.message)
                Button(noMatches.createLabel, action: presentation.createNoMatch)
                    .disabled(!presentation.model.libraryAvailable)
                    .accessibilityLabel(noMatches.createLabel)
                Button(noMatches.writeLabel) {}
                    .disabled(true)
                    .help(Strings.assistantNotConfigured)
                    .accessibilityLabel(noMatches.writeLabel)
                Text(Strings.assistantNotConfigured).font(.caption).foregroundStyle(.secondary)
                Button(noMatches.openLibraryLabel) { presentation.model.openLibrary() }
                    .accessibilityLabel(noMatches.openLibraryLabel)
            } else {
                Text(Strings.emptyLibrary)
                Button(Strings.library) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.library)
            }
            if presentation.showsForgetValues {
                Button(Strings.forgetValues, action: presentation.forgetSelectedValues)
                    .disabled(!presentation.canForgetValues)
                    .accessibilityLabel(Strings.forgetValues)
                    .accessibilityIdentifier("picker-forget-values")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PickerPreviewView: View {
    let text: String
    let description: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Text(text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityLabel(Strings.preview)
    }
}

private struct PickerActionsView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        HStack(spacing: 8) {
            if let fill = presentation.model.fillModel {
                Button(Strings.deliver) { fill.deliver(mode: fill.preferredMode) }
                    .disabled(!fill.deliverEnabled).accessibilityLabel(Strings.deliver)
                Button(Strings.copy) { fill.deliver(mode: .copyOnly) }
                    .disabled(!fill.canCopyOnly).accessibilityLabel(Strings.copy)
            } else {
                Button(Strings.usePrompt) { presentation.model.use(mode: .paste(.standard)) }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.usePrompt)
                Button(Strings.copy) { presentation.model.use(mode: .copyOnly) }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.copy)
                Button(Strings.edit) { presentation.model.editSelected() }
                    .disabled(presentation.model.selectionIndex == nil).accessibilityLabel(Strings.edit)
                Button(Strings.library) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.library)
            }
            Spacer()
            Button(Strings.cancel) { presentation.model.dismiss() }.accessibilityLabel(Strings.cancel)
        }
        .disabled(presentation.state == .delivering)
    }
}
