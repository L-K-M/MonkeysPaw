import AppKit
import MonkeysPawCore
import SwiftUI

/// Owns the native window and chooser; the SwiftUI view sees presentation only.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    typealias FolderChooser = (NSWindow, @escaping (URL?) -> Void) -> (() -> Void)

    let presentation: SettingsViewState
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private let folderChooser: FolderChooser
    private var chooserRequest: UUID?
    private var cancelChooser: (() -> Void)?

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         folderChooser: @escaping FolderChooser, openSetup: @escaping () -> Void) {
        presentation = SettingsViewState(general: general, shortcuts: shortcuts,
                                         mainThread: mainThread, openSetup: openSetup)
        self.mainThread = mainThread
        self.activation = activation
        self.folderChooser = folderChooser
        super.init()
        presentation.onChooseFolder = { [weak self] in self?.chooseFolder() }
    }

    func show() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.presentation.refresh()
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
            self.activation.show(window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Invalidate before cancelling: the native panel may complete inline.
        chooserRequest = nil
        let cancel = cancelChooser
        cancelChooser = nil
        presentation.isChoosingFolder = false
        cancel?()
    }

    private func chooseFolder() {
        mainThread.run { [weak self] in
            guard let self, let window = self.window, window.isVisible, self.chooserRequest == nil else { return }
            let request = UUID()
            self.chooserRequest = request
            self.presentation.isChoosingFolder = true
            let cancel = self.folderChooser(window) { [weak self] url in
                self?.mainThread.run { [weak self] in
                    guard let self, self.chooserRequest == request, self.window?.isVisible == true else { return }
                    self.chooserRequest = nil
                    self.cancelChooser = nil
                    self.presentation.isChoosingFolder = false
                    if let url { self.presentation.generalModel.chooseFolder(url.path) }
                }
            }
            // Injected choosers may finish synchronously.
            if self.chooserRequest == request { self.cancelChooser = cancel }
        }
    }

    private func makeWindow() -> NSWindow {
        let size = Limits.setupWindowSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Strings.settingsTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let content = NSHostingView(rootView: SettingsView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }

    static func chooseFolder(in window: NSWindow, done: @escaping (URL?) -> Void) -> (() -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.url : nil) }
        return { panel.cancel(nil) }
    }
}
