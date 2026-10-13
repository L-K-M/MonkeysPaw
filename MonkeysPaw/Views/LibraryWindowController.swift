import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI

final class LibraryWindowController: NSObject, NSWindowDelegate {
    typealias DialogPresenter = (NSWindow, LibraryEditorDialog, @escaping (LibraryEditorResponse) -> Void) -> (() -> Void)
    typealias ImportChooser = (NSWindow, @escaping ([URL]) -> Void) -> (() -> Void)
    let presentation: LibraryViewState
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private var keyMonitor: Any?
    private var isTornDown = false
    private let presentDialog: DialogPresenter
    private let importChooser: ImportChooser
    private var activeDialog: LibraryEditorDialog?
    private var cancelDialog: (() -> Void)?
    private var dialogRevision: UInt64 = 0
    private var closeRequested = false
    private var dismissedConflict: EditorConflict?

    init(model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         presentDialog: @escaping DialogPresenter = LibraryWindowController.presentEditorDialog,
         imports: LibraryImportViewState? = nil,
         importChooser: @escaping ImportChooser = MacImportChooser.choose,
         revealLibrary: @escaping () -> Void) {
        self.mainThread = mainThread
        self.activation = activation
        self.presentDialog = presentDialog
        self.importChooser = importChooser
        presentation = LibraryViewState(model: model, editor: editor, libraryPath: libraryPath, available: available,
            mainThread: mainThread, imports: imports, revealLibrary: revealLibrary)
        super.init()
        connectImportChooser()
        presentation.onEditorChange = { [weak self] in self?.updateDialog() }
        presentation.onConflictRequested = { [weak self] in
            self?.dismissedConflict = nil
            self?.updateDialog()
        }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func rebind(to model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
                imports: LibraryImportViewState? = nil) {
        guard !isTornDown else { return }
        endDialog()
        dismissedConflict = nil
        closeRequested = false
        presentation.rebind(to: model, editor: editor, libraryPath: libraryPath, available: available, imports: imports)
        connectImportChooser()
    }

    private func connectImportChooser() {
        presentation.imports?.onChoose = { [weak self] done in
            guard let self, !self.isTornDown, let window = self.window,
                  window.isVisible, window.attachedSheet == nil else { done([]); return {} }
            return self.importChooser(window, done)
        }
    }

    func show() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.presentation.didShow()
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
            if window.isMiniaturized { window.deminiaturize(nil) }
            self.observeKeys()
            self.activation.show(window)
            self.updateDialog()
        }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        endDialog()
        presentation.deactivate()
        removeKeyMonitor()
        (window as? LibraryWindow)?.closeAfterApproval()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        presentation.imports?.cancelChoosing()
        endDialog()
        removeKeyMonitor()
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
                desired = .conflict(conflict, status: state.status)
            } else if let decision = state.pendingDecision { desired = .decision(decision, status: state.status) }
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
                    case (.decision(let decision, _), .decision(let choice)):
                        self.presentation.editor.resolveDecision(choice, id: decision.id)
                    case (.conflict, .conflict(let choice)):
                        self.presentation.editor.resolveConflict(choice)
                    case (.conflict(let conflict, _), .dismissConflict):
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

    /// Explicit routing seam: hosted tests call this directly because sendEvent
    /// does not pass through local monitors or guarantee a regular key window.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !isTornDown, let window, window.isVisible, event.window === window else { return false }
        if let client = window.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            guard activeDialog == nil else { return false }
            escape()
            return true
        }
        if flags == [.command],
           event.keyCode == UInt16(kVK_ANSI_S) || event.charactersIgnoringModifiers?.lowercased() == "s" {
            presentation.save()
            return true
        }
        if flags == [.command],
           event.keyCode == UInt16(kVK_ANSI_W) || event.charactersIgnoringModifiers?.lowercased() == "w" {
            requestClose()
            return true
        }
        if flags == [.command, .shift],
           event.keyCode == UInt16(kVK_ANSI_F) || event.charactersIgnoringModifiers?.lowercased() == "f" {
            presentation.toggleFavorite()
            return true
        }
        return false
    }

    private func escape() {
        guard !isTornDown, !presentation.clearFilterForEscape() else { return }
        requestClose()
    }

    private func observeKeys() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    static func makeEditorAlert(for dialog: LibraryEditorDialog) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dialog.title
        alert.informativeText = dialog.message
        for response in dialog.responses {
            let button = alert.addButton(withTitle: response.title)
            // Return saves unsaved edits; overwriting an external version requires an explicit choice.
            switch response {
            case .decision(.save), .rename, .move: button.keyEquivalent = "\r"
            case .decision(.cancel), .dismissConflict, .cancelFileCommand: button.keyEquivalent = "\u{1b}"
            case .decision(.discard), .conflict, .delete: button.keyEquivalent = ""
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
        let size = Limits.setupWindowSize
        let window = LibraryWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = LibraryStrings.title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: CGFloat(size.width), height: CGFloat(size.height))
        window.delegate = self
        window.onEscape = { [weak self] in self?.escape() }
        window.onCloseRequest = { [weak self] in self?.requestClose() }
        let content = NSHostingView(rootView: LibraryView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}

private final class LibraryWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func close() { onCloseRequest?() }
    func closeAfterApproval() { super.close() }
}
