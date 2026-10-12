import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI

final class LibraryWindowController: NSObject, NSWindowDelegate {
    typealias DialogPresenter = (NSWindow, LibraryEditorDialog, @escaping (LibraryEditorResponse) -> Void) -> (() -> Void)
    let presentation: LibraryViewState
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private var keyMonitor: Any?
    private var isTornDown = false
    private let presentDialog: DialogPresenter
    private var activeDialog: LibraryEditorDialog?
    private var cancelDialog: (() -> Void)?
    private var dialogRevision: UInt64 = 0
    private var closeRequested = false

    init(model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         presentDialog: @escaping DialogPresenter = LibraryEditorDialog.present,
         revealLibrary: @escaping () -> Void) {
        self.mainThread = mainThread
        self.activation = activation
        self.presentDialog = presentDialog
        presentation = LibraryViewState(model: model, editor: editor, libraryPath: libraryPath, available: available,
            mainThread: mainThread, revealLibrary: revealLibrary)
        super.init()
        presentation.onEditorChange = { [weak self] in self?.updateDialog() }
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func rebind(to model: LibraryBrowserModel, editor: EditorModel, libraryPath: String, available: Bool) {
        guard !isTornDown else { return }
        endDialog()
        closeRequested = false
        presentation.rebind(to: model, editor: editor, libraryPath: libraryPath, available: available)
    }

    func show() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.presentation.didShow()
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
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
        endDialog()
        removeKeyMonitor()
    }

    func requestClose() {
        guard !isTornDown, !closeRequested else { return }
        closeRequested = true
        presentation.requestClose { [weak self] result in
            guard let self, !self.isTornDown else { return }
            self.closeRequested = false
            if result == .allowed { (self.window as? LibraryWindow)?.closeAfterApproval() }
        }
    }

    private func updateDialog() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown, let window = self.window, window.isVisible else { return }
            let state = self.presentation.editorState
            let desired: LibraryEditorDialog?
            let awaitingConflict = state.conflict.map {
                $0.kind == .modified && $0.theirsSource == nil && $0.readOnlyReason == nil && $0.failure == nil
            } ?? false
            if state.status == .saving || state.status == .loading || state.conflict?.isLoading == true || awaitingConflict {
                desired = nil
            } else if let conflict = state.conflict { desired = .conflict(conflict) }
            else if let decision = state.pendingDecision { desired = .decision(decision) }
            else { desired = nil }
            guard desired != self.activeDialog else { return }
            self.endDialog()
            guard let desired else { return }
            self.activeDialog = desired
            let revision = self.dialogRevision
            let cancel = self.presentDialog(window, desired) { [weak self] response in
                self?.mainThread.run { [weak self] in
                    guard let self, !self.isTornDown, self.dialogRevision == revision,
                          self.activeDialog == desired, desired.responses.contains(response) else { return }
                    self.activeDialog = nil
                    self.cancelDialog = nil
                    self.dialogRevision &+= 1
                    switch (desired, response) {
                    case (.decision(let decision), .decision(let choice)):
                        self.presentation.editor.resolveDecision(choice, id: decision.id)
                    case (.conflict, .conflict(let choice)):
                        self.presentation.editor.resolveConflict(choice)
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
