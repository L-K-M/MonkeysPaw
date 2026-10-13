import Foundation

public enum EditorFailure: Equatable, Sendable {
    case editing(PromptEditingFailure)
    case invalid([PromptIssue])
    case readOnly(PromptReadOnlyReason)
}

public enum EditorStatus: Equatable, Sendable {
    case idle, loading, saving, commandRunning, saved
    case failed(EditorFailure)
}

/// The same guard serves navigation and the model's stamped file commands.
public enum EditorDiscardAction: Equatable, Sendable {
    case open(LibraryPromptSelection)
    case close, revert, rename, move, delete, librarySwitch, quit
}

public enum EditorDecision: Equatable, Sendable { case save, discard, cancel }
public enum EditorGuardResult: Equatable, Sendable { case allowed, cancelled, inactive }

public struct EditorPendingDecision: Equatable, Sendable {
    public let id: UUID
    public let action: EditorDiscardAction
}

public enum EditorConflictChoice: Equatable, Sendable {
    case keepMine, takeTheirs, saveAsCopy, discard
}

public struct EditorConflict: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case modified, deleted }
    public fileprivate(set) var kind: Kind
    public fileprivate(set) var stamp: FileStamp?
    public fileprivate(set) var theirsSource: String?
    public fileprivate(set) var readOnlyReason: PromptReadOnlyReason?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var failure: PromptEditingFailure?

    public var choices: [EditorConflictChoice] {
        kind == .deleted ? [.keepMine, .saveAsCopy, .discard] : [.keepMine, .takeTheirs, .saveAsCopy]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.stamp == rhs.stamp
            && editorSourceEqual(lhs.theirsSource, rhs.theirsSource)
            && lhs.readOnlyReason == rhs.readOnlyReason && lhs.isLoading == rhs.isLoading
            && lhs.failure == rhs.failure
    }
}

/// Each id distinguishes a new commit, including deleting a restored prompt again.
enum EditorCommittedSelectionChange: Equatable, Sendable {
    case adopted(from: LibraryPromptSelection, to: LibraryPromptSelection, id: UUID)
    case deleted(LibraryPromptSelection, id: UUID)
}

public struct EditorState: Equatable, Sendable {
    public fileprivate(set) var prompt: LibraryPromptSelection?
    /// Nil for undecodable/oversized sources, rather than fabricated text.
    public fileprivate(set) var source: String?
    public fileprivate(set) var stamp: FileStamp?
    public fileprivate(set) var isDirty = false
    public fileprivate(set) var status = EditorStatus.idle
    public fileprivate(set) var readOnlyReason: PromptReadOnlyReason?
    public fileprivate(set) var issues: [PromptIssue] = []
    public fileprivate(set) var fields: [PromptField] = []
    public fileprivate(set) var preview = ""
    public fileprivate(set) var previewFailure: PromptRenderError?
    public fileprivate(set) var conflict: EditorConflict?
    public fileprivate(set) var pendingDecision: EditorPendingDecision?
    public fileprivate(set) var queuedActions: [EditorDiscardAction] = []
    public fileprivate(set) var historyMaintenanceFailed = false
    public fileprivate(set) var provenanceMaintenanceFailed = false
    public fileprivate(set) var lastCopy: LibraryPromptSelection?
    public fileprivate(set) var history = EditorHistoryState()
    fileprivate(set) var committedSelectionChange: EditorCommittedSelectionChange?

    public var canEdit: Bool {
        source != nil && readOnlyReason == nil && status != .loading && status != .commandRunning
    }
    public var canSave: Bool { canEdit && status != .saving }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prompt == rhs.prompt && editorSourceEqual(lhs.source, rhs.source)
            && lhs.stamp == rhs.stamp && lhs.isDirty == rhs.isDirty && lhs.status == rhs.status
            && lhs.readOnlyReason == rhs.readOnlyReason && lhs.issues == rhs.issues
            && lhs.fields == rhs.fields && editorSourceEqual(lhs.preview, rhs.preview)
            && lhs.previewFailure == rhs.previewFailure && lhs.conflict == rhs.conflict
            && lhs.pendingDecision == rhs.pendingDecision && lhs.queuedActions == rhs.queuedActions
            && lhs.historyMaintenanceFailed == rhs.historyMaintenanceFailed
            && lhs.provenanceMaintenanceFailed == rhs.provenanceMaintenanceFailed && lhs.lastCopy == rhs.lastCopy
            && lhs.history == rhs.history && lhs.committedSelectionChange == rhs.committedSelectionChange
    }
}

public struct EditorHistoryState: Equatable, Sendable {
    public fileprivate(set) var revisions: [PromptHistorySnapshot] = []
    public fileprivate(set) var selectedRevision: HistoryRevision?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var failure: PromptEditingFailure?
    public var previewSource: String? {
        revisions.first { $0.revision == selectedRevision }?.source
    }
}

/// UI-thread intents/state, like LibraryBrowserModel. All replies and observer
/// notifications use MainThread. The service owns worker I/O and session
/// cancellation; weak captures keep queued work from retaining this model.
public final class EditorModel: @unchecked Sendable {
    public var onChange: (() -> Void)?
    public private(set) var state = EditorState()

    private struct GuardRequest {
        let decision: EditorPendingDecision
        let operation: ((EditorModel) -> Void)?
        let completion: (EditorGuardResult) -> Void
    }

    private enum LoadPurpose { case replace, inspectConflict, takeTheirs, reconcileCopy }
    private enum SavePurpose { case original, copy }

    private let editing: PromptEditingService
    private let clock: WallClock
    private let timeZone: () -> TimeZone
    private let main: MainThread
    private var session: PromptEditingSession?
    private var generation: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var historyRequested = false
    private var commandHasExternalChange = false
    // The service drops retired replies; the model still owes its caller one.
    private var commandCompletion: ((PromptCommandOutcome) -> Void)?
    private var isActive = true
    private var baseline: LoadedPrompt?
    private var document: PromptDocument?
    private var assistantRevision: UInt64 = 0
    private var assistantPermit: AssistantSavePermit?
    private var assistantDecisionID: UUID?
    private var requests: [GuardRequest] = []
    private var pendingRequest: GuardRequest?
    private var savesDecision = false
    private var observers: [UUID: (EditorState) -> Void] = [:]
    private var observerOrder: [UUID] = []
    private var lastPublishedState = EditorState()
    private var isPublishing = false
    private var previewFormatters: (zone: TimeZone, date: DateFormatter, time: DateFormatter)?

    public init(editing: PromptEditingService, clock: WallClock,
                timeZone: @escaping () -> TimeZone, main: MainThread) {
        self.editing = editing
        self.clock = clock
        self.timeZone = timeZone
        self.main = main
    }

    deinit { deactivate() }

    /// Capture at the assistant action, before any later edit can change its
    /// baseline. Conflicts, guard decisions and editor I/O must first be resolved.
    public var assistantSnapshot: AssistantEditorSnapshot? {
        guard isActive, let source = state.source, let prompt = state.prompt,
              let session, let stamp = state.stamp else { return nil }
        let availability: AssistantEditorAvailability
        if state.conflict != nil { availability = .conflicted }
        else if pendingRequest != nil || !requests.isEmpty || state.status == .loading || isWriting {
            availability = .busy
        }
        else { availability = .available }
        let snapshotSession = PromptEditingSession(token: session.token, isInactive: session.isInactive,
                                                   loadedID: baseline?.document.frontMatter.id)
        return AssistantEditorSnapshot(source: source, relativePath: prompt.relativePath,
            revision: assistantRevision, session: snapshotSession, stamp: stamp, availability: availability)
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (EditorState) -> Void) -> UUID {
        let token = UUID()
        guard isActive else { return token }
        observers[token] = observer
        observerOrder.append(token)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
        observerOrder.removeAll { $0 == token }
    }

    /// Composition retires this model before replacing the library graph.
    /// This is forced retirement, not a user discard intent; use the guard for
    /// a requested library switch. Deactivation of the shared service is owned
    /// by composition, since another consumer may still hold that graph.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        retireSession()
        let abandoned = (pendingRequest.map { [$0] } ?? []) + requests
        requests = []
        pendingRequest = nil
        savesDecision = false
        observers = [:]
        observerOrder = []
        onChange = nil
        main.run { abandoned.forEach { $0.completion(.inactive) } }
    }

    public func open(_ selection: LibraryPromptSelection) {
        guard isActive, selection != state.prompt else { return }
        request(.open(selection))
    }

    public func close() { request(.close) }
    public func revert() { request(.revert) }

    /// FIFO, including while saving. The decision token prevents an old dialog
    /// from resolving a newer request. Callbacks run only after the guard has
    /// been rechecked on MainThread, even when that port queues its work.
    @discardableResult
    public func request(_ action: EditorDiscardAction,
                        completion: @escaping (EditorGuardResult) -> Void = { _ in }) -> UUID {
        enqueue(action, operation: nil, completion: completion)
    }

    @discardableResult
    private func enqueue(_ action: EditorDiscardAction, operation: ((EditorModel) -> Void)?,
                         decisionID: UUID = UUID(),
                         completion: @escaping (EditorGuardResult) -> Void) -> UUID {
        let decision = EditorPendingDecision(id: decisionID, action: action)
        guard isActive else {
            main.run { completion(.inactive) }
            return decision.id
        }
        requests.append(GuardRequest(decision: decision, operation: operation, completion: completion))
        updateQueuedActions()
        changed()
        main.run { [weak self] in self?.processRequests() }
        return decision.id
    }

    public func resolveDecision(_ decision: EditorDecision, id: UUID) {
        guard isActive, !isWriting,
              let request = pendingRequest, request.decision.id == id,
              state.pendingDecision?.id == id else { return }
        switch decision {
        case .save:
            savesDecision = true
            save()
        case .discard:
            restoreBaseline()
            finishDecision(.allowed)
        case .cancel:
            finishDecision(.cancelled)
        }
    }

    public func edit(_ text: String) {
        guard isActive, state.canEdit, !editorSourceEqual(state.source, text) else { return }
        assistantPermit?.invalidate(.conflict(.changedBuffer))
        state.source = text
        state.isDirty = !editorSourceEqual(text, baseline?.source)
        if state.status != .saving { state.status = .idle }
        updateDocument(PromptCodec.parse(text, filename: filename))
        changed()
    }

    public func save() {
        guard isActive, state.status != .loading, !isWriting else { return }
        if let reason = state.readOnlyReason {
            savesDecision = false
            state.status = .failed(.readOnly(reason))
            changed()
            return
        }
        startSave(.original, expectedStamp: state.stamp)
    }

    public func saveAsCopy() {
        guard isActive, state.canSave else { return }
        startSave(.copy, expectedStamp: nil)
    }

    public func resolveConflict(_ choice: EditorConflictChoice) {
        guard isActive, !isWriting, let conflict = state.conflict,
              conflict.choices.contains(choice) else { return }
        switch choice {
        case .keepMine:
            savesDecision = pendingRequest != nil
            startSave(.original, expectedStamp: conflict.stamp)
        case .takeTheirs: load(.takeTheirs)
        case .saveAsCopy:
            savesDecision = pendingRequest != nil
            saveAsCopy()
        case .discard:
            resetEditor()
            resumeDecisionAfterDiscard()
            changed()
        }
    }

    /// Browser seam: nil delegates unrelated prompts to its existing service.
    /// Open prompts always use this session, including clean favourite saves,
    /// so an app-owned stamp cannot become a delayed false conflict.
    public func toggleFavorite(of entry: LibraryEntry) -> PromptFavoriteOutcome? {
        guard isActive, state.prompt?.relativePath == RelativePath(entry.relativePath) else { return nil }
        guard state.canEdit, let document else {
            if case .unsupportedFormat(let format) = state.readOnlyReason {
                return .writeFailure(.unsupportedFormat(format))
            }
            return .writeFailure(.invalidPrompt)
        }
        do {
            let draft = try PromptCodec.settingFavorite(!document.frontMatter.favorite,
                                                       in: document, filename: filename)
            let keepsDraft = state.isDirty || state.status == .saving || state.conflict != nil
            edit(draft.source)
            if keepsDraft { return .editedBuffer }
            save()
            return .savePending
        } catch let error as PromptWriteError { return .writeFailure(error) }
        catch { return .writeFailure(.serializationFailed) }
    }

    private var filename: String { LibraryPath.filename(state.prompt?.relativePath.string ?? "") }
    private var isWriting: Bool { state.status == .saving || state.status == .commandRunning }

    private func startOpen(_ selection: LibraryPromptSelection) {
        resetEditor()
        state.prompt = selection
        bindSession(to: selection.relativePath.string)
        load(.replace)
    }

    private func bindSession(to path: String, committedEntry: LibraryEntry? = nil) {
        let generation = self.generation
        let onExternalChange: (PromptExternalChange) -> Void = { [weak self] change in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation else { return }
                self.externalChange(change)
            }
        }
        if let committedEntry {
            session = editing.beginSession(forCommitted: committedEntry, onExternalChange: onExternalChange)
        } else { session = editing.beginSession(at: path, onExternalChange: onExternalChange) }
    }

    private func retireSession() {
        if let assistantPermit {
            assistantPermit.invalidate(.failed(.inactive))
            releaseAssistantPermit(assistantPermit)
        }
        commandHasExternalChange = false
        if let session { editing.retire(session) }
        session = nil
        generation &+= 1
        loadGeneration &+= 1
        historyGeneration &+= 1
        let completion = commandCompletion
        commandCompletion = nil
        if let completion { main.run { completion(.inactive) } }
    }

    private func resetEditor() {
        retireSession()
        baseline = nil
        document = nil
        historyRequested = false
        commandHasExternalChange = false
        let pending = state.pendingDecision
        let queued = state.queuedActions
        let selectionChange = state.committedSelectionChange
        state = EditorState()
        state.pendingDecision = pending
        state.queuedActions = queued
        // Keep the command signal through a close/open before queued observers run.
        state.committedSelectionChange = selectionChange
    }

    private func load(_ purpose: LoadPurpose) {
        guard let session else { return }
        loadGeneration &+= 1
        let loadGeneration = self.loadGeneration
        let generation = self.generation
        if purpose == .inspectConflict { state.conflict?.isLoading = true }
        else if purpose != .reconcileCopy { state.status = .loading }
        changed()
        editing.load(session: session) { [weak self] outcome in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation,
                      self.loadGeneration == loadGeneration else { return }
                self.loaded(outcome, purpose: purpose)
            }
        }
    }

    private func loaded(_ outcome: PromptLoadOutcome, purpose: LoadPurpose) {
        switch outcome {
        case .loaded(let loaded):
            if purpose == .reconcileCopy {
                // A publication can precede the queued copy reply and thus
                // predate its session. Reconcile on the worker, keeping any
                // draft typed after adoption rather than replacing it.
                if loaded.stamp != state.stamp {
                    if state.isDirty || state.conflict != nil {
                        state.conflict = EditorConflict(kind: .modified, stamp: loaded.stamp,
                            theirsSource: loaded.source, readOnlyReason: loaded.readOnlyReason)
                    } else { accept(loaded); state.status = .idle }
                }
            } else if purpose == .inspectConflict {
                state.conflict = EditorConflict(kind: .modified, stamp: loaded.stamp,
                    theirsSource: loaded.source, readOnlyReason: loaded.readOnlyReason)
            } else {
                accept(loaded)
                state.status = .idle
                resumeDecisionAfterDiscard()
            }
        case .deleted:
            if state.isDirty || state.conflict != nil || purpose == .reconcileCopy {
                state.conflict = EditorConflict(kind: .deleted, stamp: nil)
                if purpose != .inspectConflict { state.status = .idle }
            } else { resetEditor() }
        case .failed(let failure):
            if purpose == .inspectConflict {
                state.conflict?.isLoading = false
                state.conflict?.failure = failure
            } else { state.status = .failed(.editing(failure)) }
        }
        changed()
    }

    private func accept(_ loaded: LoadedPrompt) {
        if state.prompt != Self.selection(loaded.entry) {
            historyGeneration &+= 1
            state.history = EditorHistoryState()
        }
        baseline = loaded
        state.prompt = Self.selection(loaded.entry)
        state.source = loaded.source
        state.stamp = loaded.stamp
        state.readOnlyReason = loaded.readOnlyReason
        state.isDirty = false
        state.conflict = nil
        state.historyMaintenanceFailed = false
        state.provenanceMaintenanceFailed = false
        updateDocument(loaded.document)
    }

    private func externalChange(_ change: PromptExternalChange) {
        if let assistantPermit, isWriting {
            assistantPermit.invalidate(.conflict(change.newStamp.map { .modified(currentStamp: $0) } ?? .deleted))
            commandHasExternalChange = true
            return
        }
        // A UI hop delivered before the service's write barrier may still be
        // queued when a command starts. Its checked outcome must arrive before
        // that hop can retire the session or replace the loaded baseline.
        if state.status == .commandRunning {
            commandHasExternalChange = true
            return
        }
        if state.isDirty || state.conflict != nil {
            openConflict(stamp: change.newStamp)
        } else if change.kind == .deleted {
            resetEditor()
            changed()
        } else { load(.replace) }
    }

    private func openConflict(stamp: FileStamp?) {
        // Invalidate earlier rereads immediately, including deletion while a
        // modified snapshot is still in the worker/UI queue.
        loadGeneration &+= 1
        if state.status == .loading { state.status = .idle }
        state.conflict = EditorConflict(kind: stamp == nil ? .deleted : .modified, stamp: stamp)
        changed()
        if stamp != nil { load(.inspectConflict) }
    }

    private func startSave(_ purpose: SavePurpose, expectedStamp: FileStamp?) {
        guard let source = state.source, let session, let path = state.prompt?.relativePath.string else { return }
        let generation = self.generation
        loadGeneration &+= 1
        state.status = .saving
        changed()
        let completion: (PromptSaveOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation else { return }
                self.saved(outcome, submitted: source, purpose: purpose)
            }
        }
        if purpose == .copy { editing.createCopy(source, near: path, session: session, completion: completion) }
        else { editing.save(source, session: session, expectedStamp: expectedStamp, completion: completion) }
    }

    private func saved(_ outcome: PromptSaveOutcome, submitted: String, purpose: SavePurpose) {
        var adoptedCopyGeneration: UInt64?
        if let entry = outcome.committedEntry {
            let previousPrompt = state.prompt
            let unchanged = editorSourceEqual(state.source, submitted)
            let loaded = LoadedPrompt(bytes: Data(entry.document.source.utf8), entry: entry)
            if purpose == .copy {
                state.lastCopy = Self.selection(entry)
                // A newer draft belongs to the original. Keep it there rather
                // than injecting the copy's id into partially typed YAML.
                if unchanged {
                    retireSession()
                    accept(loaded)
                    bindSession(to: entry.relativePath, committedEntry: entry)
                    adoptedCopyGeneration = generation
                }
            } else {
                baseline = loaded
                state.prompt = Self.selection(entry)
                state.stamp = entry.stamp
                state.conflict = nil
                if unchanged { accept(loaded) }
                else { state.isDirty = !editorSourceEqual(state.source, loaded.source) }
            }
            recordCommittedSelection(from: previousPrompt)
            state.status = .saved
            if case .savedButHistoryMaintenanceFailed = outcome { state.historyMaintenanceFailed = true }
            else { state.historyMaintenanceFailed = false }
            if case .savedButProvenanceFailed(_, let history) = outcome {
                state.provenanceMaintenanceFailed = true
                state.historyMaintenanceFailed = history
            } else { state.provenanceMaintenanceFailed = false }
            if savesDecision, !state.isDirty { finishDecision(.allowed) }
            else { savesDecision = false }
        } else {
            // A failed decision save leaves its dialog visible. Only another
            // dialog save or an explicit conflict choice may approve its action.
            savesDecision = false
            switch outcome {
            case .conflict(let stamp):
                // A copy conflict belongs to its destination, so it cannot
                // replace the original session's conflict or trigger its reread.
                if purpose == .copy { state.status = .failed(.editing(.library(.conflict))) }
                else { state.status = .idle; openConflict(stamp: stamp) }
            case .deleted: state.status = .idle; openConflict(stamp: nil)
            case .invalid(let issues): state.status = .failed(.invalid(issues))
            case .readOnly(let reason): state.status = .failed(.readOnly(reason))
            case .failed(let failure): state.status = .failed(.editing(failure))
            case .saved, .savedButHistoryMaintenanceFailed, .savedButProvenanceFailed: break
            }
        }
        changed()
        if let adoptedCopyGeneration, adoptedCopyGeneration == generation { load(.reconcileCopy) }
        if outcome.committedEntry != nil, historyRequested { loadHistory() }
        main.run { [weak self] in self?.processRequests() }
    }

    private func restoreBaseline() {
        // Discard returns to the loaded text and stamp. If disk changed during
        // a conflict, a later save reopens that conflict through the stale stamp.
        loadGeneration &+= 1
        if let baseline { accept(baseline) }
        state.isDirty = false
        state.status = .idle
        state.conflict = nil
    }

    private func processRequests() {
        guard isActive, !isWriting, pendingRequest == nil else { return }
        while isActive, !isWriting, pendingRequest == nil, !requests.isEmpty {
            let request = requests.removeFirst()
            updateQueuedActions()
            if case .open(let selection) = request.decision.action, selection == state.prompt {
                request.operation?(self)
                request.completion(.allowed)
                continue
            }
            if state.isDirty {
                pendingRequest = request
                state.pendingDecision = request.decision
                changed()
                return
            }
            perform(request)
        }
        changed()
    }

    private func finishDecision(_ result: EditorGuardResult) {
        guard let request = pendingRequest, state.pendingDecision?.id == request.decision.id else { return }
        state.pendingDecision = nil
        savesDecision = false
        changed()
        // Resolving a dialog is a UI intent too; a queued hop rechecks edits
        // made after Save/Discard, before permitting the destructive action.
        main.run { [weak self] in
            guard let self, self.isActive, self.pendingRequest?.decision.id == request.decision.id else { return }
            if result == .allowed, self.state.status == .saving {
                // A new explicit save can start after Discard but before this
                // queued approval. Reserve the same request for its new stamp.
                self.savesDecision = true
                self.state.pendingDecision = request.decision
                self.changed()
                return
            }
            if result == .allowed, self.state.isDirty {
                self.state.pendingDecision = request.decision
                self.changed()
                return
            }
            // Keep the request reserved through publication: inline observers
            // may enqueue navigation, but it must follow this older action.
            self.pendingRequest = nil
            if result == .allowed { self.perform(request) }
            else { request.completion(result) }
            self.processRequests()
        }
    }

    private func resumeDecisionAfterDiscard() {
        if pendingRequest != nil, !state.isDirty { finishDecision(.allowed) }
    }

    private func perform(_ request: GuardRequest) {
        if let operation = request.operation {
            operation(self)
            request.completion(.allowed)
            return
        }
        switch request.decision.action {
        case .open(let selection): startOpen(selection)
        case .close: resetEditor(); changed()
        case .revert: load(.replace)
        case .librarySwitch: resetEditor(); deactivate()
        case .rename, .move, .delete, .quit: break
        }
        request.completion(.allowed)
    }

    private func updateQueuedActions() { state.queuedActions = requests.map { $0.decision.action } }

    private func updateDocument(_ document: PromptDocument) {
        if !editorSourceEqual(self.document?.source, document.source) { assistantRevision &+= 1 }
        self.document = document
        state.issues = document.issues
        let effective = document.effectiveFields
        let names = Set(effective.map(\.name))
        state.fields = effective + document.frontMatter.fields.filter { !names.contains($0.name) }
        state.previewFailure = nil
        guard document.canRender else {
            state.preview = ""
            state.previewFailure = document.isReadOnly ? .unsupportedFormat(document.frontMatter.format) : .invalidPrompt
            return
        }
        let formatters = formattersForPreview()
        let now = clock.now()
        let date = formatters.date.string(from: now)
        let time = formatters.time.string(from: now)
        let defaults = Self.previewDefaults(for: effective)
        // Preview has deliberately different empty/choice rules from delivery:
        // a missing default remains a literal marker, even for a choice. Use
        // the codec's single-pass tokens, never FillService.builtinSnapshot.
        state.preview = document.template.tokens.map { token in
            switch token {
            case .literal(let text): return text
            case .escapedOpener: return "{{"
            case .placeholder(let name):
                switch name {
                case "clipboard": return "{clipboard}"
                case "date": return date
                case "time": return time
                default: return defaults[name] ?? "{\(name)}"
                }
            }
        }.joined()
    }

    /// Match effectiveFields' first-declaration rule even for duplicate input.
    static func previewDefaults(for fields: [PromptField]) -> [String: String] {
        var defaults: [String: String] = [:]
        for field in fields where defaults[field.name] == nil {
            defaults[field.name] = field.defaultValue.isEmpty ? "{\(field.name)}" : field.defaultValue
        }
        return defaults
    }

    private func formattersForPreview() -> (date: DateFormatter, time: DateFormatter) {
        let zone = timeZone()
        if let cached = previewFormatters, cached.zone == zone { return (cached.date, cached.time) }
        func formatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = format
            return formatter
        }
        let date = formatter("yyyy-MM-dd")
        let time = formatter("HH:mm")
        previewFormatters = (zone, date, time)
        return (date, time)
    }

    private static func selection(_ entry: LibraryEntry) -> LibraryPromptSelection {
        LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(entry.relativePath))
    }

    private func recordCommittedSelection(from previous: LibraryPromptSelection?) {
        guard let previous, let prompt = state.prompt, previous != prompt else { return }
        state.committedSelectionChange = .adopted(from: previous, to: prompt, id: UUID())
    }

    private func changed() { main.run { [weak self] in self?.publishLatest() } }

    private func publishLatest() {
        guard isActive, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        while isActive, state != lastPublishedState {
            let snapshot = state
            lastPublishedState = snapshot
            let subscribers = observerOrder
            onChange?()
            for token in subscribers {
                guard state == snapshot else { break }
                observers[token]?(snapshot)
            }
        }
    }
}

extension EditorModel {
    /// Called when History is opened or refreshed. Selecting a loaded revision
    /// is memory-only and never makes its read-only source an editor draft.
    public func loadHistory() {
        guard isActive, let session, let prompt = state.prompt else { return }
        historyRequested = true
        historyGeneration &+= 1
        let historyGeneration = self.historyGeneration
        let generation = self.generation
        state.history.isLoading = true
        state.history.failure = nil
        changed()
        editing.history(for: prompt.identity, session: session) { [weak self] outcome in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation,
                      self.historyGeneration == historyGeneration, self.state.prompt == prompt else { return }
                self.state.history.isLoading = false
                switch outcome {
                case .loaded(let revisions):
                    self.state.history.revisions = revisions
                    if !revisions.contains(where: { $0.revision == self.state.history.selectedRevision }) {
                        self.state.history.selectedRevision = nil
                    }
                case .failed(let failure): self.state.history.failure = failure
                }
                self.changed()
            }
        }
    }

    public func selectRevision(_ revision: HistoryRevision?) {
        guard isActive, revision == nil || state.history.revisions.contains(where: { $0.revision == revision }) else { return }
        state.history.selectedRevision = revision
        changed()
    }

    public func restore(_ revision: HistoryRevision, completion: @escaping (PromptCommandOutcome) -> Void = { _ in }) {
        requestCommand(.restore(revision), action: .revert, completion: completion)
    }

    public func rename(to filename: String, completion: @escaping (PromptCommandOutcome) -> Void = { _ in }) {
        requestCommand(.rename(filename), action: .rename, completion: completion)
    }

    public func move(to folder: String, completion: @escaping (PromptCommandOutcome) -> Void = { _ in }) {
        requestCommand(.move(folder), action: .move, completion: completion)
    }

    public func delete(completion: @escaping (PromptCommandOutcome) -> Void = { _ in }) {
        requestCommand(.delete, action: .delete, completion: completion)
    }

    private enum Command {
        case restore(HistoryRevision), rename(String), move(String), delete
    }

    private func requestCommand(_ command: Command, action: EditorDiscardAction,
                                completion: @escaping (PromptCommandOutcome) -> Void) {
        let generation = self.generation
        enqueue(action, operation: { model in
            // A queued command belongs to the requested session, never a
            // different prompt opened by an earlier navigation or copy choice.
            guard model.generation == generation else { return completion(.inactive) }
            model.startCommand(command, completion: completion)
        }, completion: { result in
            switch result {
            case .allowed: break
            case .cancelled: completion(.cancelled)
            case .inactive: completion(.inactive)
            }
        })
    }

    private func startCommand(_ command: Command, completion: @escaping (PromptCommandOutcome) -> Void) {
        guard let session, let stamp = state.stamp else { return completion(.noSelection) }
        let generation = self.generation
        commandCompletion = completion
        loadGeneration &+= 1
        historyGeneration &+= 1
        state.history.isLoading = false
        commandHasExternalChange = false
        state.status = .commandRunning
        changed()
        let reply: (PromptCommandOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation,
                      let completion = self.commandCompletion else { return }
                self.commandCompletion = nil
                self.completedCommand(outcome, command: command)
                completion(outcome)
                self.processRequests()
            }
        }
        switch command {
        case .restore(let revision): editing.restore(revision, session: session, expectedStamp: stamp, completion: reply)
        case .rename(let filename): editing.rename(to: filename, session: session, expectedStamp: stamp, completion: reply)
        case .move(let folder): editing.move(to: folder, session: session, expectedStamp: stamp, completion: reply)
        case .delete: editing.delete(session: session, expectedStamp: stamp, completion: reply)
        }
    }

    private func completedCommand(_ outcome: PromptCommandOutcome, command: Command) {
        let needsReconciliation = commandHasExternalChange
        commandHasExternalChange = false
        state.status = .idle
        let previousPrompt = state.prompt
        if let entry = outcome.committedEntry {
            accept(LoadedPrompt(bytes: Data(entry.document.source.utf8), entry: entry))
            recordCommittedSelection(from: previousPrompt)
            state.status = .saved
            if case .updatedButHistoryMaintenanceFailed = outcome { state.historyMaintenanceFailed = true }
            if case .updatedButProvenanceFailed(_, let history) = outcome {
                state.provenanceMaintenanceFailed = true
                state.historyMaintenanceFailed = history
            }
            if case .restore = command { historyRequested = true }
            changed()
            // Check publications that preceded the queued command reply. Like
            // copy reconciliation, this preserves edits typed after adoption.
            load(.reconcileCopy)
            if historyRequested { loadHistory() }
            return
        }
        switch outcome {
        case .relocated(let baseline, let current):
            accept(LoadedPrompt(bytes: Data(baseline.document.source.utf8), entry: baseline))
            recordCommittedSelection(from: previousPrompt)
            switch current {
            case .loaded(let loaded): openConflict(stamp: loaded.stamp)
            case .deleted: openConflict(stamp: nil)
            case .failed(let failure):
                state.status = .failed(.editing(failure))
                load(.reconcileCopy)
            }
            if historyRequested { loadHistory() }
        case .deleted:
            resetEditor()
            if case .delete = command, let previousPrompt {
                state.committedSelectionChange = .deleted(previousPrompt, id: UUID())
            }
        case .missing: openConflict(stamp: nil)
        case .conflict(let stamp): openConflict(stamp: stamp)
        case .destinationOccupied:
            state.status = .failed(.editing(.library(.destinationOccupied)))
            if needsReconciliation { load(.reconcileCopy) }
        case .forensic(let reason):
            state.status = .failed(.editing(.write(reason)))
            if needsReconciliation { load(.reconcileCopy) }
        case .readOnly(let reason):
            state.status = .failed(.readOnly(reason))
            if needsReconciliation { load(.reconcileCopy) }
        case .failed(let failure):
            state.status = .failed(.editing(failure))
            if needsReconciliation { load(.reconcileCopy) }
        case .updated, .updatedButHistoryMaintenanceFailed, .updatedButProvenanceFailed,
             .cancelled, .inactive, .noSelection: break
        }
        changed()
    }
}

extension EditorModel {
    /// AssistantModel owns graph/profile/access invalidation. This editor owns
    /// the buffer/session and the ordinary unsaved-edit/conflict contract.
    func acceptAssistant(_ acceptance: AssistantAcceptance, destination: AssistantSaveDestination,
                         permit: AssistantSavePermit, validate: @escaping () -> AssistantSaveRefusal?,
                         completion: @escaping (AssistantAcceptanceOutcome) -> Void) {
        guard isActive else { return main.run { completion(.failed(.inactive)) } }
        guard state.conflict == nil, !isWriting, state.status != .loading, assistantPermit == nil else {
            return main.run { completion(.failed(.editorBusy)) }
        }
        assistantPermit = permit
        let generation = self.generation
        let start: (EditorModel) -> Void = { model in
            guard model.generation == generation else {
                permit.invalidate(.failed(.staleContext))
                model.releaseAssistantPermit(permit)
                return completion(.failed(.staleContext))
            }
            model.assistantDecisionID = nil
            if let refusal = validate() {
                permit.invalidate(refusal)
                model.releaseAssistantPermit(permit)
                return completion(refusal.outcome)
            }
            guard model.state.conflict == nil, !model.isWriting, model.state.status != .loading else {
                permit.invalidate(.failed(.editorBusy))
                model.releaseAssistantPermit(permit)
                return completion(.failed(.editorBusy))
            }
            guard AssistantEditorSnapshot.matchesForAcceptance(model.assistantSnapshot, acceptance.candidate.context.editor) else {
                permit.invalidate(.conflict(.changedBuffer))
                model.releaseAssistantPermit(permit)
                return completion(.conflict(.changedBuffer))
            }
            model.startAssistantSave(acceptance, destination: destination, permit: permit, completion: completion)
        }
        if pendingRequest == nil, requests.isEmpty, destination == .improve || !state.isDirty { main.run { [weak self] in
            guard let self else { return completion(.failed(.inactive)) }
            start(self)
        } } else {
            let selection: LibraryPromptSelection
            if destination == .improve, let prompt = state.prompt { selection = prompt }
            else {
                let content = acceptance.candidate.content.document
                let path = PromptCreation.relativePath(title: content.frontMatter.title, now: clock.now())
                selection = LibraryPromptSelection(identity: PromptIdentity(path: path, id: content.frontMatter.id),
                                                   relativePath: RelativePath(path))
            }
            let decisionID = UUID()
            assistantDecisionID = decisionID
            enqueue(.open(selection), operation: start, decisionID: decisionID) { [weak self] result in
                guard result != .allowed else { return }
                let failure: AssistantAcceptanceFailure = result == .cancelled ? .cancelled : .inactive
                let outcome: AssistantAcceptanceOutcome
                do { try permit.check(); outcome = .failed(failure) }
                catch let refusal as AssistantSaveRefusal { outcome = refusal.outcome }
                catch { outcome = .failed(.inactive) }
                permit.invalidate(.failed(failure))
                self?.releaseAssistantPermit(permit)
                completion(outcome)
            }
        }
    }

    private func releaseAssistantPermit(_ permit: AssistantSavePermit) {
        guard assistantPermit === permit else { return }
        assistantPermit = nil
        assistantDecisionID = nil
    }

    /// Retiring an Assistant draft removes only its own queued discard guard.
    /// An already executing save still completes through the worker barrier.
    func cancelAssistantGuard(permit: AssistantSavePermit) {
        main.run { [weak self] in
            guard let self, self.assistantPermit === permit, let id = self.assistantDecisionID else { return }
            let request: GuardRequest
            if let pending = self.pendingRequest, pending.decision.id == id {
                request = pending
                self.pendingRequest = nil
                self.state.pendingDecision = nil
                self.savesDecision = false
            } else if let index = self.requests.firstIndex(where: { $0.decision.id == id }) {
                request = self.requests.remove(at: index)
            } else { return }
            self.assistantDecisionID = nil
            self.updateQueuedActions()
            request.completion(.cancelled)
            self.changed()
            self.processRequests()
        }
    }

    private func startAssistantSave(_ acceptance: AssistantAcceptance, destination: AssistantSaveDestination,
                                    permit: AssistantSavePermit, completion: @escaping (AssistantAcceptanceOutcome) -> Void) {
        guard let profile = acceptance.candidate.context.profile, let host = profile.baseURL.host else {
            permit.invalidate(.failed(.staleContext))
            releaseAssistantPermit(permit)
            return completion(.failed(.staleContext))
        }
        let prepared = AssistantPreparedSave(content: acceptance.candidate.content,
            metadata: AssistantSaveMetadata(providerHost: host, model: profile.modelID, usage: acceptance.usage),
            permit: permit)
        let generation = self.generation
        loadGeneration &+= 1
        commandHasExternalChange = false
        state.status = .saving
        changed()
        editing.accept(prepared, source: acceptance.candidate.context.editor, destination: destination) { [weak self] outcome in
            self?.releaseAssistantPermit(permit)
            guard let self, self.isActive, self.generation == generation else { return completion(outcome) }
            self.completedAssistantSave(outcome, source: acceptance.candidate.context.editor,
                                        destination: destination, completion: completion)
        }
    }

    private func completedAssistantSave(_ outcome: AssistantAcceptanceOutcome, source: AssistantEditorSnapshot?,
                                        destination: AssistantSaveDestination, completion: (AssistantAcceptanceOutcome) -> Void) {
        let reconcile = commandHasExternalChange
        commandHasExternalChange = false
        state.status = .idle
        if let commit = outcome.committed {
            let entry = commit.entry
            let previous = state.prompt
            let unchanged = source?.revision == assistantSnapshot?.revision
                && source?.sourceBytes == state.source.map { Data($0.utf8) }
            let loaded = LoadedPrompt(bytes: Data(entry.document.source.utf8), entry: entry)
            if destination == .improve {
                baseline = loaded
                state.prompt = Self.selection(entry)
                state.stamp = entry.stamp
                if unchanged { accept(loaded) }
                else { state.isDirty = !editorSourceEqual(state.source, loaded.source) }
            } else {
                state.lastCopy = Self.selection(entry)
                if unchanged {
                    retireSession()
                    accept(loaded)
                    bindSession(to: entry.relativePath, committedEntry: entry)
                }
            }
            recordCommittedSelection(from: previous)
            state.status = .saved
            state.historyMaintenanceFailed = commit.historyMaintenanceFailed
            if case .committedWithProvenanceWarning = outcome { state.provenanceMaintenanceFailed = true }
            else { state.provenanceMaintenanceFailed = false }
            // Publish the token result after adoption, before observers can
            // mistake our own changed stamp/session for stale acceptance.
            completion(outcome)
            changed()
            if destination == .improve || unchanged { load(.reconcileCopy) }
            if historyRequested { loadHistory() }
        } else {
            completion(outcome)
            switch outcome {
            case .conflict(.modified(let stamp)): openConflict(stamp: stamp)
            case .conflict(.deleted): openConflict(stamp: nil)
            case .failed(.editing(let failure)): state.status = .failed(.editing(failure))
            case .failed(.invalid(let issues)): state.status = .failed(.invalid(issues))
            case .failed(.readOnly(let reason)): state.status = .failed(.readOnly(reason))
            default: break
            }
            changed()
            if reconcile, state.conflict == nil { load(.reconcileCopy) }
        }
        main.run { [weak self] in self?.processRequests() }
    }
}

private func editorSourceEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case (.some(let lhs), .some(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
    default: return false
    }
}
