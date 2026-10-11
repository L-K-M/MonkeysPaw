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

    init(_ field: FillFormField, value: String) {
        self.field = field
        self.value = value
    }
}

/// Intents, state reads and onChange ownership belong to the injected UI
/// thread, just like PanelModel. Async snapshots return through MainThread.
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
    public let issues: [PromptIssue]
    public let canRender: Bool
    public let isReadOnly: Bool

    public var deliverEnabled: Bool {
        guard state == .editing, builtinsResolved, canRender else { return false }
        if case .rendered = preview { return true }
        return false
    }
    public var canCopyOnly: Bool { deliverEnabled }
    public var values: [String: String] {
        Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })
    }

    private let entry: LibraryEntry
    private let fill: FillService
    private let delivery: DeliveryService
    private let index: PromptIndex
    private let main: MainThread
    private let onDraft: ([String: String]) -> Void
    private let onDelivering: () -> Void
    private let onBack: () -> Void
    private let onCancel: () -> Void
    private let onDelivered: (DeliveryOutcome, [PromptPersistenceWarning]) -> Void
    private var builtins = PromptBuiltinValues()

    init(entry: LibraryEntry, form: FillForm, draft: [String: String]?, preferredMode: DeliveryMode,
         fill: FillService, delivery: DeliveryService, index: PromptIndex, main: MainThread,
         onDraft: @escaping ([String: String]) -> Void, onDelivering: @escaping () -> Void,
         onBack: @escaping () -> Void,
         onCancel: @escaping () -> Void,
         onDelivered: @escaping (DeliveryOutcome, [PromptPersistenceWarning]) -> Void) {
        self.entry = entry
        self.fill = fill
        self.delivery = delivery
        self.index = index
        self.main = main
        self.onDraft = onDraft
        self.onDelivering = onDelivering
        self.onBack = onBack
        self.onCancel = onCancel
        self.onDelivered = onDelivered
        self.preferredMode = preferredMode
        fields = form.fields.map { FillFieldState($0, value: draft?[$0.name] ?? $0.prefill) }
        focusIndex = fields.isEmpty ? nil : 0
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
                self.builtinsResolved = true
                self.updatePreview()
                self.onChange?()
            }
        }
    }

    public func setValue(_ value: String, name: String) {
        guard state == .editing, let position = fields.firstIndex(where: { $0.name == name }) else { return }
        fields[position].value = value
        updatePreview()
        // Keep the draft current even if a platform blur hides the panel.
        onDraft(values)
        onChange?()
    }

    public func focusNext() { moveFocus(by: 1) }
    public func focusPrevious() { moveFocus(by: -1) }

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
        onDelivering()
        onChange?()
        delivery.deliver(text, mode: mode) { [self] outcome in
            main.run { [self] in
                // Copy-only and paste fallback are deliveries too. Learning
                // failures are visible, but cannot cancel the clipboard action.
                guard state == .delivering else { return }
                do {
                    try fill.rememberedOnDelivery(identity: entry.identity,
                                                  fields: entry.document.effectiveFields, values: delivered)
                } catch { persistenceWarnings.append(.rememberedValuesNotSaved) }
                do { try index.recordUse(of: entry.identity) }
                catch { persistenceWarnings.append(.usageNotSaved) }
                state = .done(outcome)
                onDelivered(outcome, persistenceWarnings)
                onChange?()
            }
        }
    }

    public func escape() {
        guard state == .editing else { return }
        onDraft(values)
        state = .closed
        onBack()
        onChange?()
    }

    public func cancel() {
        guard state == .editing else { return }
        onDraft(values)
        state = .closed
        onCancel()
        onChange?()
    }

    /// A new picker open after blur retains values and retires this snapshot.
    func deactivate() {
        guard state == .editing else { return }
        onDraft(values)
        state = .closed
    }

    private func moveFocus(by offset: Int) {
        guard state == .editing, let focusIndex, !fields.isEmpty else { return }
        self.focusIndex = (focusIndex + offset + fields.count) % fields.count
        onChange?()
    }

    private func updatePreview() {
        preview = fill.preview(entry.document, values: values, builtins: builtins)
    }
}
