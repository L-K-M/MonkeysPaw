import AppKit
import SwiftUI

private struct LibraryAssistantGenerationView: View {
    @ObservedObject var presentation: LibraryAssistantViewState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LibraryAssistantStrings.generationTitle).font(.title2)
                .padding(.horizontal, 12)
            LibraryAssistantView(presentation: presentation, purpose: .newPrompt)
            HStack {
                Spacer()
                Button(MainMenuStrings.close, action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(presentation.state.isAccepting)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 16)
        .accessibilityIdentifier("library-assistant-generation")
    }
}

extension LibraryWindowController {
    /// The normal dialog coordinator suspends this sheet for editor guards,
    /// then remounts the same Assistant session with its candidate intact.
    static func presentPromptGeneration(in window: NSWindow, assistant: LibraryAssistantViewState,
                                        done: @escaping (LibraryEditorResponse) -> Void) -> (() -> Void) {
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = LibraryAssistantStrings.generationTitle
        sheet.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: LibraryAssistantGenerationView(presentation: assistant) { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet, returnCode: .cancel)
        })
        host.sizingOptions = []
        sheet.contentViewController = host
        sheet.setContentSize(NSSize(width: 640, height: 600))
        sheet.contentMinSize = NSSize(width: 480, height: 360)
        window.beginSheet(sheet) { [weak sheet] _ in
            sheet?.orderOut(nil)
            done(.dismissPromptGeneration)
        }
        return {
            guard sheet.sheetParent === window else { return }
            window.endSheet(sheet, returnCode: .cancel)
        }
    }
}
