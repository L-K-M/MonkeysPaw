import AppKit
import SwiftUI

/// The inspector starts improvements; this window owns their readable preview.
final class LibraryAssistantWindowController: NSWindowController, NSWindowDelegate {
    let presentation: LibraryAssistantViewState
    var onClose: (() -> Void)?
    private let activation: WindowActivationCoordinator

    init(presentation: LibraryAssistantViewState, activation: WindowActivationCoordinator) {
        self.presentation = presentation
        self.activation = activation
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = LibraryAssistantStrings.improvementTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 640, height: 360)
        let host = NSHostingController(rootView: LibraryAssistantView(presentation: presentation, purpose: .improvement))
        host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        if let window { activation.show(window) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Acceptance may already be publishing; let its authoritative outcome finish.
        !presentation.state.isAccepting
    }

    func windowWillClose(_ notification: Notification) {
        presentation.cancel()
        onClose?()
    }
}
