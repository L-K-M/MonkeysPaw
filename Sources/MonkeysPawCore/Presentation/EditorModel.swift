import Foundation

public enum EditorFailure: Equatable, Sendable {
    case editing(PromptEditingFailure)
    case invalid([PromptIssue])
    case readOnly(PromptReadOnlyReason)
}

public enum EditorStatus: Equatable, Sendable {
    case idle, loading, saving, saved
    case failed(EditorFailure)
}

/// File commands belong to their services/composition. An allowed result lets
/// their caller proceed; open, close and revert are performed by this model.
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
    public fileprivate(set) var lastCopy: LibraryPromptSelection?

    public var canEdit: Bool { source != nil && readOnlyReason == nil && status != .loading }
    public var canSave: Bool { canEdit && status != .saving }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.prompt == rhs.prompt && editorSourceEqual(lhs.source, rhs.source)
            && lhs.stamp == rhs.stamp && lhs.isDirty == rhs.isDirty && lhs.status == rhs.status
            && lhs.readOnlyReason == rhs.readOnlyReason && lhs.issues == rhs.issues
            && lhs.fields == rhs.fields && editorSourceEqual(lhs.preview, rhs.preview)
            && lhs.previewFailure == rhs.previewFailure && lhs.conflict == rhs.conflict
            && lhs.pendingDecision == rhs.pendingDecision && lhs.queuedActions == rhs.queuedActions
            && lhs.historyMaintenanceFailed == rhs.historyMaintenanceFailed && lhs.lastCopy == rhs.lastCopy
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
        let completion: (EditorGuardResult) -> Void
    }

    private enum LoadPurpose { case replace, inspectConflict, takeTheirs }
    private enum SavePurpose { case original, copy }

    private let editing: PromptEditingService
    private let clock: WallClock
    private let timeZone: () -> TimeZone
    private let main: MainThread
    private var session: PromptEditingSession?
    private var generation: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var isActive = true
    private var baseline: LoadedPrompt?
    private var document: PromptDocument?
    private var requests: [GuardRequest] = []
    private var pendingRequest: GuardRequest?
    private var savesDecision = false
    private var observers: [UUID: (EditorState) -> Void] = [:]
    private var observerOrder: [UUID] = []
    private var lastPublishedState = EditorState()
    private var isPublishing = false

    public init(editing: PromptEditingService, clock: WallClock,
                timeZone: @escaping () -> TimeZone, main: MainThread) {
        self.editing = editing
        self.clock = clock
        self.timeZone = timeZone
        self.main = main
    }

    deinit { if let session { editing.retire(session) } }

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
        retireSession()
        isActive = false
        requests = []
        pendingRequest = nil
        observers = [:]
        observerOrder = []
        onChange = nil
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
        let decision = EditorPendingDecision(id: UUID(), action: action)
        guard isActive else {
            main.run { completion(.inactive) }
            return decision.id
        }
        requests.append(GuardRequest(decision: decision, completion: completion))
        updateQueuedActions()
        changed()
        main.run { [weak self] in self?.processRequests() }
        return decision.id
    }

    public func resolveDecision(_ decision: EditorDecision, id: UUID) {
        guard isActive, state.status != .saving,
              let request = pendingRequest, request.decision.id == id else { return }
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
        state.source = text
        state.isDirty = !editorSourceEqual(text, baseline?.source)
        if state.status != .saving { state.status = .idle }
        updateDocument(PromptCodec.parse(text, filename: filename))
        changed()
    }

    public func save() {
        guard isActive, state.status != .loading, state.status != .saving else { return }
        if let reason = state.readOnlyReason {
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
        guard isActive, state.status != .saving, let conflict = state.conflict,
              conflict.choices.contains(choice) else { return }
        switch choice {
        case .keepMine: startSave(.original, expectedStamp: conflict.stamp)
        case .takeTheirs: load(.takeTheirs)
        case .saveAsCopy: saveAsCopy()
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

    private func startOpen(_ selection: LibraryPromptSelection) {
        resetEditor()
        state.prompt = selection
        bindSession(to: selection.relativePath.string)
        load(.replace)
    }

    private func bindSession(to path: String) {
        let generation = self.generation
        session = editing.beginSession(at: path) { [weak self] change in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, self.generation == generation else { return }
                self.externalChange(change)
            }
        }
    }

    private func retireSession() {
        if let session { editing.retire(session) }
        session = nil
        generation &+= 1
        loadGeneration &+= 1
    }

    private func resetEditor() {
        retireSession()
        baseline = nil
        document = nil
        let pending = state.pendingDecision
        let queued = state.queuedActions
        state = EditorState()
        state.pendingDecision = pending
        state.queuedActions = queued
    }

    private func load(_ purpose: LoadPurpose) {
        guard let session else { return }
        loadGeneration &+= 1
        let loadGeneration = self.loadGeneration
        let generation = self.generation
        if purpose == .inspectConflict { state.conflict?.isLoading = true }
        else { state.status = .loading }
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
            if purpose == .inspectConflict {
                state.conflict = EditorConflict(kind: .modified, stamp: loaded.stamp,
                    theirsSource: loaded.source, readOnlyReason: loaded.readOnlyReason)
            } else {
                accept(loaded)
                state.status = .idle
                resumeDecisionAfterDiscard()
            }
        case .deleted:
            if state.isDirty || state.conflict != nil {
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
        baseline = loaded
        state.prompt = Self.selection(loaded.entry)
        state.source = loaded.source
        state.stamp = loaded.stamp
        state.readOnlyReason = loaded.readOnlyReason
        state.isDirty = false
        state.conflict = nil
        state.historyMaintenanceFailed = false
        updateDocument(loaded.document)
    }

    private func externalChange(_ change: PromptExternalChange) {
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
        if let entry = outcome.committedEntry {
            let unchanged = editorSourceEqual(state.source, submitted)
            let loaded = LoadedPrompt(bytes: Data(entry.document.source.utf8), entry: entry)
            if purpose == .copy {
                state.lastCopy = Self.selection(entry)
                // A newer draft belongs to the original. Keep it there rather
                // than injecting the copy's id into partially typed YAML.
                if unchanged {
                    retireSession()
                    accept(loaded)
                    bindSession(to: entry.relativePath)
                }
            } else {
                baseline = loaded
                state.prompt = Self.selection(entry)
                state.stamp = entry.stamp
                state.conflict = nil
                if unchanged { accept(loaded) }
                else { state.isDirty = !editorSourceEqual(state.source, loaded.source) }
            }
            state.status = .saved
            if case .savedButHistoryMaintenanceFailed = outcome { state.historyMaintenanceFailed = true }
            else { state.historyMaintenanceFailed = false }
            if savesDecision, !state.isDirty { finishDecision(.allowed) }
            else { savesDecision = false }
        } else {
            switch outcome {
            case .conflict(let stamp): state.status = .idle; openConflict(stamp: stamp)
            case .deleted: state.status = .idle; openConflict(stamp: nil)
            case .invalid(let issues): state.status = .failed(.invalid(issues))
            case .readOnly(let reason): state.status = .failed(.readOnly(reason))
            case .failed(let failure): state.status = .failed(.editing(failure))
            case .saved, .savedButHistoryMaintenanceFailed: break
            }
        }
        changed()
        main.run { [weak self] in self?.processRequests() }
    }

    private func restoreBaseline() {
        loadGeneration &+= 1
        if let baseline { accept(baseline) }
        state.isDirty = false
        state.status = .idle
        state.conflict = nil
    }

    private func processRequests() {
        guard isActive, state.status != .saving, pendingRequest == nil else { return }
        while isActive, state.status != .saving, pendingRequest == nil, !requests.isEmpty {
            let request = requests.removeFirst()
            updateQueuedActions()
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
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        state.pendingDecision = nil
        savesDecision = false
        changed()
        // Resolving a dialog is a UI intent too; a queued hop rechecks edits
        // made after Save/Discard, before permitting the destructive action.
        let generation = self.generation
        main.run { [weak self] in
            guard let self, self.isActive, self.generation == generation else { return }
            if result == .allowed, self.state.isDirty {
                self.requests.insert(request, at: 0)
                self.updateQueuedActions()
            } else if result == .allowed { self.perform(request) }
            else { request.completion(result) }
            self.processRequests()
        }
    }

    private func resumeDecisionAfterDiscard() {
        if pendingRequest != nil, !state.isDirty { finishDecision(.allowed) }
    }

    private func perform(_ request: GuardRequest) {
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone()
        let now = clock.now()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)
        let defaults = Dictionary(uniqueKeysWithValues: effective.map {
            ($0.name, $0.defaultValue.isEmpty ? "{\($0.name)}" : $0.defaultValue)
        })
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

    private static func selection(_ entry: LibraryEntry) -> LibraryPromptSelection {
        LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(entry.relativePath))
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

private func editorSourceEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case (.some(let lhs), .some(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
    default: return false
    }
}
