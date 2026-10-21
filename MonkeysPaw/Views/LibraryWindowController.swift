import AppKit
import Combine
import MonkeysPawCore
import SwiftUI

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    typealias DialogPresenter = (NSWindow, LibraryEditorDialog, @escaping (LibraryEditorResponse) -> Void) -> (() -> Void)
    typealias ImportChooser = (NSWindow, @escaping ([URL]) -> Void) -> (() -> Void)
    let presentation: LibraryViewState
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private var isTornDown = false
    private let presentDialog: DialogPresenter
    private let importChooser: ImportChooser
    private var activeDialog: LibraryEditorDialog?
    private var cancelDialog: (() -> Void)?
    private var dialogRevision: UInt64 = 0
    private var closeRequested = false
    private var dismissedConflict: EditorConflict?
    private(set) var splitController: NSSplitViewController?
    private(set) var promptList: LibraryPromptListController?
    private(set) var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    private var presentationObservation: AnyCancellable?
    private var presentationUpdatePending = false
    private var appliedSearchFocusRevision: UInt64 = 0
    var searchItem: NSSearchToolbarItem? {
        window?.toolbar?.items.first { $0.itemIdentifier == .librarySearch } as? NSSearchToolbarItem
    }
    private var modeItem: NSToolbarItemGroup? {
        window?.toolbar?.items.first { $0.itemIdentifier == .libraryEditorMode } as? NSToolbarItemGroup
    }

    init(model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         presentDialog: @escaping DialogPresenter = LibraryWindowController.presentEditorDialog,
         imports: LibraryImportViewState? = nil,
         makeAssistant: LibraryViewState.AssistantFactory? = nil,
         scheduler: MonkeysPawCore.Scheduler? = nil,
         conflictProvider: LibraryViewState.ConflictProvider? = nil,
         syncStatus: SyncStatusViewState? = nil,
         importChooser: @escaping ImportChooser = MacImportChooser.choose,
         revealPrompt: @escaping (RelativePath) -> Void = { _ in },
         revealLibrary: @escaping () -> Void) {
        self.mainThread = mainThread
        self.activation = activation
        self.presentDialog = presentDialog
        self.importChooser = importChooser
        presentation = LibraryViewState(model: model, editor: editor, libraryPath: libraryPath, available: available,
            mainThread: mainThread, imports: imports, makeAssistant: makeAssistant, scheduler: scheduler,
            conflictProvider: conflictProvider, syncStatus: syncStatus,
            revealPrompt: revealPrompt, revealLibrary: revealLibrary)
        super.init(window: nil)
        connectImportChooser()
        presentation.onEditorChange = { [weak self] in self?.updateDialog() }
        presentation.onConflictRequested = { [weak self] in
            self?.dismissedConflict = nil
            self?.updateDialog()
        }
        presentationObservation = presentation.objectWillChange.sink { [weak self] _ in
            self?.schedulePresentationUpdate()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func rebind(to model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
                imports: LibraryImportViewState? = nil, makeAssistant: LibraryViewState.AssistantFactory? = nil,
                conflictProvider: LibraryViewState.ConflictProvider? = nil, syncStatus: SyncStatusViewState? = nil) {
        guard !isTornDown else { return }
        endDialog()
        dismissedConflict = nil
        closeRequested = false
        presentation.rebind(to: model, editor: editor, libraryPath: libraryPath, available: available,
            imports: imports, makeAssistant: makeAssistant, conflictProvider: conflictProvider, syncStatus: syncStatus)
        connectImportChooser()
    }

    private func connectImportChooser() {
        presentation.imports?.onChoose = { [weak self] done in
            guard let self, !self.isTornDown, let window = self.window,
                  window.isVisible, window.attachedSheet == nil else { done([]); return {} }
            return self.importChooser(window, done)
        }
    }

    // Window construction is explicit in show(); reading window before the first
    // show must not attempt to load a nib in hosted tests or during app launch.
    override func loadWindow() {}

    func show() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.presentation.didShow()
            let window = self.window ?? self.makeWindow()
            self.window = window
            self.refreshWindowPresentation()
            if window.isMiniaturized { window.deminiaturize(nil) }
            self.activation.show(window)
            self.refreshWindowPresentation()
            self.updateDialog()
        }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        endDialog()
        presentation.deactivate()
        (window as? LibraryWindow)?.closeAfterApproval()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        presentation.didHide()
        presentation.retireAssistant()
        presentation.imports?.cancelChoosing()
        endDialog()
    }

    func windowDidDeminiaturize(_ notification: Notification) { refreshDialogsAfterVisibilityChange() }
    func windowDidBecomeKey(_ notification: Notification) { refreshDialogsAfterVisibilityChange() }
    func windowDidChangeOcclusionState(_ notification: Notification) { refreshDialogsAfterVisibilityChange() }

    func refreshDialogsAfterVisibilityChange() { updateDialog() }

    func requestClose() {
        guard !isTornDown, !closeRequested else { return }
        // The reusable window retains running imports and reports for reopening.
        presentation.imports?.cancelChoosing()
        closeRequested = true
        // Release only the assistant's guard so the close can reach its own decision.
        presentation.assistant?.cancelPendingAcceptance()
        presentation.requestClose { [weak self] result in
            guard let self, !self.isTornDown else { return }
            self.closeRequested = false
            if result == .allowed { (self.window as? LibraryWindow)?.closeAfterApproval() }
        }
    }

    private func updateDialog() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            let state = self.presentation.editorState
            let awaitingConflict = state.conflict.map {
                $0.kind == .modified && $0.theirsSource == nil && $0.readOnlyReason == nil && $0.failure == nil
            } ?? false
            // A fresh detection or retry invalidates dismissal, even while hidden.
            if state.conflict == nil || state.status == .saving || state.status == .loading || state.status == .commandRunning
                || state.conflict?.isLoading == true || awaitingConflict { self.dismissedConflict = nil }
            guard let window = self.window, window.isVisible else { return }
            let desired: LibraryEditorDialog?
            if state.status == .saving || state.status == .loading || state.status == .commandRunning
                || state.conflict?.isLoading == true || awaitingConflict {
                desired = nil
            } else if let conflict = state.conflict, conflict != self.dismissedConflict {
                desired = .conflict(conflict, status: state.status, title: self.presentation.displayTitle)
            } else if let decision = state.pendingDecision { desired = .decision(decision, status: state.status, title: self.presentation.displayTitle) }
            else if let request = self.presentation.fileCommandRequest { desired = .fileCommand(request) }
            else { desired = nil }
            guard desired != self.activeDialog else { return }
            self.endDialog()
            guard let desired else { return }
            self.presentation.imports?.cancelChoosing()
            self.activeDialog = desired
            let revision = self.dialogRevision
            let cancel = self.presentDialog(window, desired) { [weak self] response in
                self?.mainThread.run { [weak self] in
                    guard let self, !self.isTornDown, self.dialogRevision == revision,
                          self.activeDialog == desired, desired.accepts(response) else { return }
                    self.activeDialog = nil
                    self.cancelDialog = nil
                    self.dialogRevision &+= 1
                    switch (desired, response) {
                    case (.decision(let decision, _, _), .decision(let choice)):
                        self.presentation.editor.resolveDecision(choice, id: decision.id)
                    case (.conflict, .conflict(let choice)):
                        self.presentation.editor.resolveConflict(choice)
                    case (.conflict(let conflict, _, _), .dismissConflict):
                        self.dismissedConflict = conflict
                        if let decision = self.presentation.editor.state.pendingDecision {
                            self.presentation.editor.resolveDecision(.cancel, id: decision.id)
                        }
                    case (.fileCommand(let request), _):
                        self.presentation.resolveFileCommand(response, id: request.id)
                    default: break
                    }
                }
            }
            if self.activeDialog == desired, self.dialogRevision == revision { self.cancelDialog = cancel }
        }
    }

    private func endDialog() {
        dialogRevision &+= 1
        activeDialog = nil
        let cancel = cancelDialog
        cancelDialog = nil
        cancel?()
    }

    // objectWillChange fires before @Published assigns. One run-loop callback
    // reads the completed batch, then uses the injected UI-thread boundary.
    private func schedulePresentationUpdate() {
        guard !presentationUpdatePending else { return }
        presentationUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.mainThread.run { [weak self] in
                guard let self else { return }
                self.presentationUpdatePending = false
                self.refreshWindowPresentation()
            }
        }
    }

    override func performTextFinderAction(_ sender: Any?) { routeTextFinder(sender) }

    func enqueueUIAction(_ work: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { [mainThread] in mainThread.run(work) }
    }

    func refreshWindowPresentation() {
        guard !isTornDown, let window else { return }
        let state = presentation.editorState
        if let prompt = state.prompt {
            window.title = presentation.displayTitle
            window.subtitle = prompt.relativePath.string
            window.representedURL = URL(fileURLWithPath: presentation.activeLibraryPath, isDirectory: true)
                .appendingPathComponent(prompt.relativePath.string)
        } else {
            window.title = LibraryStrings.sectionTitle(presentation.snapshot.selectedSection,
                sections: presentation.snapshot.sections)
            window.subtitle = LibraryStrings.promptCount(presentation.snapshot.rows.count)
            window.representedURL = nil
        }
        window.isDocumentEdited = state.isDirty
        if let item = inspectorItem, item.isCollapsed == presentation.isInspectorVisible {
            let collapsed = !presentation.isInspectorVisible
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { item.isCollapsed = collapsed }
            else { item.animator().isCollapsed = collapsed }
        }
        if let field = searchItem?.searchField, !field.stringValue.utf8.elementsEqual(presentation.snapshot.filter.utf8),
           (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = presentation.snapshot.filter
        }
        modeItem?.selectedIndex = presentation.editorMode == .edit ? 0 : 1
        updateToolbarItems()
        window.toolbar?.validateVisibleItems()
        if appliedSearchFocusRevision != presentation.focusRevision, commandsAvailable(in: window) {
            appliedSearchFocusRevision = presentation.focusRevision
            if searchItem != nil, window.toolbar?.isVisible == true { searchLibrary(nil) }
        }
    }

    static func makeEditorAlert(for dialog: LibraryEditorDialog) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dialog.title
        alert.informativeText = dialog.message
        let isRevert: Bool
        if case .decision(let decision, _, _) = dialog { isRevert = decision.action == .revert }
        else { isRevert = false }
        for response in dialog.responses {
            let title = isRevert && response == .decision(.discard) ? EditorStrings.revert : response.title
            let button = alert.addButton(withTitle: title)
            switch response {
            case .decision(.save), .rename, .move:
                button.keyEquivalent = "\r"
            case .decision(.cancel), .dismissConflict, .cancelFileCommand:
                button.keyEquivalent = "\u{1b}"
            case .decision(.discard):
                button.keyEquivalent = isRevert ? "" : "d"
                button.keyEquivalentModifierMask = isRevert ? [] : .command
            case .conflict, .delete:
                button.keyEquivalent = ""
            }
            button.hasDestructiveAction = response == .decision(.discard) || response == .conflict(.discard) || response == .delete
        }
        if case .fileCommand(let request) = dialog { configureFileCommandAlert(alert, request: request) }
        return alert
    }

    static func presentEditorDialog(in window: NSWindow, dialog: LibraryEditorDialog,
                                    done: @escaping (LibraryEditorResponse) -> Void) -> (() -> Void) {
        let alert = makeEditorAlert(for: dialog)
        let responses = dialog.responses
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if responses.indices.contains(index) {
                done(fileCommandResponse(responses[index], alert: alert))
                return
            }
            // Non-button dismissal must complete the pending dialog without losing the draft.
            switch dialog {
            case .decision: done(.decision(.cancel))
            case .conflict: done(.dismissConflict)
            case .fileCommand: done(.cancelFileCommand)
            }
        }
        return {
            guard alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = LibraryWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = LibraryStrings.sectionTitle(.all, sections: presentation.snapshot.sections)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.delegate = self
        window.onCloseRequest = { [weak self] in self?.requestClose() }
        window.validateCommand = { [weak self] item in self?.validateMenuItem(item) == true }
        let split = LibrarySplitViewController()
        split.validateCommand = { [weak self] item in self?.validateMenuItem(item) == true }
        split.splitView.isVertical = true
        split.splitView.autosaveName = "LibrarySplitView"
        let sidebar = NSHostingController(rootView: LibrarySidebarView(presentation: presentation))
        let editor = NSHostingController(rootView: LibraryEditorView(presentation: presentation))
        let inspector = NSHostingController(rootView: LibraryInspectorView(presentation: presentation))
        sidebar.sizingOptions = []
        editor.sizingOptions = []
        inspector.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.holdingPriority = .init(rawValue: 251)
        let list = LibraryPromptListController(presentation: presentation, mainThread: mainThread)
        list.validateCommand = { [weak self] item in self?.validateLibraryMenuItem(item, in: self?.window) == true }
        let listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 240
        listItem.holdingPriority = .init(rawValue: 251)
        listItem.automaticallyAdjustsSafeAreaInsets = true
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 360
        editorItem.holdingPriority = .init(rawValue: 200)
        editorItem.automaticallyAdjustsSafeAreaInsets = true
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 560
        inspectorItem.canCollapse = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.isCollapsed = !presentation.isInspectorVisible
        inspectorItem.holdingPriority = .init(rawValue: 252)
        for item in [sidebarItem, listItem, editorItem, inspectorItem] { split.addSplitViewItem(item) }
        self.splitController = split
        self.promptList = list
        self.inspectorItem = inspectorItem
        inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            self?.mainThread.run { [weak self] in self?.presentation.setInspectorVisible(!item.isCollapsed) }
        }
        window.contentViewController = split
        window.toolbar = makeToolbar()
        if !window.setFrameUsingName("Library") { window.center() }
        window.setFrameAutosaveName("Library")
        return window
    }
}

private final class LibraryWindow: NSWindow {
    var onCloseRequest: (() -> Void)?
    var validateCommand: ((NSMenuItem) -> Bool)?

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleToolbarShown(_:)), #selector(runToolbarCustomizationPalette(_:)):
            return validateCommand?(item) == true
        default: return super.validateMenuItem(item)
        }
    }

    override func close() { onCloseRequest?() }
    func closeAfterApproval() { super.close() }
}
