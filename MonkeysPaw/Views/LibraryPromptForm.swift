import MonkeysPawCore
import SwiftUI

enum LibraryFormStrings {
    static let title = "Title"
    static let description = "Description"
    static let tags = "Tags"
    static let newTag = "Add a tag"
    static let addTag = "Add"
    static let isPrivate = "Private"
    static let privacyHint = "Never send this prompt to the assistant."
    static let body = "Prompt"
    static let bodyHint = "Use {{name}} for a placeholder."
    static let source = "Source"
    static let unavailable = "Edit Source to fix validation errors and use the form."
    static func removeTag(_ tag: String) -> String { "Remove tag “" + tag + "”" }
}

/// The form and Source feed the same EditorModel draft and discard guard.
struct LibraryPromptForm: View {
    @ObservedObject var presentation: LibraryViewState
    let isVisible: Bool
    @State private var newTag = ""

    var body: some View {
        VStack(spacing: 0) {
            properties
                .id(presentation.sourceRevision)
                .disabled(!presentation.canEditSource || !isVisible)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(LibraryFormStrings.body).font(.headline)
                Text(LibraryFormStrings.bodyHint).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            LibrarySourceEditor(source: presentation.editorState.form?.body ?? "",
                path: presentation.editorState.prompt?.relativePath,
                revision: presentation.sourceRevision,
                isEditable: presentation.canEditSource && presentation.editorState.form != nil,
                onEdit: { presentation.edit(.body($0)) },
                focusRevision: isVisible ? presentation.editorFocusRevision : 0,
                isVisible: isVisible, content: .body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("library-prompt-form")
        .sheet(item: $presentation.fieldSettingsDraft) { draft in
            LibraryFieldSettingsSheet(draft: draft,
                onCancel: presentation.cancelFieldSettings,
                onApply: presentation.applyFieldSettings)
        }
        .onChange(of: presentation.sourceRevision) { _ in newTag = "" }
    }

    private var properties: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(LibraryFormStrings.title).foregroundStyle(.secondary)
                PickerTextInput(value: presentation.editorState.form?.title ?? "",
                    label: LibraryFormStrings.title, identifier: "library-prompt-title",
                    wantsFocus: false, focusRevision: 0,
                    onChange: { presentation.edit(.title($0)) })
            }
            GridRow {
                Text(LibraryFormStrings.description).foregroundStyle(.secondary)
                PickerTextInput(value: presentation.editorState.form?.description ?? "",
                    label: LibraryFormStrings.description, identifier: "library-prompt-description",
                    wantsFocus: false, focusRevision: 0,
                    onChange: { presentation.edit(.description($0)) })
            }
            GridRow(alignment: .top) {
                Text(LibraryFormStrings.tags).foregroundStyle(.secondary)
                tags
            }
            GridRow(alignment: .top) {
                Text("")
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(LibraryFormStrings.isPrivate, isOn: Binding(
                        get: { presentation.editorState.form?.isPrivate ?? false },
                        set: { presentation.edit(.isPrivate($0)) }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("library-prompt-private")
                    Text(LibraryFormStrings.privacyHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let fields = presentation.editorState.form?.fieldSettings, !fields.isEmpty {
                GridRow(alignment: .top) {
                    Text(LibraryFieldStrings.placeholders).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(fields.enumerated()), id: \.offset) { item in
                                if item.offset > 0 { Divider() }
                                fieldRow(item.element)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                    .accessibilityIdentifier("library-field-list")
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Rows stay visible whenever the form renders; only their buttons share
    /// the settings gate so conflicts and guard decisions explain the dimming.
    private func fieldRow(_ field: PromptFieldSettings) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "{{" + field.name + "}}")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            if field.isImplicit {
                Text(LibraryFieldStrings.implicit)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Text(EditorStrings.fieldKind(field.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(LibraryFieldStrings.settings) { presentation.requestFieldSettings(field) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!presentation.canEditFieldSettings || !isVisible)
                .accessibilityLabel(LibraryFieldStrings.settingsLabel(field.name))
                .accessibilityIdentifier("library-field-settings-\(field.name)")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-field-row-\(field.name)")
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tags = presentation.editorState.form?.tags, !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { item in
                            HStack(spacing: 4) {
                                Text(verbatim: item.element).lineLimit(1)
                                Button { removeTag(at: item.offset) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(LibraryFormStrings.removeTag(item.element))
                                .accessibilityIdentifier("library-remove-tag-\(item.offset)")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TextField(LibraryFormStrings.newTag, text: $newTag)
                    .onSubmit(addTag)
                    .accessibilityIdentifier("library-new-tag")
                Button(LibraryFormStrings.addTag, action: addTag)
                    .disabled(newTag.isEmpty)
                    .accessibilityIdentifier("library-add-tag")
            }
        }
    }

    private func addTag() {
        guard presentation.canEditSource, !newTag.isEmpty,
              let form = presentation.editorState.form else { return }
        presentation.edit(.tags(form.tags + [newTag]))
        newTag = ""
    }

    private func removeTag(at index: Int) {
        guard var tags = presentation.editorState.form?.tags, tags.indices.contains(index) else { return }
        tags.remove(at: index)
        presentation.edit(.tags(tags))
    }
}
