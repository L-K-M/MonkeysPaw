import AppKit
import MonkeysPawCore
import SwiftUI

/// Builds one reusable panel and marshals every window operation to AppKit's thread.
final class PanelController: PanelWindow {
    enum HideReason { case delivery, dismissal, blur }

    var rootView: (() -> AnyView)?
    var onCancel: (() -> Void)?
    var onHide: ((HideReason) -> Void)?

    private let mainThread: MainThread
    private let scheduler: Scheduler
    private let log: LogSink
    private let keyWindow: () -> NSWindow?
    private var panel: PromptPanel?
    private var resignObserver: NSObjectProtocol?
    private var presentationGeneration = 0
    private var pendingDismissal = HideReason.dismissal

    var isVisible: Bool { panel?.isVisible == true }

    init(mainThread: MainThread, scheduler: Scheduler, log: LogSink,
         keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.mainThread = mainThread
        self.scheduler = scheduler
        self.log = log
        self.keyWindow = keyWindow
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
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
    }

    private func hideOnMainThread(reason: HideReason) {
        presentationGeneration &+= 1
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
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
                guard let self, generation == self.presentationGeneration,
                      self.isVisible, self.panel?.isKeyWindow == false else { return }
                self.pendingDismissal = .blur
                self.onCancel?()
            }
        }
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
        return panel
    }
}
