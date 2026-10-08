import AppKit
import MonkeysPawCore
import SwiftUI

/// Owns the native window; SetupView receives only its presentation model.
final class SetupWindowController {
    private let presentation: SetupViewState
    private var window: NSWindow?

    init(model: SetupModel) {
        presentation = SetupViewState(model: model)
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
        let content = NSHostingView(rootView: SetupView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}
