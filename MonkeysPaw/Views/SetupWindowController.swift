import AppKit
import MonkeysPawCore
import SwiftUI

/// Owns the native window; SetupView receives only its presentation model.
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let presentation: SetupViewState
    private var window: NSWindow?
    var onClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init(model: SetupModel) {
        presentation = SetupViewState(model: model)
        super.init()
        // The Done control performs the same close as the title-bar button so
        // windowWillClose drives the existing onClose callback.
        presentation.requestClose = { [weak self] in self?.window?.performClose(nil) }
    }

    func tearDown() {
        // Closing for teardown must not advance the first-run flow.
        onClose = nil
        presentation.requestClose = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Let AppKit finish closing Setup before raising the next first-run step.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    func show() {
        presentation.model.refresh()
        let window = self.window ?? makeWindow()
        self.window = window
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
    }

    private func makeWindow() -> NSWindow {
        let size = Limits.setupWindowSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Strings.setupTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let content = NSHostingView(rootView: SetupView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}
