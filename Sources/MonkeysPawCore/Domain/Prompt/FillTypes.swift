/// Where a field's initial value came from at form open.
public enum PrefillSource: Equatable, Sendable {
    case remembered
    case defaultValue
}

/// Metadata and initial value in body first-use order. Remembered text takes
/// precedence over a declared default, including an explicitly empty string.
public struct FillFormField: Equatable, Sendable {
    public let name: String
    public let kind: FieldKind
    public let label: String
    public let description: String?
    public let options: [FieldOption]
    public let optional: Bool
    public let remember: Bool
    public let prefill: String
    public let prefillSource: PrefillSource

    init(_ field: PromptField, prefill: String, prefillSource: PrefillSource = .defaultValue) {
        name = field.name
        kind = field.kind
        label = field.label
        description = field.description
        options = field.options
        optional = field.optional
        remember = field.remember
        self.prefill = prefill
        self.prefillSource = prefillSource
    }
}

public struct FillForm: Equatable, Sendable {
    public let fields: [FillFormField]
    public let issues: [PromptIssue]
    public let canRender: Bool
    public let isReadOnly: Bool
    /// A failed remembered-state read uses defaults and remains visible to the
    /// caller. It never resets or overwrites that state.
    public let warning: PromptPersistenceWarning?
}

/// Live fill states are data, including the field/builtin that blocks render.
public enum FillPreview: Equatable, Sendable {
    case rendered(String)
    case blocked(PromptRenderError, issues: [PromptIssue])
}

/// Local learning is best-effort: failure does not cancel the user's delivery.
/// Models expose these sanitized warnings without file paths or user values.
public enum PromptPersistenceWarning: String, Sendable {
    case rememberedValuesUnavailable
    case rememberedValuesNotSaved
    case usageNotSaved
    case lastDeliveryNotSaved
}
