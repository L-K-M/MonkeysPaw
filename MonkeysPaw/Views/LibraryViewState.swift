import Foundation
import MonkeysPawCore
import SwiftUI

/// The reusable window follows one browser graph at a time. Tokens and a
/// binding revision also protect against already-queued retired publications.
final class LibraryViewState: ObservableObject {
    enum Preview: Equatable {
        case none
        case rendered(String)
        case issues([PromptIssue])
    }

    enum Direction { case up, down }
    enum EditorTab: Hashable { case edit, preview, fields, history }
    private enum OpenContext { case library, picker }

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
    @Published private(set) var commandMessage: String?
    var onEditorChange: (() -> Void)?
    var onConflictRequested: (() -> Void)?
    private(set) var model: LibraryBrowserModel
    private(set) var editor: EditorModel
    private let mainThread: MainThread
    private let revealLibrary: () -> Void
    private var observer: UUID?
    private var editorObserver: UUID?
    private var bindingRevision: UInt64 = 0
    private var isActive = true
    private var copySelection: LibraryPromptSelection?
    private var isClosingEditor = false
    private var isPresented = false
    private var revealAfterOpen: [LibraryPromptSelection] = []
    private var lastClosedPromptPath: RelativePath?

    init(model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
         mainThread: MainThread, imports: LibraryImportViewState? = nil, revealLibrary: @escaping () -> Void) {
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
        observeModel()
        refresh()
    }

    deinit { detachObservers() }

    var canSave: Bool {
        isActive && libraryAvailable && editorState.canSave
            && editorState.conflict == nil && editorState.pendingDecision == nil
    }
    var canRevert: Bool {
        isActive && libraryAvailable && editorState.prompt != nil
            && editorState.status != .loading && editorState.status != .saving
            && editorState.status != .commandRunning
            && editorState.conflict == nil && editorState.pendingDecision == nil
    }
    var canShowConflict: Bool {
        isActive && libraryAvailable && editorState.canSave
            && editorState.conflict?.isLoading == false && editorState.pendingDecision == nil
    }

    var canRunFileCommand: Bool {
        canRevert && editorState.canEdit && editorState.stamp != nil
    }
    var canLoadHistory: Bool {
        isActive && libraryAvailable && editorState.prompt != nil && editorState.status != .commandRunning
    }
    var selectedRevision: PromptHistorySnapshot? {
        editorState.history.revisions.first { $0.revision == editorState.history.selectedRevision }
    }
    var canRestoreRevision: Bool {
        canRunFileCommand && fileCommandRequest == nil && !editorState.history.isLoading && selectedRevision != nil
    }

    var canToggleFavorite: Bool {
        guard isActive, libraryAvailable, let row = snapshot.selectedPrompt else { return false }
        if row.relativePath == editorState.prompt?.relativePath,
           !editorState.canEdit || editorState.previewFailure != nil { return false }
        return row.canRender && !row.isReadOnly
    }

    var favoriteMessage: String? { favoriteOutcome.flatMap(LibraryStrings.favoriteMessage) }

    func rebind(to model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
                imports: LibraryImportViewState? = nil) {
        guard isActive else { return }
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
        imports?.deactivate()
        isActive = false
        bindingRevision &+= 1
        sourceRevision &+= 1
        revealAfterOpen = []
        detachObservers()
        libraryAvailable = false
        favoriteOutcome = nil
        fileCommandRequest = nil
        commandMessage = nil
        onEditorChange = nil
        onConflictRequested = nil
    }

    func setLibraryAvailable(_ available: Bool) {
        guard isActive else { return }
        libraryAvailable = available
        imports?.setLibraryAvailable(available)
        if !available { fileCommandRequest = nil }
        onEditorChange?()
    }

    func didShow() {
        guard isActive else { return }
        isPresented = true
        lastClosedPromptPath = nil
        refresh()
        focusRevision &+= 1
        if editor.state.prompt == nil, let selection = snapshot.selection { select(selection) }
    }

    func setFilter(_ filter: String) {
        guard isActive else { return }
        favoriteOutcome = nil
        model.setFilter(filter)
    }

    func selectSection(_ section: LibrarySectionID) {
        guard isActive else { return }
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
            self.copySelection = nil
            self.model.selectPrompt(self.editor.state.prompt)
        }
    }

    func edit(_ source: String) {
        guard isActive, libraryAvailable else { return }
        commandMessage = nil
        editor.edit(source)
    }

    // After Cancel, Save reopens conflict choices without writing the stale draft.
    func save() {
        if canShowConflict { onConflictRequested?() }
        else if canSave { editor.save() }
    }
    func saveAsCopy() { if canSave { editor.saveAsCopy() } }
    func revert() { if canRevert { editor.revert() } }

    func loadHistory() { if canLoadHistory { editor.loadHistory() } }

    func selectRevision(_ filename: String?) {
        guard isActive else { return }
        editor.selectRevision(editorState.history.revisions.first { $0.revision.filename == filename }?.revision)
    }

    func restoreRevision() {
        guard canRestoreRevision, let revision = selectedRevision?.revision else { return }
        editor.restore(revision, completion: commandCompletion(success: LibraryCommandStrings.restored))
    }

    func requestFileCommand(_ command: LibraryFileCommand) {
        guard canRunFileCommand, fileCommandRequest == nil, let prompt = editorState.prompt else { return }
        let folders = snapshot.sections.compactMap { section -> String? in
            if case .folder(let folder) = section.id { return folder.string }
            return nil
        }
        fileCommandRequest = LibraryFileCommandRequest(command: command, prompt: prompt, folders: folders)
        onEditorChange?()
    }

    func resolveFileCommand(_ response: LibraryEditorResponse, id: UUID) {
        guard let request = fileCommandRequest, request.id == id,
              LibraryEditorDialog.fileCommand(request).accepts(response) else { return }
        fileCommandRequest = nil
        onEditorChange?()
        guard response != .cancelFileCommand, canRunFileCommand, editorState.prompt == request.prompt else { return }
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
        // Core owns the unsaved guard, ordering and exactly-once completion.
        return { [weak self] outcome in
            guard let self, self.isActive, self.bindingRevision == revision else { return }
            self.commandMessage = LibraryCommandStrings.message(outcome, success: success)
        }
    }

    func requestClose(_ completion: @escaping (EditorGuardResult) -> Void) {
        guard isActive else { completion(.inactive); return }
        isClosingEditor = true
        let revision = bindingRevision
        // EditorModel.request completes through its injected MainThread.
        editor.request(.close) { [weak self] result in
            guard let self, self.isActive, self.bindingRevision == revision else { completion(.inactive); return }
            if result == .allowed { self.isPresented = false }
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
                if previousPrompt != state.prompt || state.status == .loading
                    || state.status == .saving || state.status == .commandRunning {
                    self.commandMessage = nil
                }
                if previousPrompt?.relativePath != state.prompt?.relativePath { self.sourceRevision &+= 1 }
                // External deletion and conflict discard can clear the editor
                // before the browser retires its selected row.
                if let previousPrompt, state.prompt == nil {
                    self.lastClosedPromptPath = previousPrompt.relativePath
                }
                let adoptedCopy = previousPrompt != nil
                    && state.prompt != previousPrompt && state.prompt == state.lastCopy
                self.editorState = state
                if let request = self.fileCommandRequest,
                   request.prompt != state.prompt || !self.canRunFileCommand { self.fileCommandRequest = nil }
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
                if self.editorTab == .history, previousPrompt != state.prompt,
                   state.prompt != nil, !state.history.isLoading { self.loadHistory() }
            }
        }
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
