import AppKit
import MonkeysPawCore
import SwiftUI

/// Builds one reusable panel and marshals every window operation to AppKit's thread.
final class PanelController: PanelWindow {
    enum HideReason { case delivery, dismissal, blur }

    var rootView: (() -> AnyView)?
    var onCancel: (() -> Void)?
    var onHide: ((HideReason) -> Void)?
    var onShow: (() -> Void)?
    var onEscape: (() -> Void)?
    var onKey: ((NSEvent, FieldKind?) -> Bool)?

    private let mainThread: MainThread
    private let scheduler: Scheduler
    private let log: LogSink
    private let keyWindow: () -> NSWindow?
    private var panel: PromptPanel?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var presentationGeneration = 0
    private var pendingDismissal = HideReason.dismissal

    var isVisible: Bool { panel?.isVisible == true }
    var isActiveAndVisible: Bool { isVisible && panel?.isKeyWindow == true }

    init(mainThread: MainThread, scheduler: Scheduler, log: LogSink,
         keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.mainThread = mainThread
        self.scheduler = scheduler
        self.log = log
        self.keyWindow = keyWindow
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func show() {
        mainThread.run { [weak self] in self?.showOnMainThread() }
    }

    func cancelForOwnedWindow() {
        mainThread.run { [weak self] in
            guard let self, self.isVisible else { return }
            // Opening our own window is a new focus choice before AppKit makes
            // it key. Still cancel through the model to clear the armed target.
            self.pendingDismissal = .blur
            self.onCancel?()
        }
    }

    func hide() {
        mainThread.run { [weak self] in
            guard let self, self.isVisible else { return }
            // Capture before orderOut: Escape may automatically make Setup key
            // afterward. A queued dismissal must also respect an already-key window.
            let reason = Self.dismissalReason(requested: self.pendingDismissal, panel: self.panel,
                                               keyWindow: self.keyWindow())
            self.pendingDismissal = .dismissal
            self.hideOnMainThread(reason: reason)
        }
    }

    func hideForDelivery() {
        mainThread.run { [weak self] in self?.hideOnMainThread(reason: .delivery) }
    }

    private func showOnMainThread() {
        let cursor = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenIndex = PanelPlacement.screenIndex(at: cursor, frames: screens.map(\.frame))
        // A display change can briefly leave the cursor outside every screen.
        // The fallback still uses a visibleFrame and the same clamping rules.
        let screen = screenIndex.map { screens[$0] } ?? NSScreen.main ?? screens.first
        guard let screen else {
            log.write(.warning, "Panel unavailable: no screen")
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(PanelPlacement.frame(at: cursor, in: screen.visibleFrame), display: true)

        // Order in BEFORE activating: activation follows our ordered-in window
        // onto the current Space instead of pulling the user to another Space.
        panel.orderFrontRegardless()
        // A non-activating panel can show a caret without receiving keystrokes.
        // Activating routes them to our key window; the all-Spaces flags keep
        // the current full-screen Space in place.
        NSApp.activate()
        panel.makeKey()
        presentationGeneration &+= 1
        pendingDismissal = .dismissal
        observeBlur(of: panel)
        observeKeys(of: panel)
        onShow?()
    }

    private func hideOnMainThread(reason: HideReason) {
        presentationGeneration &+= 1
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // DeliveryService restores after the settle delay. This path only tells
        // the focus driver whether that restore is delivery or guarded dismissal.
        onHide?(reason)
        panel?.orderOut(nil)
    }

    private func observeBlur(of panel: PromptPanel) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let generation = self.presentationGeneration
            self.scheduler.after(Limits.blurHideDelay) { [weak self] in
                self?.mainThread.run { [weak self] in
                    guard let self, generation == self.presentationGeneration,
                          self.isVisible, self.panel?.isKeyWindow == false else { return }
                    self.pendingDismissal = .blur
                    self.onCancel?()
                }
            }
        }
    }

    private func observeKeys(of panel: PromptPanel) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        // The field editor consumes Return/Tab/Escape before NSPanel.keyDown.
        // A local monitor sees those events first, including in a nonactivating
        // key panel. Scope it to this visible key window and remove it on hide.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel, panel.isKeyWindow else { return event }
            let kind = Self.focusedFieldKind(in: panel)
            // Keep native Return activation for focused action buttons.
            if panel.firstResponder is NSButton, kind == nil,
               (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                return event
            }
            return self.onKey?(event, kind) == true ? nil : event
        }
    }

    static func focusedFieldKind(in window: NSWindow) -> FieldKind? {
        if window.firstResponder is PickerMultilineTextView { return .multiline }
        if window.firstResponder is PickerChoiceButton { return .choice }
        // Match the shared field editor by identity. Its delegate is exposed
        // as NSTextViewDelegate, while NSTextField's public conformance is
        // different; currentEditor avoids relying on that private bridge.
        if let editor = window.firstResponder as? NSText,
           let content = window.contentView,
           let field = textField(in: content, matching: { $0.currentEditor() === editor }) { return field.fieldKind }
        return (window.firstResponder as? PickerTextField)?.fieldKind
    }

    /// Pointer selection and native Tab can leave the results list focused.
    /// Printable input still belongs to search; dispatch to the field editor
    /// directly so this event cannot recurse through the local monitor.
    func forwardTypingToSearch(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags.subtracting([.shift, .option]).isEmpty,
              event.specialKey == nil || event.keyCode == 51,
              let characters = event.characters, !characters.isEmpty,
              event.keyCode == 51 || characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let panel, panel.isVisible, panel.isKeyWindow, let content = panel.contentView,
              let query = Self.textField(in: content, matching: { $0.fieldKind == nil }),
              panel.firstResponder !== query.currentEditor(),
              panel.makeFirstResponder(query), let editor = query.currentEditor() else { return false }
        // Refocusing a text field can select its whole value. Continue the
        // query instead of replacing it when typing from a selected result.
        (editor as? NSTextView)?.setSelectedRange(NSRange(location: query.stringValue.utf16.count, length: 0))
        editor.keyDown(with: event)
        return true
    }

    private static func textField(in view: NSView, matching predicate: (PickerTextField) -> Bool) -> PickerTextField? {
        if let field = view as? PickerTextField, predicate(field) { return field }
        for child in view.subviews {
            if let field = textField(in: child, matching: predicate) { return field }
        }
        return nil
    }

    static func dismissalReason(requested: HideReason, panel: NSWindow?,
                                keyWindow: NSWindow?) -> HideReason {
        guard requested == .dismissal, let keyWindow, keyWindow !== panel else { return requested }
        return .blur
    }

    private func makePanel() -> PromptPanel {
        let content = NSHostingView(rootView: rootView?() ?? AnyView(EmptyView()))
        // Placement owns the frame; the hosting view must not propose its own size.
        content.sizingOptions = []

        let panel = PromptPanel(content: content)
        panel.onCancel = { [weak self] in self?.onCancel?() }
        panel.onEscape = { [weak self] in self?.onEscape?() }
        return panel
    }
}
