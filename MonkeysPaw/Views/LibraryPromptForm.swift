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
    static let details = "Details"
    static let showDetails = "Show Prompt Details"
    static let hideDetails = "Hide Prompt Details"
    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
    static let source = "Source"
    static let unavailable = "Edit Source to fix validation errors and use the form."
    static func removeTag(_ tag: String) -> String { "Remove tag “" + tag + "”" }
    static func placeholderCount(_ count: Int) -> String {
        "\(count) " + (count == 1 ? "Placeholder" : "Placeholders")
    }
}

/// The form and Source feed the same EditorModel draft and discard guard.
struct LibraryPromptForm: View {
    @ObservedObject var presentation: LibraryViewState
    let isVisible: Bool
    @State private var newTag = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                title
                if presentation.isDetailsVisible { properties }
            }
                .padding(12)
                .id(presentation.sourceRevision)
                .disabled(!presentation.canEditSource || !isVisible)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LibraryFormStrings.body).font(.headline)
                    Text(LibraryFormStrings.bodyHint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { presentation.showInspector(.fields) } label: {
                    Label(LibraryFormStrings.placeholderCount(presentation.editorState.fields.count),
                        systemImage: "curlybraces")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("library-show-placeholders")
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
        .disabled(!isVisible)
        .accessibilityIdentifier("library-prompt-form")
        .onChange(of: presentation.sourceRevision) { _ in newTag = "" }
    }

    private var title: some View {
        HStack(spacing: 12) {
            Text(LibraryFormStrings.title).foregroundStyle(.secondary)
            PickerTextInput(value: presentation.editorState.form?.title ?? "",
                label: LibraryFormStrings.title, identifier: "library-prompt-title",
                wantsFocus: false, focusRevision: 0,
                onChange: { presentation.edit(.title($0)) })
            if presentation.editorState.isPrivate {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(LibraryFormStrings.privacyHint)
                    .accessibilityLabel(LibraryFormStrings.isPrivate)
            }
            Button { presentation.toggleDetails() } label: {
                Label(LibraryFormStrings.details,
                    systemImage: presentation.isDetailsVisible ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .help(presentation.isDetailsVisible ? LibraryFormStrings.hideDetails : LibraryFormStrings.showDetails)
            .accessibilityValue(presentation.isDetailsVisible ? LibraryFormStrings.expanded : LibraryFormStrings.collapsed)
            .accessibilityIdentifier("library-details-toggle")
        }
    }

    private var properties: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
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
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
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
