import AppKit
import MonkeysPawCore
import SwiftUI

/// Owns the native window and chooser; the SwiftUI view sees presentation only.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    typealias FolderChooser = (NSWindow, @escaping (URL?) -> Void) -> (() -> Void)
    enum ForgetAllResponse { case confirmed, cancelled }
    typealias ForgetAllConfirmation = (NSWindow, @escaping (ForgetAllResponse) -> Void) -> (() -> Void)

    let presentation: SettingsViewState
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activation: WindowActivationCoordinator
    private let folderChooser: FolderChooser
    private let forgetAllConfirmation: ForgetAllConfirmation
    private let makeAssistant: () -> AssistantSettingsModel
    private let onProviderChange: () -> Void
    private var chooserRequest: UUID?
    private var cancelChooser: (() -> Void)?
    private var confirmationRequest: UUID?
    private var cancelConfirmation: (() -> Void)?
    private var isTornDown = false
    private var visibilityObservers: [NSObjectProtocol] = []
    private var isClosing = false

    init(general: GeneralSettingsModel, shortcuts: ShortcutsSettingsModel,
         rememberedValues: RememberedValuesSettingsModel,
         delivery: DeliverySettingsModel, updates: UpdateSettingsModel,
         forgetAllConfirmation: @escaping ForgetAllConfirmation,
         mainThread: MainThread, activation: WindowActivationCoordinator,
         folderChooser: @escaping FolderChooser, openSetup: @escaping () -> Void,
         makeAssistant: @escaping () -> AssistantSettingsModel,
         onProviderChange: @escaping () -> Void = {},
         makeAccount: @escaping () -> AccountModel? = { nil }, onAccountOpen: @escaping () -> Void = {},
         makeInvite: @escaping () -> InviteModel? = { nil }) {
        presentation = SettingsViewState(general: general, shortcuts: shortcuts,
                                         rememberedValues: rememberedValues,
                                         delivery: delivery, updates: updates,
                                         mainThread: mainThread, openSetup: openSetup,
                                         makeAccount: makeAccount, onAccountOpen: onAccountOpen,
                                         makeInvite: makeInvite)
        self.mainThread = mainThread
        self.activation = activation
        self.folderChooser = folderChooser
        self.forgetAllConfirmation = forgetAllConfirmation
        self.makeAssistant = makeAssistant
        self.onProviderChange = onProviderChange
        super.init()
        presentation.onChooseFolder = { [weak self] in self?.chooseFolder() }
        presentation.onRememberedValuesChange = { [weak self] in self?.updateForgetAllConfirmation() }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshAccountVisibility()
            })
        }
    }

    deinit {
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        let cancel = cancelConfirmation
        let cancelChooser = self.cancelChooser
        let window = self.window
        let presentation = self.presentation
        mainThread.run {
            cancel?()
            cancelChooser?()
            presentation.cancelForgetAll()
            // Retire without publishing a tab removal from deinit.
            presentation.assistant?.retire()
            presentation.delivery.retire()
            presentation.updates.retire()
            presentation.windowHidden()
            window?.delegate = nil
            window?.close()
        }
    }

    func tearDown() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.isTornDown = true
            self.cancelPendingPanels()
            self.presentation.retireAssistant()
            self.presentation.delivery.retire()
            self.presentation.updates.retire()
            self.presentation.windowHidden()
            self.window?.delegate = nil
            // willClose also stops both shortcut recorders' native monitors.
            self.window?.close()
            self.window = nil
        }
    }

    func show() {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown else { return }
            if self.presentation.assistant == nil {
                self.presentation.openAssistant(self.makeAssistant(), mainThread: self.mainThread,
                    onProviderChange: self.onProviderChange)
            }
            self.presentation.refresh()
            self.presentation.delivery.show()
            self.presentation.updates.show()
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
            self.isClosing = false
            self.activation.show(window)
            self.refreshAccountVisibility()
        }
    }

    func showAccount() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.presentation.selectedTab = .account
            self.show()
        }
    }

    func openInvite(_ supplied: inout String) {
        let link = SecretValue(supplied)
        supplied = ""
        mainThread.run { [weak self] in
            guard let self else { return }
            self.showAccount()
            var input = link.withValue { $0 }
            self.presentation.account.invites.stage(&input)
        }
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        presentation.windowHidden()
        cancelPendingPanels()
        presentation.delivery.hide()
        presentation.updates.hide()
    }

    private func cancelPendingPanels() {
        // Invalidate before cancelling: the native panel may complete inline.
        chooserRequest = nil
        let cancel = cancelChooser
        cancelChooser = nil
        presentation.isChoosingFolder = false
        cancel?()
        endForgetAllConfirmation()
        presentation.cancelForgetAll()
        // The native window is retained for reopening, along with its draft.
        presentation.assistant?.cancelTest()
    }

    func windowDidMiniaturize(_ notification: Notification) { presentation.windowHidden() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshAccountVisibility() }
    func windowDidBecomeKey(_ notification: Notification) { refreshAccountVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { refreshAccountVisibility() }

    private func refreshAccountVisibility() {
        mainThread.run { [weak self] in
            guard let self else { return }
            if !self.isTornDown, !self.isClosing, !NSApp.isHidden, let window = self.window,
               window.isVisible, !window.isMiniaturized {
                self.presentation.windowShown()
            } else { self.presentation.windowHidden() }
        }
    }

    private func updateForgetAllConfirmation() {
        mainThread.run { [weak self] in
            guard let self else { return }
            guard self.presentation.rememberedValues.confirmation == .forgetAll else {
                self.endForgetAllConfirmation()
                return
            }
            guard let window = self.window, window.isVisible else {
                self.presentation.cancelForgetAll()
                return
            }
            guard self.confirmationRequest == nil else { return }

            let request = UUID()
            self.confirmationRequest = request
            let cancel = self.forgetAllConfirmation(window) { [weak self] response in
                self?.mainThread.run { [weak self] in
                    guard let self, self.confirmationRequest == request else { return }
                    self.confirmationRequest = nil
                    self.cancelConfirmation = nil
                    guard self.window?.isVisible == true else {
                        self.presentation.cancelForgetAll()
                        return
                    }
                    switch response {
                    case .confirmed: self.presentation.confirmForgetAll()
                    case .cancelled: self.presentation.cancelForgetAll()
                    }
                }
            }
            // Test confirmations can respond inline, as the folder chooser can.
            if self.confirmationRequest == request { self.cancelConfirmation = cancel }
        }
    }

    private func endForgetAllConfirmation() {
        // Revoke the response before ending the sheet, which may complete inline.
        confirmationRequest = nil
        let cancel = cancelConfirmation
        cancelConfirmation = nil
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
                    guard let self, self.chooserRequest == request else { return }
                    self.chooserRequest = nil
                    self.cancelChooser = nil
                    self.presentation.isChoosingFolder = false
                    // A hidden (for example minimized) window still ends the
                    // request so Choose works again, but applies no late result.
                    guard self.window?.isVisible == true, let url else { return }
                    self.presentation.generalModel.chooseFolder(url.path)
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

    static func confirmForgetAll(in window: NSWindow, done: @escaping (ForgetAllResponse) -> Void) -> (() -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RememberedValuesStrings.confirmationTitle
        alert.informativeText = RememberedValuesStrings.confirmationMessage
        let forget = alert.addButton(withTitle: RememberedValuesStrings.forgetAll)
        forget.hasDestructiveAction = true
        forget.setAccessibilityLabel(RememberedValuesStrings.forgetAll)
        let cancel = alert.addButton(withTitle: RememberedValuesStrings.cancel)
        cancel.setAccessibilityLabel(RememberedValuesStrings.cancel)
        alert.beginSheetModal(for: window) { response in
            done(response == .alertFirstButtonReturn ? .confirmed : .cancelled)
        }
        return {
            guard alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
    }
}
