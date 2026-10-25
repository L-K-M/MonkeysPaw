import AppKit
import Combine
import MonkeysPawCore
import SwiftUI

/// The inspector starts improvements; this window owns their readable preview.
final class LibraryAssistantWindowController: NSWindowController, NSWindowDelegate {
    let presentation: LibraryAssistantViewState
    var onClose: (() -> Void)?
    private let activation: WindowActivationCoordinator
    private let mainThread: MainThread
    private var presentationObservation: AnyCancellable?
    private var presentationUpdatePending = false

    init(presentation: LibraryAssistantViewState, promptTitle: String,
         activation: WindowActivationCoordinator, mainThread: MainThread) {
        self.presentation = presentation
        self.activation = activation
        self.mainThread = mainThread
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = LibraryAssistantStrings.improvementTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 640, height: 360)
        let host = NSHostingController(rootView: LibraryAssistantImprovementView(presentation: presentation, promptTitle: promptTitle))
        host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window)
        window.delegate = self
        window.center()
        presentationObservation = presentation.objectWillChange.sink { [weak self] _ in
            self?.schedulePresentationUpdate()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        if let window { activation.show(window) }
    }

    // Read the completed publication on the next turn; closing inline would
    // re-enter Core's publication loop through windowWillClose and cancel().
    private func schedulePresentationUpdate() {
        guard !presentationUpdatePending else { return }
        presentationUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.mainThread.run { [weak self] in
                guard let self else { return }
                self.presentationUpdatePending = false
                guard self.window?.isVisible == true, self.presentation.improvementStage == .ended else { return }
                self.close()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Acceptance may already be publishing; let its authoritative outcome finish.
        !presentation.state.isAccepting
    }

    func windowWillClose(_ notification: Notification) {
        presentationObservation = nil
        if presentation.isImprovementRequest { presentation.cancel() }
        onClose?()
    }
}
