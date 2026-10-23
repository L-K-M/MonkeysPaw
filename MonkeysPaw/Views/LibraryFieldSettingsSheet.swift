import Foundation
import MonkeysPawCore
import SwiftUI

enum LibraryFieldStrings {
    static let placeholders = "Placeholders"
    static let settings = "Settings…"
    static let implicit = "Implicit"
    static let useDefault = "Use a default value"
    static let defaultValue = "Default value"
    static let choices = "Choices"
    static let choiceLabel = "Label"
    static let choiceValue = "Value"
    static let addChoice = "Add Choice"
    static let optional = "Optional"
    static let remember = "Remember the last value"
    static let missingChoices = "Add at least one choice."
    static let invalidDefault = "The default must match a choice value."
    static let draftHint = "Apply updates this draft. Save commits your changes."
    static let apply = "Apply"

    static func settingsLabel(_ name: String) -> String { "Settings for \(name)" }
    static func removeChoice(_ index: Int) -> String { "Remove choice \(index + 1)" }
    static func issue(_ issue: PromptFieldSettingsIssue) -> String {
        switch issue {
        case .missingOptions: return missingChoices
        case .invalidDefault: return invalidDefault
        }
    }
}

/// Stage controls against one exact prompt/buffer; Apply edits the shared draft.
final class LibraryFieldSettingsDraft: ObservableObject, Identifiable {
    let id = UUID()
    let fieldName: String
    @Published var settings: PromptFieldSettings {
        didSet {
            // Wholesale draft replacement keeps the row-identity array in step.
            let difference = settings.options.count - optionIDs.count
            if difference > 0 { optionIDs += (0..<difference).map { _ in UUID() } }
            if difference < 0 { optionIDs.removeLast(-difference) }
        }
    }
    @Published private(set) var optionIDs: [UUID]
    /// A nil default differs from an explicitly empty literal, so the toggle
    /// and its text stage separately instead of collapsing into one string.
    @Published var hasDefault: Bool
    @Published var defaultText: String
    @Published var descriptionText: String
    let prompt: LibraryPromptSelection?
    let source: String?
    let sourceRevision: UInt64

    init(field: PromptFieldSettings, prompt: LibraryPromptSelection?,
         source: String?, sourceRevision: UInt64) {
        fieldName = field.name
        settings = field
        optionIDs = field.options.map { _ in UUID() }
        hasDefault = field.defaultValue != nil
        defaultText = field.defaultValue ?? ""
        descriptionText = field.description ?? ""
        self.prompt = prompt
        self.source = source
        self.sourceRevision = sourceRevision
    }

    var staged: PromptFieldSettings {
        var staged = settings
        staged.defaultValue = hasDefault ? defaultText : nil
        // An untouched control keeps even an explicit empty description.
        if descriptionText.utf8.elementsEqual((settings.description ?? "").utf8) {
            staged.description = settings.description
        } else {
            staged.description = descriptionText.isEmpty ? nil : descriptionText
        }
        return staged
    }

    var issue: PromptFieldSettingsIssue? { staged.validationIssue }
    var issueMessage: String? { issue.map(LibraryFieldStrings.issue) }

    func removeOption(at index: Int) {
        guard settings.options.indices.contains(index), optionIDs.indices.contains(index) else { return }
        optionIDs.remove(at: index)
        settings.options.remove(at: index)
    }

    func removeOption(id: UUID) {
        guard let index = optionIndex(for: id) else { return }
        removeOption(at: index)
    }

    func addOption() {
        optionIDs.append(UUID())
        settings.options.append(PromptFieldOptionSettings(label: "", value: ""))
    }

    func optionIndex(for id: UUID) -> Int? {
        guard let index = optionIDs.firstIndex(of: id), settings.options.indices.contains(index) else { return nil }
        return index
    }

    func isStale(prompt: LibraryPromptSelection?, source: String?, sourceRevision: UInt64) -> Bool {
        self.prompt != prompt || self.sourceRevision != sourceRevision
            || !Self.sameSource(self.source, source)
    }

    private static func sameSource(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }
}

/// A staged editor for one placeholder, presented from the form's rows.
struct LibraryFieldSettingsSheet: View {
    @ObservedObject var draft: LibraryFieldSettingsDraft
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                controls
                    .padding(16)
            }
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .frame(minWidth: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-field-settings")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "{{" + draft.fieldName + "}}")
                .font(.system(.headline, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("library-field-name")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(EditorStrings.fieldType).foregroundStyle(.secondary)
                    Picker(EditorStrings.fieldType, selection: $draft.settings.kind) {
                        ForEach([FieldKind.text, .multiline, .choice], id: \.self) { kind in
                            Text(EditorStrings.fieldKind(kind)).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(EditorStrings.fieldType)
                    .accessibilityIdentifier("library-field-type")
                }
                GridRow {
                    Text(LibraryNativeStrings.labelLabel).foregroundStyle(.secondary)
                    TextField(LibraryNativeStrings.labelLabel, text: $draft.settings.label)
                        .accessibilityIdentifier("library-field-label")
                }
                GridRow {
                    Text(LibraryNativeStrings.descriptionLabel).foregroundStyle(.secondary)
                    TextField(LibraryNativeStrings.descriptionLabel, text: $draft.descriptionText)
                        .accessibilityIdentifier("library-field-description")
                }
                GridRow(alignment: .top) {
                    Text(EditorStrings.fieldDefault).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(LibraryFieldStrings.useDefault, isOn: $draft.hasDefault)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("library-field-default-toggle")
                        TextField(LibraryFieldStrings.defaultValue, text: $draft.defaultText, axis: .vertical)
                            .lineLimit(1...6)
                            .disabled(!draft.hasDefault)
                            .accessibilityIdentifier("library-field-default")
                    }
                }
                if draft.settings.kind == .choice { choices }
                GridRow(alignment: .top) {
                    Text(EditorStrings.fieldBehaviorHeader).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(LibraryFieldStrings.optional, isOn: $draft.settings.optional)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("library-field-optional")
                        Toggle(LibraryFieldStrings.remember, isOn: $draft.settings.remember)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("library-field-remember")
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            Text(LibraryFieldStrings.draftHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choices: some View {
        GridRow(alignment: .top) {
            Text(LibraryFieldStrings.choices).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                if !draft.settings.options.isEmpty {
                    Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            Text(LibraryFieldStrings.choiceLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(LibraryFieldStrings.choiceValue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("").frame(width: 16)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(draft.optionIDs, id: \.self, content: choiceRow)
                    }
                }
                Button(LibraryFieldStrings.addChoice, action: draft.addOption)
                .accessibilityIdentifier("library-field-choice-add")
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ id: UUID) -> some View {
        if let index = draft.optionIndex(for: id) {
            GridRow {
                TextField(LibraryFieldStrings.choiceLabel, text: choiceBinding(index, \.label))
                    .accessibilityIdentifier("library-field-choice-label-\(index)")
                TextField(LibraryFieldStrings.choiceValue, text: choiceBinding(index, \.value), axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("library-field-choice-value-\(index)")
                Button { draft.removeOption(id: id) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LibraryFieldStrings.removeChoice(index))
                .accessibilityIdentifier("library-field-choice-remove-\(index)")
            }
        }
    }

    func choiceBinding(_ index: Int,
                       _ key: WritableKeyPath<PromptFieldOptionSettings, String>) -> Binding<String> {
        let id = draft.optionIDs.indices.contains(index) ? draft.optionIDs[index] : nil
        // A delayed field-editor commit must follow its choice, not its old row.
        return Binding(get: {
            guard let id, let current = draft.optionIndex(for: id) else { return "" }
            return draft.settings.options[current][keyPath: key]
        }, set: {
            guard let id, let current = draft.optionIndex(for: id) else { return }
            draft.settings.options[current][keyPath: key] = $0
        })
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = draft.issueMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library-field-settings-error")
            }
            Spacer(minLength: 0)
            Button(LibraryDialogStrings.cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("library-field-settings-cancel")
            Button(LibraryFieldStrings.apply, action: onApply)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.issue != nil)
                .accessibilityIdentifier("library-field-settings-apply")
        }
        .padding(12)
    }
}
