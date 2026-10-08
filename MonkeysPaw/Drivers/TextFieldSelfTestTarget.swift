import AppKit
import MonkeysPawCore

final class TextFieldSelfTestTarget: SelfTestTarget {
    private var window: NSWindow?
    private var field: NSTextField?

    func present(fieldExpecting text: String) {
        let window = self.window ?? makeWindow()
        self.window = window
        // Never prefill the expected string: only an actual paste can pass the test.
        field?.stringValue = ""
        window.center()
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
        if let field {
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    func readBack() -> String? {
        // The field editor may still own uncommitted text when the timer fires.
        field?.currentEditor()?.string ?? field?.stringValue
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        let size = Limits.selfTestWindowSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Strings.selfTestWindowTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                     .fullScreenAuxiliary, .transient]

        let field = NSTextField(string: "")
        field.placeholderString = Strings.selfTestPlaceholder
        field.setAccessibilityLabel(Strings.selfTestPlaceholder)
        field.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        self.field = field
        return window
    }
}
