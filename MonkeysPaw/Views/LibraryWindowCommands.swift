import AppKit
import MonkeysPawCore

extension LibraryWindowController: NSMenuItemValidation {
    private enum FindAction { case panel, textFinder }
    enum CommandContext { case responderChain, explicitWindow, textInput }
    /// Hosted windows need not become key. Production validation additionally
    /// requires key status before the responder chain can act on a prompt.
    func validateLibraryMenuItem(_ item: NSMenuItem, in candidate: NSWindow?) -> Bool {
        validateCommand(item, in: candidate, context: .explicitWindow)
    }

    func commandsAvailable(in candidate: NSWindow?, context: CommandContext = .explicitWindow) -> Bool {
        guard let window, candidate === window, window.isVisible,
              context == .explicitWindow || window.isKeyWindow,
              window.attachedSheet == nil, presentation.libraryAvailable,
              presentation.fileCommandRequest == nil, presentation.newPromptRequest == nil,
              !presentation.isScopeDropPending,
              presentation.editorState.status != .commandRunning,
              presentation.editorState.pendingDecision == nil,
              presentation.editorState.queuedActions.isEmpty,
              presentation.imports?.isChoosing != true else { return false }
        // Filtering input remains enabled during its own composition. Menu and
        // toolbar commands still wait for marked text to commit or cancel.
        return context == .textInput || (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validateCommand(item, in: window, context: .responderChain)
    }

    private func validateCommand(_ item: NSMenuItem, in candidate: NSWindow?, context: CommandContext) -> Bool {
        updateCommandTitle(item)
        guard commandsAvailable(in: candidate, context: context) else { return false }
        switch item.action {
        case #selector(newDocument(_:)): return presentation.canCreatePrompt
        case #selector(saveDocument(_:)): return presentation.canSave || presentation.canShowConflict
        case #selector(duplicateDocument(_:)): return presentation.canSaveAsCopy
        case #selector(renameDocument(_:)), #selector(moveDocument(_:)), #selector(deleteLibraryPrompt(_:)):
            return presentation.canRunFileCommand
        case #selector(revertDocumentToSaved(_:)): return presentation.canRevert
        case #selector(showInFinder(_:)): return presentation.editorState.prompt != nil
        case #selector(toggleFavorite(_:)): return presentation.canToggleFavorite
        case #selector(showEdit(_:)), #selector(showPreview(_:)), #selector(showSource(_:)), #selector(selectEditorMode(_:)):
            return presentation.editorState.prompt != nil
        case #selector(togglePromptDetails(_:)): return presentation.editorState.form != nil
        case #selector(showFields(_:)), #selector(showHistory(_:)):
            return presentation.editorState.prompt != nil
        case #selector(showAssistant(_:)):
            return presentation.canShowAssistant
        case #selector(writeWithAssistant(_:)):
            return presentation.canGeneratePrompt
        case #selector(reviewWithAssistant(_:)), #selector(improveWithAssistant(_:)):
            if let assistant = presentation.assistant { return assistant.canReview }
            let state = presentation.editorState
            return presentation.canShowAssistant && state.prompt != nil && state.source != nil
                && state.readOnlyReason == nil && !state.isPrivate && state.conflict == nil
                && state.status != .loading && state.status != .saving
                && !state.issues.contains { $0.severity == .error }
        case #selector(importFromMenu): return presentation.imports?.canImport == true
        case #selector(searchLibrary(_:)): return presentation.canFocusFilter
        case #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)):
            return true
        case Selector(("toggleSidebar:")), Selector(("toggleInspector:")),
             Selector(("toggleToolbarShown:")), Selector(("runToolbarCustomizationPalette:")):
            return true
        default: return false
        }
    }

    private func updateCommandTitle(_ item: NSMenuItem) {
        switch item.action {
        case #selector(toggleFavorite(_:)):
            item.title = presentation.openPromptRow?.favorite == true ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite
        case #selector(showEdit(_:)): item.state = presentation.editorMode == .edit ? .on : .off
        case #selector(showPreview(_:)): item.state = presentation.editorMode == .preview ? .on : .off
        case #selector(showSource(_:)): item.state = presentation.editorMode == .source ? .on : .off
        case #selector(togglePromptDetails(_:)):
            item.title = presentation.editorMode == .edit && presentation.isDetailsVisible
                ? LibraryFormStrings.hideDetails : LibraryFormStrings.showDetails
        case #selector(showFields(_:)): item.state = presentation.isInspectorVisible && presentation.inspectorPane == .fields ? .on : .off
        case #selector(showHistory(_:)): item.state = presentation.isInspectorVisible && presentation.inspectorPane == .history ? .on : .off
        case #selector(showAssistant(_:)): item.state = presentation.isAssistantVisible ? .on : .off
        case Selector(("toggleSidebar:")):
            item.title = splitController?.splitViewItems.first?.isCollapsed == true ? LibraryStrings.showSidebar : LibraryStrings.hideSidebar
        case Selector(("toggleInspector:")):
            item.title = presentation.isInspectorVisible ? LibraryStrings.hideInspector : LibraryStrings.showInspector
        case Selector(("toggleToolbarShown:")):
            item.title = window?.toolbar?.isVisible == true ? LibraryStrings.hideToolbar : LibraryStrings.showToolbar
        default: break
        }
    }

    /// File ▸ New Prompt asks for a title, then creates the prompt in the
    /// selected folder (§11.7).
    @objc func newDocument(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.canCreatePrompt else { return }
        presentation.requestNewPrompt()
    }
    @objc func saveDocument(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.save()
    }
    @objc func duplicateDocument(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.saveAsCopy()
    }
    @objc func renameDocument(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.requestFileCommand(.rename)
    }
    @objc func moveDocument(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.requestFileCommand(.move)
    }
    @objc func deleteLibraryPrompt(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.requestFileCommand(.delete)
    }
    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.revert()
    }
    @objc func showInFinder(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.revealPrompt()
    }
    @objc func toggleFavorite(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.toggleFavorite()
    }
    @objc func showEdit(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.editorState.prompt != nil else { return }
        window?.makeFirstResponder(nil)
        presentation.focusEditor()
    }
    @objc func showPreview(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.editorState.prompt != nil else { return }
        window?.makeFirstResponder(nil)
        presentation.editorMode = .preview
    }
    @objc func showSource(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.editorState.prompt != nil else { return }
        window?.makeFirstResponder(nil)
        presentation.focusEditor(mode: .source)
    }
    @objc func togglePromptDetails(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        window?.makeFirstResponder(nil)
        presentation.toggleDetails()
    }
    @objc func selectEditorMode(_ sender: NSToolbarItemGroup) {
        switch LibraryViewState.EditorMode(rawValue: sender.selectedIndex) {
        case .edit: showEdit(sender)
        case .preview: showPreview(sender)
        case .source: showSource(sender)
        case nil: break
        }
    }
    @objc func showFields(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.editorState.prompt != nil else { return }
        presentation.showInspector(.fields)
    }
    @objc func showHistory(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.editorState.prompt != nil else { return }
        presentation.showInspector(.history)
    }
    @objc func showAssistant(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.showAssistant()
    }
    @objc func reviewWithAssistant(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.showAssistant()
        presentation.assistant?.flow = .review
        presentation.assistant?.review()
    }
    @objc func improveWithAssistant(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.showAssistant()
        presentation.assistant?.flow = .improve
        presentation.assistant?.focusInstruction()
    }
    @objc func writeWithAssistant(_ sender: Any?) {
        guard commandsAvailable(in: window) else { return }
        presentation.generatePromptWithAssistant()
    }
    @objc func importFromMenu() {
        guard commandsAvailable(in: window) else { return }
        presentation.imports?.choose()
    }
    @objc func searchLibrary(_ sender: Any?) {
        guard commandsAvailable(in: window), presentation.canFocusFilter, let toolbar = window?.toolbar else { return }
        synchronizeSearch {
            if searchItem == nil { toolbar.insertItem(withItemIdentifier: .librarySearch, at: toolbar.items.count) }
            toolbar.isVisible = true
            renderSearchQuery(presentation.snapshot.filter)
            searchItem?.beginSearchInteraction()
            if let field = searchItem?.searchField { window?.makeFirstResponder(field) }
            // Reacquire the editor after AppKit establishes the interaction.
            renderSearchQuery(presentation.snapshot.filter)
        }
    }

    // A menu action reaches the controller only when no focused text view
    // already handles it. Find still opens the source view's native find bar.
    @objc func performFindPanelAction(_ sender: Any?) { routeFind(sender, action: .panel) }
    func routeTextFinder(_ sender: Any?) { routeFind(sender, action: .textFinder) }

    private func routeFind(_ sender: Any?, action: FindAction) {
        guard commandsAvailable(in: window) else { return }
        guard presentation.editorState.prompt != nil else { searchLibrary(sender); return }
        if presentation.editorMode == .preview { presentation.focusEditor() }
        // SwiftUI installs Edit on the next turn when Preview was visible.
        enqueueUIAction { [weak self] in
            self?.runFindAction(sender, action: action)
        }
    }

    private func runFindAction(_ sender: Any?, action: FindAction) {
        guard commandsAvailable(in: window), let root = window?.contentView else { return }
        root.layoutSubtreeIfNeeded()
        guard let text = sourceTextView(in: root) else { searchLibrary(sender); return }
        window?.makeFirstResponder(text)
        if action == .textFinder { text.performTextFinderAction(sender) }
        else { text.performFindPanelAction(sender) }
    }

    private func sourceTextView(in view: NSView) -> LibrarySourceTextView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let text = view as? LibrarySourceTextView { return text }
        for child in view.subviews {
            if let text = sourceTextView(in: child) { return text }
        }
        return nil
    }
}
