import AppKit
import MonkeysPawCore
import SwiftUI

struct PickerView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            content.padding(12)
            if !presentation.status.isEmpty {
                Label(presentation.status.replacingOccurrences(of: "\n", with: " · "),
                    systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(presentation.status)
                    .accessibilityLabel(presentation.status)
                    .accessibilityIdentifier("picker-status")
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        if presentation.model.fillModel == nil, presentation.model.results.isEmpty {
            PickerEmptyView(presentation: presentation)
        } else {
            HStack(alignment: .top, spacing: 12) {
                controls.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                PickerPreviewView(text: presentation.preview, description: selectedDescription)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var header: some View {
        if presentation.state == .fill || presentation.state == .delivering {
            HStack {
                Button { presentation.model.escape() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel(Strings.back)
                    .help(Strings.back + " ⎋")
                    .disabled(presentation.state == .delivering)
                Text(selectedTitle).font(.title2).lineLimit(1)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                PickerTextInput(value: presentation.model.query, label: Strings.searchPrompts,
                    identifier: "picker-query", kind: nil, wantsFocus: presentation.state == .picker,
                    focusRevision: presentation.focusRevision, onChange: presentation.setQuery,
                    font: .preferredFont(forTextStyle: .title2), isBezeled: false)
                    .frame(height: 28)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.pasteTarget(presentation.pasteTarget))
                    .lineLimit(1).truncationMode(.tail)
                    .help(Strings.pasteTarget(presentation.pasteTarget))
                    .accessibilityIdentifier("picker-target")
                if let syncStatus = presentation.syncStatus { SyncStatusView(presentation: syncStatus) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PickerActionsView(presentation: presentation).fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.favorite ? "star.fill" : "text.alignleft")
                .foregroundStyle(row.favorite ? Color.yellow : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityLabel((row.favorite ? Strings.favorite + " " : "") + row.title + " " + detail)
    }

    private var detail: String {
        var parts = [row.folder] + row.tags.map { "#" + $0 }
        if case .group(let group) = row.access { parts.append(group.name) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct PickerEmptyView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(spacing: 10) {
            if let noMatches = presentation.model.noMatches {
                Text(noMatches.message)
                Button(Strings.createPrompt(noMatches.query), action: presentation.createNoMatch)
                    .disabled(!presentation.model.libraryAvailable)
                    .accessibilityLabel(noMatches.createLabel)
                Button(Strings.writeWithAssistant) {}
                    .disabled(true)
                    .help(Strings.assistantNotConfigured)
                    .accessibilityLabel(noMatches.writeLabel)
                Text(Strings.assistantNotConfigured).font(.caption).foregroundStyle(.secondary)
                Button(Strings.openLibrary) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.openLibrary)
            } else {
                Text(Strings.emptyLibrary)
                Button(Strings.openLibrary) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.openLibrary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button { fill.deliver(mode: fill.preferredMode) } label: {
                    keyCap(Strings.deliver, "↩")
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!fill.deliverEnabled).accessibilityLabel(Strings.deliver)
                    .accessibilityIdentifier("picker-deliver")
                Button { fill.deliver(mode: .copyOnly) } label: { keyCap(Strings.copy, "⌥↩") }
                    .disabled(!fill.canCopyOnly).accessibilityLabel(Strings.copy)
                    .accessibilityIdentifier("picker-copy")
                Button { presentation.model.escape() } label: { keyCap(Strings.back, "⎋") }
                    .accessibilityLabel(Strings.back).accessibilityIdentifier("picker-back")
            } else {
                Button { presentation.model.use(mode: .paste(.standard)) } label: { keyCap(Strings.paste, "↩") }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.usePrompt)
                    .accessibilityIdentifier("picker-use")
                Button { presentation.model.use(mode: .copyOnly) } label: { keyCap(Strings.copy, "⌥↩") }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.copy)
                    .accessibilityIdentifier("picker-copy")
                Button { presentation.model.editSelected() } label: { keyCap(Strings.edit, "⌘↩") }
                    .disabled(presentation.model.selectionIndex == nil).accessibilityLabel(Strings.edit)
                    .accessibilityIdentifier("picker-edit")
                Button { presentation.model.openLibrary() } label: { keyCap(Strings.library, "⌘L") }
                    .accessibilityLabel(Strings.library)
                    .accessibilityIdentifier("picker-library")
            }
            moreActions
        }
        .buttonStyle(.borderless)
        .disabled(presentation.state == .delivering)
    }

    private var moreActions: some View {
        Menu {
            if presentation.showsForgetValues {
                Button(Strings.forgetValues, action: presentation.forgetSelectedValues)
                    .disabled(!presentation.canForgetValues)
                    .accessibilityLabel(Strings.forgetValues)
                    .accessibilityIdentifier("picker-forget-values")
            }
            Button(Strings.setup, action: presentation.showSetup)
            Button(Strings.settings, action: presentation.showSettings)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel(Strings.pickerMore).accessibilityIdentifier("picker-more")
        .fixedSize()
    }

    private func keyCap(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text(keys).foregroundStyle(.secondary)
        }
    }
}
