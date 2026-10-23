/// The original index carries unknown option metadata through edits and removal.
public struct PromptFieldOptionSettings: Equatable, Sendable {
    public var label: String
    public var value: String
    let originalIndex: Int?

    public init(label: String, value: String) {
        self.label = label
        self.value = value
        originalIndex = nil
    }

    init(_ option: FieldOption, index: Int) {
        label = option.label
        value = option.value
        originalIndex = index
    }
}

public enum PromptFieldSettingsIssue: Sendable {
    case missingOptions, invalidDefault
}

/// A staged visual edit. Nil default differs from an explicitly empty default.
public struct PromptFieldSettings: Equatable, Sendable {
    public let name: String
    public let isImplicit: Bool
    public var kind: FieldKind
    public var label: String
    public var description: String?
    public var defaultValue: String?
    public var options: [PromptFieldOptionSettings]
    public var optional: Bool
    public var remember: Bool

    public var validationIssue: PromptFieldSettingsIssue? {
        guard kind == .choice else { return nil }
        guard !options.isEmpty else { return .missingOptions }
        if let defaultValue, !options.contains(where: { $0.value == defaultValue }) {
            return .invalidDefault
        }
        return nil
    }

    init(_ field: PromptField, hasDefault: Bool) {
        name = field.name
        isImplicit = field.isImplicit
        kind = field.kind
        label = field.label
        description = field.description
        defaultValue = hasDefault ? field.defaultValue : nil
        options = field.options.enumerated().map { PromptFieldOptionSettings($0.element, index: $0.offset) }
        optional = field.optional
        remember = field.remember
    }
}
