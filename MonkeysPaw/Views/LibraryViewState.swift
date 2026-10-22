import Foundation
import MonkeysPawCore
import SwiftUI
import UniformTypeIdentifiers

/// The reusable window follows one browser graph at a time. Tokens and a
/// binding revision also protect against already-queued retired publications.
final class LibraryViewState: ObservableObject {
    typealias AssistantFactory = () -> AssistantModel
    typealias ConflictProvider = () -> ConflictModel?
    enum Preview: Equatable {
        case none
        case rendered(String)
        case issues([PromptIssue])
    }

    enum Direction { case up, down }
    enum EditorTab: Hashable { case edit, preview, fields, history }
    private enum OpenContext { case library, picker, creation }
    private struct ScopeDrop {
        let selection: LibraryPromptSelection
        let section: LibrarySectionID
        var openApproved: Bool
    }
    private static let scopeDragType = UTType(exportedAs: "ch.lkmc.monkeyspaw.library-row")
    static var scopeDragTypeIdentifier: String { scopeDragType.identifier }

    @Published private(set) var snapshot: LibraryBrowserState
    @Published private(set) var preview: Preview = .none
    @Published private(set) var favoriteOutcome: PromptFavoriteOutcome?
    @Published private(set) var libraryAvailable: Bool
    @Published private(set) var activeLibraryPath: String
    @Published private(set) var focusRevision: UInt64 = 0
    @Published private(set) var editorState: EditorState
    @Published private(set) var sourceRevision: UInt64 = 0
    @Published private(set) var imports: LibraryImportViewState?
    @Published var editorTab = EditorTab.edit {
        didSet { if editorTab == .history, oldValue != .history { loadHistory() } }
    }
    @Published private(set) var fileCommandRequest: LibraryFileCommandRequest?
    @Published private(set) var newPromptRequest: LibraryNewPromptRequest?
    @Published private(set) var commandMessage: String?
    @Published private(set) var assistant: LibraryAssistantViewState?
    @Published private(set) var isAssistantVisible = false
    @Published private(set) var assistantSaveMessage: String?
    @Published private(set) var quoteHighlight: LibrarySourceHighlight?
    @Published private(set) var conflict: LibraryConflictViewState?
    @Published private(set) var syncStatus: SyncStatusViewState?
    @Published private(set) var scopeDragEpoch = UUID()
    @Published private(set) var isScopeDropPending = false
    var onEditorChange: (() -> Void)?
    var onConflictRequested: (() -> Void)?
    var onAssistantVisibilityChange: (() -> Void)?
    var onConflictVisibilityChange: (() -> Void)?
    private(set) var model: LibraryBrowserModel
    private(set) var editor: EditorModel
    private let mainThread: MainThread
    private let revealLibrary: () -> Void
    private let createPrompt: (String, RelativePath) -> LibraryPromptSelection?
    private var makeAssistant: AssistantFactory?
    private var conflictProvider: ConflictProvider?
    private let scheduler: MonkeysPawCore.Scheduler?
    private var assistantSession: PromptEditingSession?
    private var assistantPrompt: LibraryPromptSelection?
    private var observer: UUID?
    private var editorObserver: UUID?
    private var bindingRevision: UInt64 = 0
    private var isActive = true
    private var copySelection: LibraryPromptSelection?
    private var isClosingEditor = false
    private var isPresented = false
    private var revealAfterOpen: [LibraryPromptSelection] = []
    private var lastClosedPromptPath: RelativePath?
    private var scopeDrop: ScopeDrop?
    private var scopeDropRequest: UUID?
    private var scopeDropLoad: Progress?

    init(model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
         mainThread: MainThread, imports: LibraryImportViewState? = nil,
         makeAssistant: AssistantFactory? = nil, scheduler: MonkeysPawCore.Scheduler? = nil,
         conflictProvider: ConflictProvider? = nil,
         syncStatus: SyncStatusViewState? = nil,
         createPrompt: @escaping (String, RelativePath) -> LibraryPromptSelection? = { _, _ in nil },
         revealLibrary: @escaping () -> Void) {
        self.model = model
        self.editor = editor
        editorState = editor.state
        snapshot = model.state
        activeLibraryPath = libraryPath
        libraryAvailable = available
        self.imports = imports
        imports?.updateDestinations(model.state.sections)
        self.mainThread = mainThread
        self.revealLibrary = revealLibrary
        self.createPrompt = createPrompt
        self.makeAssistant = makeAssistant
        self.conflictProvider = conflictProvider
        self.syncStatus = syncStatus
        self.scheduler = scheduler
        observeModel()
        refresh()
    }

    deinit { assistant?.retire(); conflict?.retire(); syncStatus?.retire(); detachObservers() }

    var isResolvingConflict: Bool { conflict?.isResolving == true }
    var canEditSource: Bool { isActive && libraryAvailable && !isResolvingConflict && editorState.canEdit }
    var canShowAssistant: Bool { isActive && libraryAvailable && !isResolvingConflict && makeAssistant != nil && scheduler != nil }

    func showAssistant() {
        guard canShowAssistant, let makeAssistant, let scheduler else { return }
        if assistant == nil {
            let revision = bindingRevision
            let session = editor.assistantSnapshot?.session
            let path = editor.state.prompt?.relativePath
            let view = LibraryAssistantViewState(model: makeAssistant(), editor: editor,
                available: libraryAvailable, main: mainThread, scheduler: scheduler) { [weak self] outcome in
                    guard let self, self.isActive, self.bindingRevision == revision,
                          self.editor.assistantSnapshot?.session == session,
                          self.editor.state.prompt?.relativePath == path else { return }
                    self.assistantSaveMessage = LibraryAssistantStrings.acceptance(outcome)
                }
            view.onRequest = { [weak self] in self?.assistantSaveMessage = nil }
            view.onHighlight = { [weak self] range in
                guard let self, self.isActive, self.bindingRevision == revision else { return }
                self.quoteHighlight = range.flatMap { range in
                    self.editor.state.source.map { LibrarySourceHighlight(byteRange: range, sourceBytes: Data($0.utf8)) }
                }
                if range != nil { self.editorTab = .edit }
            }
            assistantSession = session
            assistantPrompt = editor.state.prompt
            assistant = view
        }
        if !isAssistantVisible {
            isAssistantVisible = true
            onAssistantVisibilityChange?()
        }
    }

    func toggleAssistant() {
        if isAssistantVisible { closeAssistant() }
        else { showAssistant() }
    }

    func closeAssistant() {
        isAssistantVisible = false
        assistant?.close()
        quoteHighlight = nil
        onAssistantVisibilityChange?()
    }

    func retireAssistant() {
        let wasVisible = isAssistantVisible
        isAssistantVisible = false
        retireAssistantBinding()
        if wasVisible { onAssistantVisibilityChange?() }
    }

    private func retireAssistantBinding() {
        let old = assistant
        assistant = nil
        old?.retire()
        assistantSession = nil
        assistantPrompt = nil
        assistantSaveMessage = nil
        quoteHighlight = nil
    }

    func assistantProfileChanged() {
        assistantSaveMessage = nil
        assistant?.profileChanged()
    }

    private func updateAssistantSession() {
        guard let assistant else { return }
        if assistantSession != editor.assistantSnapshot?.session || assistantPrompt?.relativePath != editor.state.prompt?.relativePath {
            let visible = isAssistantVisible
            retireAssistantBinding()
            if visible, canShowAssistant { showAssistant() }
            else if visible {
                isAssistantVisible = false
                onAssistantVisibilityChange?()
            }
            return
        }
        assistant.editorChanged(available: libraryAvailable && !isResolvingConflict)
    }

    var canSave: Bool {
        isActive && libraryAvailable && !isResolvingConflict && editorState.canSave
            && editorState.conflict == nil && editorState.pendingDecision == nil
    }
    var canSaveAsCopy: Bool {
        isActive && libraryAvailable && !isResolvingConflict && editorState.canSaveAsCopy
            && editorState.conflict == nil && editorState.pendingDecision == nil
    }
    var canRevert: Bool {
        isActive && libraryAvailable && !isResolvingConflict && editorState.prompt != nil
            && editorState.status != .loading && editorState.status != .saving
            && editorState.status != .commandRunning
            && editorState.conflict == nil && editorState.pendingDecision == nil
    }
    var canShowConflict: Bool {
        isActive && libraryAvailable && !isResolvingConflict && editorState.canSave
            && editorState.conflict?.isLoading == false && editorState.pendingDecision == nil
    }

    var canRunFileCommand: Bool {
        canRevert && editorState.canEdit && editorState.stamp != nil && !isScopeDropPending
            && editorState.queuedActions.isEmpty && newPromptRequest == nil
    }
    var canCreatePrompt: Bool { scopeDragReady && !isScopeDropPending }
    var canFocusFilter: Bool {
        isActive && isPresented && fileCommandRequest == nil && newPromptRequest == nil
            && editorState.pendingDecision == nil && editorState.conflict == nil && imports?.isChoosing != true
    }
    var canLoadHistory: Bool {
        isActive && libraryAvailable && !isResolvingConflict && editorState.prompt != nil && editorState.status != .commandRunning
    }
    var selectedRevision: PromptHistorySnapshot? {
        editorState.history.revisions.first { $0.revision == editorState.history.selectedRevision }
    }
    var canRestoreRevision: Bool {
        canRunFileCommand && fileCommandRequest == nil && !editorState.history.isLoading && selectedRevision != nil
    }

    var canToggleFavorite: Bool {
        guard isActive, libraryAvailable, !isResolvingConflict, let row = snapshot.selectedPrompt else { return false }
        // Group favourites are a personal overlay, including for a viewer or
        // a dirty open editor. The model rechecks committed access at intent time.
        if case .group = row.access { return row.canRender }
        if row.access == .unavailable { return false }
        if row.relativePath == editorState.prompt?.relativePath,
           !editorState.canEdit || editorState.previewFailure != nil { return false }
        return row.canRender && !row.isReadOnly
    }

    var favoriteMessage: String? { favoriteOutcome.flatMap(LibraryStrings.favoriteMessage) }

    func rebind(to model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
                imports: LibraryImportViewState? = nil, makeAssistant: AssistantFactory? = nil,
                conflictProvider: ConflictProvider? = nil, syncStatus: SyncStatusViewState? = nil) {
        guard isActive else { return }
        retireScopeDrags()
        retireAssistant()
        retireConflict()
        self.syncStatus?.retire()
        self.syncStatus = syncStatus
        if isPresented { syncStatus?.show() }
        self.makeAssistant = makeAssistant
        self.conflictProvider = conflictProvider
        assistantSaveMessage = nil
        self.imports?.deactivate()
        self.imports = imports
        imports?.updateDestinations(model.state.sections)
        detachObservers()
        bindingRevision &+= 1
        sourceRevision &+= 1
        revealAfterOpen = []
        self.model = model
        self.editor = editor
        editorState = editor.state
        editorTab = .edit
        fileCommandRequest = nil
        newPromptRequest = nil
        commandMessage = nil
        copySelection = nil
        isClosingEditor = false
        lastClosedPromptPath = nil
        activeLibraryPath = libraryPath
        libraryAvailable = available
        favoriteOutcome = nil
        observeModel()
        refresh()
        focusRevision &+= 1
    }

    func deactivate() {
        guard isActive else { return }
        retireScopeDrags()
        retireAssistant()
        retireConflict()
        conflictProvider = nil
        syncStatus?.retire()
        imports?.deactivate()
        isActive = false
        bindingRevision &+= 1
        sourceRevision &+= 1
        revealAfterOpen = []
        detachObservers()
        libraryAvailable = false
        favoriteOutcome = nil
        fileCommandRequest = nil
        newPromptRequest = nil
        commandMessage = nil
        onEditorChange = nil
        onConflictRequested = nil
        onAssistantVisibilityChange = nil
        onConflictVisibilityChange = nil
    }

    func setLibraryAvailable(_ available: Bool) {
        guard isActive else { return }
        syncStatus?.refreshBinding()
        let becameAvailable = available && !libraryAvailable
        libraryAvailable = available
        imports?.setLibraryAvailable(available)
        assistant?.editorChanged(available: available && !isResolvingConflict)
        updateConflict()
        if !available { fileCommandRequest = nil; newPromptRequest = nil; retireScopeDrags() }
        if becameAvailable, editorTab == .history { loadHistory() }
        onEditorChange?()
    }

    func didShow() {
        guard isActive else { return }
        isPresented = true
        syncStatus?.show()
        lastClosedPromptPath = nil
        refresh()
        focusRevision &+= 1
        if editor.state.prompt == nil, let selection = snapshot.selection { select(selection) }
    }

    func didHide() {
        isPresented = false
        newPromptRequest = nil
        syncStatus?.hide()
        retireScopeDrags()
        retireConflict()
    }

    func setFilter(_ filter: String) {
        guard isActive, !model.filter.utf8.elementsEqual(filter.utf8) else { return }
        cancelScopeDrop()
        favoriteOutcome = nil
        model.setFilter(filter)
    }

    func selectSection(_ section: LibrarySectionID) {
        guard isActive, section != model.selectedSection else { return }
        cancelScopeDrop()
        favoriteOutcome = nil
        model.selectSection(section)
    }

    /// SwiftUI List can publish nil when a filter removes its selected row.
    /// Ignore that reconciliation; Core keeps the selected prompt's preview.
    func selectPath(_ path: RelativePath?) {
        guard isActive, let path,
              let row = snapshot.rows.first(where: { $0.relativePath == path }) else { return }
        favoriteOutcome = nil
        select(row.selection)
    }

    /// Picker routes may target a row hidden by Library's section or filter.
    /// Change those only after the draft guard allows the requested open.
    func openPrompt(_ selection: LibraryPromptSelection) {
        guard isActive, libraryAvailable else { return }
        editorTab = .edit
        select(selection, context: .picker)
    }

    private func select(_ selection: LibraryPromptSelection, context: OpenContext = .library) {
        guard isActive, libraryAvailable else { return }
        cancelScopeDrop()
        // Upgrade a pending Library selection when Picker requests the same
        // target, without asking the user to cancel two identical decisions.
        if context == .picker, !revealAfterOpen.contains(selection) { revealAfterOpen.append(selection) }
        let action = EditorDiscardAction.open(selection)
        guard editor.state.pendingDecision?.action != action,
              !editor.state.queuedActions.contains(action) else { return }
        let revision = bindingRevision
        // EditorModel.request completes through its injected MainThread.
        editor.request(action) { [weak self] result in
            guard let self, self.isActive, self.bindingRevision == revision else { return }
            let reveal = self.revealAfterOpen.contains(selection)
            self.revealAfterOpen.removeAll { $0 == selection }
            guard result == .allowed else { return }
            if reveal {
                self.model.setFilter("")
                self.model.selectSection(.all)
            }
            // Creation can finish before the browser receives its index update.
            self.copySelection = context == .creation ? selection : nil
            self.model.selectPrompt(self.editor.state.prompt)
            if self.model.selection == selection { self.copySelection = nil }
        }
    }

    func edit(_ source: String) {
        guard canEditSource else { return }
        commandMessage = nil
        editor.edit(source)
    }

    // After Cancel, Save reopens conflict choices without writing the stale draft.
    func save() {
        if canShowConflict { onConflictRequested?() }
        else if canSave { editor.save() }
    }
    func saveAsCopy() { if canSaveAsCopy { editor.saveAsCopy() } }
    func revert() { if canRevert { editor.revert() } }

    func loadHistory() { if canLoadHistory { editor.loadHistory() } }

    func selectRevision(_ filename: String?) {
        guard isActive, !isResolvingConflict else { return }
        editor.selectRevision(editorState.history.revisions.first { $0.revision.filename == filename }?.revision)
    }

    func restoreRevision() {
        guard canRestoreRevision, let revision = selectedRevision?.revision else { return }
        editor.restore(revision, completion: commandCompletion(success: LibraryCommandStrings.restored))
    }

    func requestFileCommand(_ command: LibraryFileCommand) {
        guard canRunFileCommand, fileCommandRequest == nil, let prompt = editorState.prompt else { return }
        cancelScopeDrop()
        commandMessage = nil
        let folders = snapshot.sections.compactMap { section -> String? in
            if case .folder(let folder) = section.id { return folder.string }
            return nil
        }
        fileCommandRequest = LibraryFileCommandRequest(command: command, prompt: prompt, folders: folders)
        onEditorChange?()
    }

    func requestNewPrompt() {
        guard canCreatePrompt, let folder = model.newPromptDestination() else { return }
        commandMessage = nil
        newPromptRequest = LibraryNewPromptRequest(folder: folder)
        onEditorChange?()
    }

    func resolveNewPrompt(_ response: LibraryEditorResponse, id: UUID) {
        guard let request = newPromptRequest, request.id == id,
              LibraryEditorDialog.newPrompt(request).accepts(response) else { return }
        newPromptRequest = nil
        onEditorChange?()
        guard case .createPrompt(let input) = response, canCreatePrompt else { return }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LibraryStrings.newPromptDefaultTitle : input
        let revision = bindingRevision
        // Ask for the title first; only an approved draft guard may write a file.
        editor.request(.create) { [weak self] result in
            // A close, open or hide during the guard's save supersedes creation.
            guard let self, self.isActive, self.bindingRevision == revision,
                  result == .allowed, self.canCreatePrompt else { return }
            guard let selection = self.createPrompt(title, request.folder) else {
                // Match commandCompletion's ordering after editor publications.
                self.mainThread.run { [weak self] in
                    guard let self, self.isActive, self.bindingRevision == revision else { return }
                    self.commandMessage = Strings.createPromptFailed
                }
                return
            }
            self.editorTab = .edit
            self.model.setFilter("")
            if self.model.selectedSection != .all,
               self.model.moveDestination(for: self.model.selectedSection) != request.folder {
                self.model.selectSection(.all)
            }
            // Stay in this window. The picker path also shows it and focuses search.
            self.select(selection, context: .creation)
        }
    }

    func resolveFileCommand(_ response: LibraryEditorResponse, id: UUID) {
        guard let request = fileCommandRequest, request.id == id,
              LibraryEditorDialog.fileCommand(request).accepts(response) else { return }
        fileCommandRequest = nil
        onEditorChange?()
        guard response != .cancelFileCommand, canRunFileCommand, request.matchesFile(editorState.prompt) else { return }
        switch response {
        case .rename(let filename):
            editor.rename(to: filename, completion: commandCompletion(success: LibraryCommandStrings.renamed))
        case .move(let folder):
            editor.move(to: folder, completion: commandCompletion(success: LibraryCommandStrings.moved))
        case .delete:
            editor.delete(completion: commandCompletion(success: LibraryCommandStrings.deleted))
        default: break
        }
    }

    private func commandCompletion(success: String) -> (PromptCommandOutcome) -> Void {
        commandMessage = nil
        let revision = bindingRevision
        // Queue feedback with state publications so an older busy update cannot erase it.
        return { [weak self] outcome in
            self?.mainThread.run { [weak self] in
                guard let self, self.isActive, self.bindingRevision == revision else { return }
                // Cancelling a guard can leave an unresolved save conflict.
                if case .cancelled = outcome, self.editorState.conflict != nil {
                    self.commandMessage = nil
                    return
                }
                self.commandMessage = LibraryCommandStrings.message(outcome, success: success)
            }
        }
    }

    func requestClose(_ completion: @escaping (EditorGuardResult) -> Void) {
        guard isActive else { completion(.inactive); return }
        retireScopeDrags()
        isClosingEditor = true
        let revision = bindingRevision
        // EditorModel.request completes through its injected MainThread.
        editor.request(.close) { [weak self] result in
            guard let self, self.isActive, self.bindingRevision == revision else { completion(.inactive); return }
            if result == .allowed { self.didHide() }
            self.isClosingEditor = false
            completion(result)
        }
    }

    func moveSelection(_ direction: Direction) {
        guard isActive, !snapshot.rows.isEmpty else { return }
        let position = snapshot.rows.firstIndex { $0.selection == snapshot.selection }
        let next: Int
        if let position {
            next = min(max(position + (direction == .up ? -1 : 1), 0), snapshot.rows.count - 1)
        } else {
            next = direction == .up ? snapshot.rows.count - 1 : 0
        }
        selectPath(snapshot.rows[next].relativePath)
    }

    func toggleFavorite() {
        // The keyboard shortcut must honour the same gate as the button.
        guard canToggleFavorite else { return }
        favoriteOutcome = model.toggleFavorite()
    }

    func revealFolder() {
        guard isActive, libraryAvailable else { return }
        revealLibrary()
    }

    func focusFilter() {
        guard canFocusFilter else { return }
        focusRevision &+= 1
    }

    /// Return true when Escape cleared search. The controller closes only on
    /// the next Escape, independently of which pane currently owns focus.
    func clearFilterForEscape() -> Bool {
        guard isActive, !snapshot.filter.isEmpty else { return false }
        setFilter("")
        focusRevision &+= 1
        return true
    }

    private func observeModel() {
        let revision = bindingRevision
        let model = self.model
        observer = model.addObserver { [weak self, weak model] state in
            self?.mainThread.run { [weak self, weak model] in
                guard let self, let model, self.isActive,
                      self.bindingRevision == revision, self.model === model else { return }
                if self.snapshot.selection != state.selection { self.favoriteOutcome = nil }
                self.snapshot = state
                self.imports?.updateDestinations(state.sections)
                self.updateConflict()
                if let copy = self.copySelection, state.rows.contains(where: { $0.selection == copy }) {
                    self.copySelection = nil
                    self.model.selectPrompt(copy)
                } else if self.isPresented, !self.isClosingEditor, self.editor.state.prompt == nil,
                          let selection = state.selection,
                          selection.relativePath != self.lastClosedPromptPath {
                    self.select(selection)
                }
            }
        }
        let editor = self.editor
        editorObserver = editor.addObserver { [weak self, weak editor] state in
            self?.mainThread.run { [weak self, weak editor] in
                guard let self, let editor, self.isActive,
                      self.bindingRevision == revision, self.editor === editor else { return }
                let previousPrompt = self.editorState.prompt
                let pathChanged = previousPrompt?.relativePath != state.prompt?.relativePath
                let identityChanged = previousPrompt?.identity != state.prompt?.identity
                let commandFinished = self.editorState.status == .commandRunning && state.status != .commandRunning
                let saveCommitted = self.editorState.status == .saving && state.status == .saved
                // Conflict rereads must preserve the command's typed outcome.
                let newConflict = self.editorState.conflict == nil && state.conflict != nil
                if !commandFinished, pathChanged || identityChanged || state.status == .loading
                    || state.status == .saving || state.status == .commandRunning
                    || newConflict || state.pendingDecision != nil {
                    self.commandMessage = nil
                }
                // First-save identity assignment keeps this path's native undo/caret.
                if pathChanged { self.sourceRevision &+= 1 }
                // External deletion and conflict discard can clear the editor
                // before the browser retires its selected row.
                if let previousPrompt, state.prompt == nil {
                    self.lastClosedPromptPath = previousPrompt.relativePath
                }
                let adoptedCopy = previousPrompt != nil
                    && state.prompt != previousPrompt && state.prompt == state.lastCopy
                self.editorState = state
                self.updateConflict()
                self.updateAssistantSession()
                if let request = self.fileCommandRequest,
                   !request.matchesFile(state.prompt) || !self.canRunFileCommand { self.fileCommandRequest = nil }
                self.refreshPreview()
                // Copy adoption selects a new path. An external deletion keeps
                // the draft visible even when the browser clears its selection.
                if adoptedCopy, let prompt = state.prompt {
                    self.copySelection = prompt
                    self.model.setFilter("")
                    self.model.selectSection(.all)
                    if self.model.rows.contains(where: { $0.selection == prompt }) {
                        self.copySelection = nil
                        self.model.selectPrompt(prompt)
                    }
                } else if self.isPresented, !self.isClosingEditor, state.prompt == nil,
                          let selection = self.model.selection,
                          selection.relativePath != self.lastClosedPromptPath {
                    self.select(selection)
                }
                self.onEditorChange?()
                // History keys follow identity; moving also retires Core's path-bound load.
                if self.editorTab == .history, pathChanged || identityChanged || commandFinished || saveCommitted,
                   state.prompt != nil, !state.history.isLoading, !editor.state.history.isLoading { self.loadHistory() }
                self.finishScopeDrop()
            }
        }
    }

    private var scopeDragReady: Bool {
        let state = editor.state
        return isActive && isPresented && libraryAvailable && !isClosingEditor && !isResolvingConflict
            && fileCommandRequest == nil && newPromptRequest == nil && imports?.isChoosing != true
            && state.pendingDecision == nil && state.conflict == nil && state.queuedActions.isEmpty
            && state.status != .loading && state.status != .saving && state.status != .commandRunning
    }

    var canStartScopeDrag: Bool { scopeDragReady && !isScopeDropPending }

    func canDragScopeRow(_ selection: LibraryPromptSelection) -> Bool {
        canStartScopeDrag
            && model.rows.contains { $0.selection == selection && !$0.isReadOnly }
    }

    func canDropScopeRow(onto section: LibrarySectionID) -> Bool {
        scopeDragReady && !isScopeDropPending && model.moveDestination(for: section) != nil
    }

    private func scopePayload(_ selection: LibraryPromptSelection, epoch: UUID) -> Data {
        let identity: String
        switch selection.identity {
        case .assigned(let id): identity = id.rawValue
        case .local(let hash): identity = hash
        }
        let value = "monkeyspaw-row:" + epoch.uuidString + ":" + identity + ":" + selection.relativePath.string
        return Data(value.utf8)
    }

    func scopeDragProvider(for selection: LibraryPromptSelection, epoch: UUID) -> NSItemProvider? {
        guard epoch == scopeDragEpoch, canDragScopeRow(selection) else { return nil }
        let payload = scopePayload(selection, epoch: epoch)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.scopeDragTypeIdentifier, visibility: .ownProcess) { done in
            done(payload, nil)
            return nil
        }
        return provider
    }

    @discardableResult
    func acceptScopeDrop(_ providers: [NSItemProvider], onto section: LibrarySectionID, epoch: UUID) -> Bool {
        guard epoch == scopeDragEpoch, canDropScopeRow(onto: section), providers.count == 1,
              let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(Self.scopeDragTypeIdentifier) else { return false }
        let request = UUID()
        let revision = bindingRevision
        scopeDropRequest = request
        isScopeDropPending = true
        // Spend even a cancelled drag. No dropped path is ever parsed or imported.
        scopeDragEpoch = UUID()
        let load = provider.loadDataRepresentation(forTypeIdentifier: Self.scopeDragTypeIdentifier) { [weak self] bytes, _ in
            self?.mainThread.run { [weak self] in
                guard let self, self.bindingRevision == revision, self.scopeDropRequest == request else { return }
                self.scopeDropLoad = nil
                guard self.scopeDragReady, let bytes,
                      self.model.moveDestination(for: section) != nil,
                      let row = self.model.rows.first(where: {
                          !$0.isReadOnly && bytes == self.scopePayload($0.selection, epoch: epoch)
                      }) else {
                    self.cancelScopeDrop()
                    self.commandMessage = LibraryCommandStrings.moveUnavailable
                    return
                }
                self.scopeDrop = ScopeDrop(selection: row.selection, section: section,
                    openApproved: self.editor.state.prompt == row.selection)
                if self.scopeDrop?.openApproved == true { self.finishScopeDrop(); return }
                self.editor.request(.open(row.selection)) { [weak self] result in
                    guard let self, self.bindingRevision == revision, self.scopeDropRequest == request else { return }
                    guard result == .allowed else { self.cancelScopeDrop(); return }
                    self.model.selectPrompt(row.selection)
                    self.scopeDrop?.openApproved = true
                    self.finishScopeDrop()
                }
            }
        }
        if scopeDropRequest == request { scopeDropLoad = load }
        return true
    }

    private func finishScopeDrop() {
        guard let drop = scopeDrop, drop.openApproved else { return }
        if editor.state.status == .loading { return }
        cancelScopeDrop()
        guard scopeDragReady, editor.state.prompt == drop.selection, editor.state.canEdit,
              editor.state.stamp != nil, let destination = model.moveDestination(for: drop.section) else {
            commandMessage = LibraryCommandStrings.moveUnavailable
            return
        }
        editor.move(to: destination.string, completion: commandCompletion(success: LibraryCommandStrings.moved))
    }

    private func cancelScopeDrop() {
        scopeDropRequest = nil
        scopeDrop = nil
        let load = scopeDropLoad
        scopeDropLoad = nil
        isScopeDropPending = false
        load?.cancel()
    }

    private func retireScopeDrags() {
        cancelScopeDrop()
        scopeDragEpoch = UUID()
    }

    private func detachObservers() {
        if let observer { model.removeObserver(observer) }
        if let editorObserver { editor.removeObserver(editorObserver) }
        observer = nil
        editorObserver = nil
    }

    private func refresh() {
        snapshot = model.state
        editorState = editor.state
        refreshPreview()
        updateConflict()
    }

    private func retireConflict() {
        let old = conflict
        conflict = nil
        old?.retire()
        if old != nil { onConflictVisibilityChange?() }
    }

    private func updateConflict() {
        guard isPresented, let row = snapshot.selectedPrompt,
              row.conflictOrigin != nil, row.selection == editorState.prompt,
              let stamp = editorState.stamp else { retireConflict(); return }
        if conflict == nil {
            let view = LibraryConflictViewState(main: mainThread)
            view.onResolve = { [weak self] action in self?.resolveSyncConflict(action) }
            view.onChange = { [weak self, weak view] in
                guard let self, let view, self.isActive, self.conflict === view else { return }
                self.objectWillChange.send()
                self.assistant?.editorChanged(available: self.libraryAvailable && !view.isResolving)
            }
            conflict = view
            onConflictVisibilityChange?()
        }
        let busy = editorState.status == .loading || editorState.status == .saving || editorState.status == .commandRunning
        conflict?.bind(model: conflictProvider?(), selection: row.selection, stamp: stamp,
            available: libraryAvailable && !busy && editorState.pendingDecision == nil && editorState.queuedActions.isEmpty)
    }

    private func resolveSyncConflict(_ action: ConflictResolutionAction) {
        guard isActive, isPresented, !isClosingEditor, libraryAvailable,
              let view = conflict, view.canResolve(action), let selection = view.selection,
              editor.state.prompt == selection, snapshot.selection == selection else { return }
        if editor.state.isDirty || editor.state.conflict != nil {
            let revision = bindingRevision
            editor.request(.revert) { [weak self, weak view] result in
                guard let self, let view, self.isActive, self.isPresented,
                      self.bindingRevision == revision, self.conflict === view,
                      result == .allowed, self.snapshot.selection == selection else { return }
                // Save/reload may change the candidate; require a fresh choice.
                view.refreshComparison(.afterEditing)
            }
        } else { view.resolve(action) }
    }

    private func refreshPreview() {
        guard editorState.prompt != nil else {
            preview = .none
            return
        }
        guard editorState.previewFailure == nil else {
            preview = .issues(editorState.issues)
            return
        }
        preview = .rendered(editorState.preview)
    }
}
