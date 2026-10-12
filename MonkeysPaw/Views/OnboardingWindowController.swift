import AppKit
import MonkeysPawCore
import SwiftUI

/// Reuses the Settings chooser and Setup's accessory policy; views forward intents.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let presentation: OnboardingViewState
    private(set) var window: NSWindow?
    var onStateChange: (() -> Void)?
    private let mainThread: MainThread
    private let activateApplication: () -> Void
    private let folderChooser: SettingsWindowController.FolderChooser
    private var chooserRequest: UUID?
    private var cancelChooser: (() -> Void)?

    init(model: OnboardingModel, activeLibraryPath: String, defaultLibraryPath: String,
         mainThread: MainThread, activateApplication: @escaping () -> Void,
         folderChooser: @escaping SettingsWindowController.FolderChooser,
         openSettings: @escaping () -> Void) {
        presentation = OnboardingViewState(model: model, activeLibraryPath: activeLibraryPath,
            defaultLibraryPath: defaultLibraryPath, mainThread: mainThread, openSettings: openSettings)
        self.mainThread = mainThread
        self.activateApplication = activateApplication
        self.folderChooser = folderChooser
        super.init()
        presentation.onChooseFolder = { [weak self] in self?.chooseFolder() }
        presentation.onClose = { [weak self] in self?.window?.close() }
        presentation.onChange = { [weak self] in
            guard let self else { return }
            if self.presentation.state.step != .libraryFolder
                || self.presentation.state.libraryStatus == .lostWhileRunning
                || self.presentation.state.isReadOnly { self.endChooser() }
            if self.presentation.state.isReadOnly { self.window?.close() }
            self.onStateChange?()
        }
    }

    deinit { cancelChooser?() }

    func show() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.presentation.model.refresh()
            guard !self.presentation.state.isReadOnly, self.presentation.state.step != .setup else { return }
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
            // Like Setup, onboarding does not request a Dock icon. Only Settings
            // and Library participate in the shared regular-window policy.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            self.activateApplication()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func updateLibraryPaths(active: String, default defaultPath: String) {
        presentation.updateLibraryPaths(active: active, default: defaultPath)
    }

    func windowWillClose(_ notification: Notification) { endChooser() }

    private func endChooser() {
        // Revoke before cancellation: an injected or native sheet may reply inline.
        chooserRequest = nil
        let cancel = cancelChooser
        cancelChooser = nil
        presentation.isChoosingFolder = false
        cancel?()
    }

    private func chooseFolder() {
        mainThread.run { [weak self] in
            guard let self, let window = self.window, window.isVisible,
                  self.presentation.canChooseFolder, self.chooserRequest == nil else { return }
            let request = UUID()
            self.chooserRequest = request
            self.presentation.isChoosingFolder = true
            let cancel = self.folderChooser(window) { [weak self] url in
                self?.mainThread.run { [weak self] in
                    guard let self, self.chooserRequest == request else { return }
                    self.chooserRequest = nil
                    self.cancelChooser = nil
                    self.presentation.isChoosingFolder = false
                    guard self.window?.isVisible == true, self.presentation.canChooseFolder, let url else { return }
                    self.presentation.model.chooseFolder(url.path)
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
        window.title = Strings.onboardingTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let content = NSHostingView(rootView: OnboardingView(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}
