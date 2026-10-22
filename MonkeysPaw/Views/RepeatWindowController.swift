import AppKit
import MonkeysPawCore
import SwiftUI

/// Refusals and review hints never open or reset the hidden picker draft.
final class RepeatWindowController {
    final class Presentation: ObservableObject {
        @Published private(set) var message = ""
        @Published private(set) var reference: RepeatPromptReference?
        private let openPrompt: (RepeatPromptReference) -> Void
        var dismiss: (() -> Void)?

        init(openPrompt: @escaping (RepeatPromptReference) -> Void) { self.openPrompt = openPrompt }

        func update(_ result: RepeatResult) {
            message = Strings.repeatMessage(result) ?? ""
            if case .reviewRequired(let reference, _) = result { self.reference = reference }
            else { reference = nil }
        }

        func reopen() {
            guard let reference else { return }
            dismiss?()
            openPrompt(reference)
        }
    }

    let presentation: Presentation
    private(set) var window: NSWindow?
    private let mainThread: MainThread
    private let activateApplication: () -> Void
    private var isTornDown = false

    init(mainThread: MainThread, activateApplication: @escaping () -> Void,
         openPrompt: @escaping (RepeatPromptReference) -> Void) {
        self.mainThread = mainThread
        self.activateApplication = activateApplication
        presentation = Presentation(openPrompt: openPrompt)
        presentation.dismiss = { [weak self] in self?.window?.close() }
    }

    func show(_ result: RepeatResult) {
        mainThread.run { [weak self] in
            guard let self, !self.isTornDown, Strings.repeatMessage(result) != nil else { return }
            self.presentation.update(result)
            let window = self.window ?? self.makeWindow()
            if self.window == nil { window.center() }
            self.window = window
            // Notices stay accessory, like Setup; Settings/Library own the Dock policy.
            window.orderFrontRegardless()
            self.activateApplication()
            window.makeKey()
        }
    }

    func tearDown() {
        isTornDown = true
        presentation.dismiss = nil
        window?.close()
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let size = Limits.panelSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Strings.repeatLast
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let content = NSHostingView(rootView: RepeatNotice(presentation: presentation))
        content.sizingOptions = []
        window.contentView = content
        return window
    }
}

private struct RepeatNotice: View {
    @ObservedObject var presentation: RepeatWindowController.Presentation

    var body: some View {
        WelcomeWindowView(title: Strings.repeatLast, explanation: WelcomeStrings.repeatExplanation) {
            WelcomeStatusRow(symbol: .needsAttention) {
                Text(presentation.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("repeat-message")
            }
        } secondaryActions: {
            openPromptButton
        } defaultAction: {
            doneButton
        }
    }

    @ViewBuilder private var openPromptButton: some View {
        if presentation.reference != nil {
            Button(Strings.openRepeatPrompt) { presentation.reopen() }
                .accessibilityIdentifier("repeat-open-prompt")
        }
    }

    private var doneButton: some View {
        Button(Strings.done) { presentation.dismiss?() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("repeat-done")
    }
}
