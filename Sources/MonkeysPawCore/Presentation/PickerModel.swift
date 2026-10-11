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

/// UI-thread intents/state reads and a single-owner onChange hook, matching
/// PanelModel. Index and snapshot callbacks marshal through MainThread before
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
    }

    public var onChange: (() -> Void)?
    public private(set) var query = ""
    public private(set) var results: [PickerResultRow] = []
    public private(set) var selectionIndex: Int?
    public private(set) var selectedPreview = PickerPreview.none
    public private(set) var state = State.closed
    public private(set) var fillModel: FillModel?
    public private(set) var requestedIntent: Intent?
    public private(set) var persistenceWarnings: [PromptPersistenceWarning] = []
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
    private var matches: [PromptSearchResult] = []
    private var drafts: [PromptIdentity: [String: String]] = [:]
    private var snapshotGeneration: UInt64 = 0

    public init(index: PromptIndex, fill: FillService, delivery: DeliveryService,
                main: MainThread) {
        self.index = index
        self.fill = fill
        self.delivery = delivery
        self.main = main
        index.setOnChange { [weak self] in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self else { return }
                self.refresh(resetSelection: false)
                self.onChange?()
            }
        }
    }

    // A released model must leave the hook clear: setOnChange asserts
    // clear-before-install, so a stale closure would block a replacement owner.
    deinit { index.setOnChange(nil) }

    public func open() {
        guard state != .delivering, fillModel?.state != .delivering else { return }
        fillModel?.deactivate()
        fillModel = nil
        invalidateSnapshot()
        persistenceWarnings = []
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
        invalidateSnapshot()
        let offset = direction == .up ? -1 : 1
        self.selectionIndex = min(max(selectionIndex + offset, 0), results.count - 1)
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

    private var selectedEntry: LibraryEntry? {
        guard let selectionIndex, matches.indices.contains(selectionIndex) else { return nil }
        return matches[selectionIndex].entry
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
