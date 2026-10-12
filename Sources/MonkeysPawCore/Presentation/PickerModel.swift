import Foundation

public struct PickerResultRow: Equatable, Sendable {
    public let identity: PromptIdentity
    public let relativePath: String
    public let title: String
    public let folder: String
    public let tags: [String]
    public let favorite: Bool
    public let previewLine: String?
    public let issues: [PromptIssue]
    public var hasIssues: Bool { !issues.isEmpty }
    public let canRender: Bool

    // Compare path bytes; this hand-written equality must list every stored property.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
            && lhs.title == rhs.title && lhs.folder.utf8.elementsEqual(rhs.folder.utf8)
            && lhs.tags == rhs.tags && lhs.favorite == rhs.favorite
            && lhs.previewLine == rhs.previewLine && lhs.issues == rhs.issues && lhs.canRender == rhs.canRender
    }
}

public enum PickerPreview: Equatable, Sendable {
    case none
    /// Rendered with defaults when possible; otherwise the template body until
    /// form open. Row selection never reads clipboard or remembered text.
    case body(String)
    case issues([PromptIssue])
}

public struct PickerNoMatches: Equatable, Sendable {
    public let query: String
    public var message: String { "No prompts match '\(query)'" }
    public var createTitle: String { query }
    public let createLabel = "Create a prompt"
    public let writeLabel = "Write with the assistant"
    public let openLibraryLabel = "Open the library folder"
}

/// UI-thread intents/state reads and a single-owner onChange hook. Index and snapshot callbacks marshal through MainThread before
/// touching model state. @unchecked Sendable supports those crossings only.
/// No watcher ownership, app wiring or platform view lives in this slice.
public final class PickerModel: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case picker
        case fill
        case delivering
        case done(DeliveryOutcome)
        case closed
    }

    public enum SelectionDirection: Sendable { case up, down }
    public enum Intent: Equatable, Sendable {
        case edit(identity: PromptIdentity, relativePath: String)
        case openLibrary

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.edit(let leftID, let leftPath), .edit(let rightID, let rightPath)):
                return leftID == rightID && leftPath.utf8.elementsEqual(rightPath.utf8)
            case (.openLibrary, .openLibrary): return true
            case (.edit, .openLibrary), (.openLibrary, .edit): return false
            }
        }
    }

    public var onChange: (() -> Void)?
    public private(set) var query = ""
    public private(set) var results: [PickerResultRow] = []
    public private(set) var selectionIndex: Int?
    public private(set) var selectedPreview = PickerPreview.none
    public private(set) var state = State.closed
    public private(set) var fillModel: FillModel?
    public private(set) var requestedIntent: Intent?
    /// Survives reopening so delivery persistence failures remain visible;
    /// cleared when the next use starts.
    public private(set) var persistenceWarnings: [PromptPersistenceWarning] = []
    /// Explicit forget failures use the same onChange hook and remain visible
    /// until a forget succeeds. Only sanitized FileStoreError/LibraryError
    /// values are exposed; delivery warnings keep their existing enum.
    public private(set) var forgetValuesError: Error?
    public private(set) var isResolvingBuiltins = false
    /// Composition supplies folder availability; cached prompts remain usable.
    public var libraryAvailable = true { didSet { onChange?() } }
    public var noMatches: PickerNoMatches? {
        // Empty query on an empty library is not a no-match state (§11.5).
        results.isEmpty && !query.isEmpty ? PickerNoMatches(query: query) : nil
    }

    private let index: PromptIndex
    private let fill: FillService
    private let delivery: DeliveryService
    private let main: MainThread
    private var indexObserver: UUID?
    private var matches: [PromptSearchResult] = []
    private var drafts: [PromptIdentity: [String: String]] = [:]
    private var snapshotGeneration: UInt64 = 0

    public init(index: PromptIndex, fill: FillService, delivery: DeliveryService,
                main: MainThread) {
        self.index = index
        self.fill = fill
        self.delivery = delivery
        self.main = main
        indexObserver = index.addObserver { [weak self] in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self else { return }
                self.refresh(resetSelection: false)
                self.onChange?()
            }
        }
    }

    deinit {
        if let indexObserver { index.removeObserver(indexObserver) }
    }

    public func open() {
        guard state != .delivering, fillModel?.state != .delivering else { return }
        fillModel?.deactivate()
        fillModel = nil
        invalidateSnapshot()
        requestedIntent = nil
        state = .picker
        refresh(resetSelection: true)
        delivery.show()
        onChange?()
    }

    public func setQuery(_ query: String) {
        guard state == .picker else { return }
        invalidateSnapshot()
        self.query = query
        refresh(resetSelection: true)
        onChange?()
    }

    public func moveSelection(_ direction: SelectionDirection) {
        guard state == .picker, let selectionIndex, !results.isEmpty else { return }
        let offset = direction == .up ? -1 : 1
        selectResult(at: min(max(selectionIndex + offset, 0), results.count - 1))
    }

    /// Native result lists select rows directly, including by pointer input.
    public func selectResult(at position: Int) {
        guard state == .picker, results.indices.contains(position) else { return }
        invalidateSnapshot()
        selectionIndex = position
        updateSelectedPreview()
        onChange?()
    }

    public func use(mode: DeliveryMode) {
        guard state == .picker, !isResolvingBuiltins, let entry = selectedEntry else { return }
        guard entry.document.canRender else {
            selectedPreview = .issues(entry.issues)
            onChange?()
            return
        }
        if !entry.document.effectiveFields.isEmpty {
            openFill(entry, mode: mode)
            return
        }

        persistenceWarnings = []
        isResolvingBuiltins = true
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        onChange?()
        fill.builtinSnapshot(for: entry.document) { [weak self] snapshot in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.state == .picker, self.snapshotGeneration == generation else { return }
                self.isResolvingBuiltins = false
                self.deliver(entry, mode: mode, builtins: snapshot)
            }
        }
    }

    public func editSelected() {
        guard state == .picker, let entry = selectedEntry else { return }
        requestedIntent = .edit(identity: entry.identity, relativePath: entry.relativePath)
        onChange?()
    }

    public func openLibrary() {
        guard state == .picker else { return }
        requestedIntent = .openLibrary
        onChange?()
    }

    /// Forget the open form's identity, even if index refresh moved selection;
    /// otherwise use the current selection. Failure retains every draft/value.
    public func forgetSelectedValues() {
        guard !rejectForgetDuringDelivery() else { return }
        let model = state == .fill ? fillModel : nil
        let identity = state == .fill ? model?.identity : selectedEntry?.identity
        guard let identity else {
            failForgetting(LibraryError.invalidIdentity)
            return
        }

        do { try fill.forgetValues(for: identity) }
        catch {
            failForgetting(error)
            return
        }
        drafts[identity] = nil
        completeForgetting(reset: model)
    }

    /// Also available to Settings while the panel is closed. Session drafts
    /// are invalidated only after the persisted reset succeeds. Composition
    /// forwards the returned outcome without reading the mutable UI error.
    @discardableResult
    public func forgetAllValues() -> RememberedValuesOutcome {
        guard !rejectForgetDuringDelivery() else { return .deliveryInFlight }
        do { try fill.forgetAllValues() }
        catch {
            return failForgetting(error)
        }
        drafts = [:]
        completeForgetting(reset: state == .fill ? fillModel : nil)
        return .forgotten
    }

    /// Consume before handling: a handler can publish another change without
    /// dismissing, and must not receive this intent again. Clearing is silent.
    public func takeRequestedIntent() -> Intent? {
        defer { requestedIntent = nil }
        return requestedIntent
    }

    public func escape() {
        switch state {
        case .fill:
            fillModel?.escape()
        case .picker, .done:
            close()
        case .delivering, .closed:
            break
        }
    }

    /// Blur and toggle-off close the entire panel while retaining a fill draft.
    /// Escape remains a separate intent: from fill it returns to the picker.
    public func dismiss() {
        switch state {
        case .fill:
            fillModel?.deactivate()
            close()
        case .picker, .done:
            close()
        case .delivering, .closed:
            break
        }
    }

    private var selectedEntry: LibraryEntry? {
        guard let selectionIndex, matches.indices.contains(selectionIndex) else { return nil }
        return matches[selectionIndex].entry
    }

    /// Returns true and already reports `forgetValuesError` (with onChange)
    /// when a delivery is in flight; callers must not report it again.
    private func rejectForgetDuringDelivery() -> Bool {
        guard state == .delivering || fillModel?.state == .delivering else { return false }
        // Pending learning would restore the delivered values after a reset.
        failForgetting(LibraryError.operationFailed)
        return true
    }

    @discardableResult
    private func failForgetting(_ error: Error) -> RememberedValuesOutcome {
        let outcome: RememberedValuesOutcome
        if let error = error as? FileStoreError {
            forgetValuesError = error
            outcome = .fileStoreFailure(error)
        } else {
            let error = error as? LibraryError ?? .operationFailed
            forgetValuesError = error
            outcome = .libraryFailure(error)
        }
        onChange?()
        return outcome
    }

    private func completeForgetting(reset model: FillModel?) {
        forgetValuesError = nil
        persistenceWarnings = []
        // A fieldless use may still be waiting for a snapshot. Retire that
        // delivery request; the held form owns and retains its own snapshot.
        invalidateSnapshot()
        model?.resetToDefaults()
        // The form view can own its onChange hook, so notify the picker too.
        onChange?()
    }

    private func openFill(_ entry: LibraryEntry, mode: DeliveryMode) {
        let model = FillModel(entry: entry, form: fill.form(for: entry), draft: drafts[entry.identity],
                              preferredMode: mode, fill: fill, delivery: delivery, index: index, main: main,
                              onDraft: { [weak self] in self?.drafts[entry.identity] = $0 },
                              onDelivering: { [weak self] in
                                  self?.state = .delivering
                                  self?.onChange?()
                              },
                              onBack: { [weak self] in
                                  guard let self else { return }
                                  self.fillModel = nil
                                  self.state = .picker
                                  self.refresh(resetSelection: false)
                                  self.onChange?()
                              }, onCancel: { [weak self] in self?.close() },
                              onDelivered: { [weak self] outcome, warnings in
                                  self?.finishDelivery(entry.identity, outcome: outcome, warnings: warnings)
                              })
        fillModel = model
        persistenceWarnings = model.persistenceWarnings
        state = .fill
        model.onChange = { [weak self, weak model] in
            guard let self, let model, self.fillModel === model else { return }
            self.onChange?()
        }
        onChange?()
        model.open()
    }

    private func deliver(_ entry: LibraryEntry, mode: DeliveryMode, builtins: PromptBuiltinValues) {
        let text: String
        do { text = try fill.render(entry.document, values: [:], builtins: builtins) }
        catch {
            // The entry already passed canRender; unexpected renderer failures
            // still leave its template body visible.
            selectedPreview = .body(entry.document.body)
            onChange?()
            return
        }
        state = .delivering
        onChange?()
        delivery.deliver(text, mode: mode) { [self] outcome in
            main.run { [self] in
                var warnings: [PromptPersistenceWarning] = []
                do { try index.recordUse(of: entry.identity) }
                catch { warnings.append(.usageNotSaved) }
                finishDelivery(entry.identity, outcome: outcome, warnings: warnings)
            }
        }
    }

    private func finishDelivery(_ identity: PromptIdentity, outcome: DeliveryOutcome,
                                warnings: [PromptPersistenceWarning]) {
        drafts[identity] = nil
        persistenceWarnings = warnings
        state = .done(outcome)
        refresh(resetSelection: true)
        onChange?()
    }

    private func close() {
        invalidateSnapshot()
        fillModel = nil
        state = .closed
        // Use the same queue as show/delivery. Dismissal hides through the
        // injected PanelWindow and restores only while our app is frontmost.
        delivery.dismiss()
        onChange?()
    }

    private func invalidateSnapshot() {
        snapshotGeneration &+= 1
        isResolvingBuiltins = false
    }

    private func refresh(resetSelection: Bool) {
        let previous = resetSelection ? nil : selectedEntry?.relativePath
        matches = index.search(query)
        results = matches.map { result in
            let entry = result.entry
            let front = entry.document.frontMatter
            return PickerResultRow(identity: entry.identity, relativePath: entry.relativePath,
                                   title: front.title, folder: entry.folder, tags: front.tags,
                                   favorite: front.favorite, previewLine: front.description,
                                   issues: entry.issues, canRender: entry.document.canRender)
        }
        selectionIndex = previous.flatMap { path in
            matches.firstIndex { $0.relativePath.utf8.elementsEqual(path.utf8) }
        } ?? (matches.isEmpty ? nil : 0)
        updateSelectedPreview()
    }

    private func updateSelectedPreview() {
        guard let entry = selectedEntry else {
            selectedPreview = .none
            return
        }
        guard entry.document.canRender else {
            selectedPreview = .issues(entry.issues)
            return
        }
        switch fill.preview(entry.document, values: [:], builtins: PromptBuiltinValues()) {
        case .rendered(let text): selectedPreview = .body(text)
        case .blocked: selectedPreview = .body(entry.document.body)
        }
    }
}
