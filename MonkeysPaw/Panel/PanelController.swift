import AppKit
import MonkeysPawCore
import SwiftUI

/// Builds one reusable panel and marshals every window operation to AppKit's thread.
final class PanelController {
    private let mainThread: MainThread
    private let log: LogSink
    private var panel: PromptPanel?

    init(mainThread: MainThread, log: LogSink) {
        self.mainThread = mainThread
        self.log = log
    }

    func show() {
        mainThread.run { [weak self] in self?.showOnMainThread() }
    }

    func hide() {
        mainThread.run { [weak self] in self?.hideOnMainThread() }
    }

    func toggle() {
        mainThread.run { [weak self] in
            guard let self else { return }

            if self.panel?.isVisible == true {
                self.hideOnMainThread()
            } else {
                self.showOnMainThread()
            }
        }
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
    }

    private func hideOnMainThread() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> PromptPanel {
        let content = NSHostingView(rootView:
            Text("Monkey's Paw: nothing here yet")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor)))
        // Placement owns the frame; the hosting view must not propose its own size.
        content.sizingOptions = []

        let panel = PromptPanel(content: content)
        panel.onCancel = { [weak self] in self?.hide() }
        return panel
    }
}
