import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI

final class LibraryWindowController: NSObject, NSWindowDelegate {
    let presentation: LibraryViewState
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private var keyMonitor: Any?
    private var isTornDown = false

    init(model: LibraryBrowserModel, libraryPath: String, available: Bool,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         now: @escaping () -> Date, timeZone: @escaping () -> TimeZone,
         revealLibrary: @escaping () -> Void) {
        self.mainThread = mainThread
        self.activation = activation
        presentation = LibraryViewState(model: model, libraryPath: libraryPath, available: available,
            mainThread: mainThread, now: now, timeZone: timeZone, revealLibrary: revealLibrary)
        super.init()
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func rebind(to model: LibraryBrowserModel, libraryPath: String, available: Bool) {
        guard !isTornDown else { return }
        presentation.rebind(to: model, libraryPath: libraryPath, available: available)
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
        }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        presentation.deactivate()
        removeKeyMonitor()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { removeKeyMonitor() }

    /// Explicit routing seam: hosted tests call this directly because sendEvent
    /// does not pass through local monitors or guarantee a regular key window.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !isTornDown, let window, window.isVisible, event.window === window else { return false }
        if let client = window.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            escape()
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
        window?.close()
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
        let content = NSHostingView(rootView: LibraryView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}

private final class LibraryWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
