/// How the field's current value was produced, for card provenance display.
public enum FieldProvenance: Equatable, Sendable {
    case defaultValue
    case remembered
    case draft
    case typed
}

/// View state for a control. Metadata is immutable; views change values only
/// through FillModel intents. id/name and Tab order follow body first use.
public struct FillFieldState: Equatable, Sendable {
    private let field: FillFormField
    public var id: String { field.name }
    public var name: String { field.name }
    public var kind: FieldKind { field.kind }
    public var label: String { field.label }
    public var description: String? { field.description }
    public var options: [FieldOption] { field.options }
    public var optional: Bool { field.optional }
    public var remember: Bool { field.remember }
    public fileprivate(set) var value: String
    public private(set) var provenance: FieldProvenance

    init(_ field: FillFormField, value: String, provenance: FieldProvenance) {
        self.field = field
        self.value = value
        self.provenance = provenance
    }

    /// Value and provenance move together so card badges cannot drift.
    mutating func update(value: String, provenance: FieldProvenance) {
        self.value = value
        self.provenance = provenance
    }
}

/// Intents, state reads and onChange ownership belong to the injected UI
/// thread, just like PickerModel. Async snapshots return through MainThread.
/// @unchecked Sendable permits those callbacks, not cross-thread intents.
/// Forms are interactive immediately; delivery waits for the builtin snapshot.
public final class FillModel: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case editing
        case delivering
        case done(DeliveryOutcome)
        case closed
    }

    /// Single owner; the front end republishes changes on its UI thread.
    public var onChange: (() -> Void)?
    public private(set) var fields: [FillFieldState]
    public private(set) var focusIndex: Int?
    public private(set) var preview: FillPreview
    public private(set) var builtinsResolved = false
    public private(set) var state = State.editing
    public private(set) var persistenceWarnings: [PromptPersistenceWarning]
    /// The picker carries a terminal/copy selection into the form. Views use
    /// this for the primary Deliver action; explicit chords pass their mode.
    public let preferredMode: DeliveryMode
    public var deliveryHint: String { delivery.hint(for: preferredMode) }
    public let issues: [PromptIssue]
    public let canRender: Bool
    public let isReadOnly: Bool
    public let card: PromptCard
    /// Card header metadata only; the view must not reach the document.
    public var title: String { entry.document.frontMatter.title }
    public var folder: String { entry.folder }

    public var deliverEnabled: Bool {
        guard state == .editing, builtinsResolved, canRender else { return false }
        if case .rendered = preview { return true }
        return false
    }
    public var canCopyOnly: Bool { deliverEnabled }
    public var values: [String: String] {
        Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })
    }

    /// First required field still empty, for card attention display.
    public var missingRequiredFieldIndex: Int? {
        fields.firstIndex { !$0.optional && $0.value.isEmpty }
    }

    /// Share of required fields holding a value; 1 when nothing is required.
    public var warmth: Double {
        let required = fields.filter { !$0.optional }
        guard !required.isEmpty else { return 1 }
        return Double(required.count { !$0.value.isEmpty }) / Double(required.count)
    }

    /// Card display of a resolved builtin snapshot field; nil until resolved.
    public func builtinText(_ name: BuiltinName) -> String? {
        guard builtinsResolved else { return nil }
        switch name {
        case .clipboard: return builtins.clipboard
        case .date: return builtins.date
        case .time: return builtins.time
        }
    }

    /// Card header summary of the clipboard snapshot; nil until resolved and
    /// only when this template uses the clipboard builtin.
    public var clipboardSummary: ClipboardSummary? {
        resolvedClipboardSummary
    }

    private let entry: LibraryEntry
    private let fill: FillService
    private let delivery: DeliveryService
    private let index: PromptIndex
    private let main: MainThread
    private let repeatService: RepeatService?
    private let onDraft: ([String: String]) -> Void
    private let onDelivering: () -> Void
    private let onBack: () -> Void
    private let onCancel: () -> Void
    private let onDelivered: (DeliveryOutcome, [PromptPersistenceWarning]) -> Void
    private var builtins = PromptBuiltinValues()
    private var resolvedClipboardSummary: ClipboardSummary?
    private var retainsDraft = true

    /// The held form can outlive an index refresh that selects another prompt.
    var identity: PromptIdentity { entry.identity }

    init(entry: LibraryEntry, form: FillForm, draft: [String: String]?, preferredMode: DeliveryMode,
         fill: FillService, delivery: DeliveryService, index: PromptIndex, main: MainThread,
         repeatService: RepeatService? = nil,
         onDraft: @escaping ([String: String]) -> Void, onDelivering: @escaping () -> Void,
         onBack: @escaping () -> Void,
         onCancel: @escaping () -> Void,
         onDelivered: @escaping (DeliveryOutcome, [PromptPersistenceWarning]) -> Void) {
        self.entry = entry
        self.fill = fill
        self.delivery = delivery
        self.index = index
        self.main = main
        self.repeatService = repeatService
        self.onDraft = onDraft
        self.onDelivering = onDelivering
        self.onBack = onBack
        self.onCancel = onCancel
        self.onDelivered = onDelivered
        self.preferredMode = preferredMode
        fields = form.fields.map { field in
            if let held = draft?[field.name] {
                return FillFieldState(field, value: held, provenance: .draft)
            }
            return FillFieldState(field, value: field.prefill,
                                  provenance: field.prefillSource == .remembered ? .remembered : .defaultValue)
        }
        focusIndex = fields.isEmpty ? nil : 0
        card = PromptCard(document: entry.document)
        issues = form.issues
        canRender = form.canRender
        isReadOnly = form.isReadOnly
        persistenceWarnings = form.warning.map { [$0] } ?? []
        let initial = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })
        preview = fill.preview(entry.document, values: initial, builtins: builtins)
    }

    /// Called once after the picker owns this model. Closing/deactivating it
    /// makes a late clipboard callback inert, including after another reopen.
    func open() {
        fill.builtinSnapshot(for: entry.document) { [weak self] snapshot in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.state == .editing else { return }
                self.builtins = snapshot
                if self.entry.document.template.builtins.contains(.clipboard) {
                    self.resolvedClipboardSummary = ClipboardSummary(snapshot.clipboard ?? "")
                }
                self.builtinsResolved = true
                self.updatePreview()
                self.onChange?()
            }
        }
    }

    public func setValue(_ value: String, name: String) {
        guard state == .editing, let position = fields.firstIndex(where: { $0.name == name }) else { return }
        fields[position].update(value: value, provenance: .typed)
        updatePreview()
        // Keep the draft current even if a platform blur hides the panel.
        retainsDraft = true
        onDraft(values)
        onChange?()
    }

    public func focusNext() { moveFocus(by: 1) }
    public func focusPrevious() { moveFocus(by: -1) }

    /// Pointer/native focus changes keep keyboard traversal in field order.
    public func focusField(at position: Int) {
        guard state == .editing, fields.indices.contains(position), focusIndex != position else { return }
        focusIndex = position
        onChange?()
    }

    public func deliver(mode: DeliveryMode) {
        guard deliverEnabled else { return }
        let delivered = values
        let text: String
        do { text = try fill.render(entry.document, values: delivered, builtins: builtins) }
        catch {
            updatePreview()
            onChange?()
            return
        }
        state = .delivering
        let recording = repeatService?.beginRecording()
        onDelivering()
        onChange?()
        delivery.captureInvocation(source: .picker) { [self] invocation in
            delivery.deliver(text, mode: mode, invocation: invocation, isValid: { [self] in
                recording.map { repeatService?.isCurrent($0) == true } ?? true
            }) { [self] outcome in
                main.run { [self] in
                    // Copy-only and paste fallback are deliveries too. Learning
                    // failures are visible, but cannot cancel the clipboard action.
                    guard state == .delivering else { return }
                    guard let outcome else { state = .closed; onChange?(); return }
                    guard recording.map({ repeatService?.isCurrent($0) == true }) ?? true else {
                        finishDelivery(outcome)
                        return
                    }
                    do {
                        try fill.rememberedOnDelivery(identity: entry.identity,
                                                      fields: entry.document.effectiveFields, values: delivered)
                    } catch { persistenceWarnings.append(.rememberedValuesNotSaved) }
                    do { try index.recordUse(of: entry.identity) }
                    catch { persistenceWarnings.append(.usageNotSaved) }
                    if let repeatService, let recording {
                        repeatService.recordCompleted(entry: entry, values: delivered, mode: mode, ticket: recording) { [self] saved in
                            persistenceWarnings += saved
                            finishDelivery(outcome)
                        }
                    } else { finishDelivery(outcome) }
                }
            }
        }
    }

    private func finishDelivery(_ outcome: DeliveryOutcome) {
        state = .done(outcome)
        onDelivered(outcome, persistenceWarnings)
        onChange?()
    }

    public func escape() {
        guard state == .editing else { return }
        captureDraft()
        state = .closed
        onBack()
        onChange?()
    }

    public func cancel() {
        guard state == .editing else { return }
        captureDraft()
        state = .closed
        onCancel()
        onChange?()
    }

    /// A new picker open after blur retains drafts unless reset, and retires
    /// this snapshot.
    func deactivate() {
        guard state == .editing else { return }
        captureDraft()
        state = .closed
    }

    /// Picker calls this only after forgetting persisted values succeeds. Keep
    /// the held metadata, focus and builtin snapshot, including a pending read.
    /// Drafts are cleared by the picker, so resetting must not republish them.
    func resetToDefaults() {
        guard state == .editing else { return }
        let defaults = Dictionary(entry.document.effectiveFields.map { ($0.name, $0.defaultValue) },
                                  uniquingKeysWith: { _, new in new })
        for position in fields.indices {
            fields[position].update(value: defaults[fields[position].name] ?? "", provenance: .defaultValue)
        }
        retainsDraft = false
        persistenceWarnings = []
        updatePreview()
        onChange?()
    }

    private func captureDraft() {
        // Closing a reset form must not recreate the forgotten draft. Only a
        // later edit starts a new draft, so reopening sees current defaults.
        guard retainsDraft else { return }
        onDraft(values)
    }

    private func moveFocus(by offset: Int) {
        guard state == .editing, let focusIndex, !fields.isEmpty else { return }
        focusField(at: (focusIndex + offset + fields.count) % fields.count)
    }

    private func updatePreview() {
        preview = fill.preview(entry.document, values: values, builtins: builtins)
    }
}
