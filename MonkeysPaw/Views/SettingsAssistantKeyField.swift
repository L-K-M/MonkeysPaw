import AppKit
import SwiftUI

/// Only the native secure field owns typed text; published view state has none.
struct SettingsAssistantKeyField: NSViewRepresentable {
    let reset: UUID
    let isEditable: Bool
    let onInput: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(frame: .zero)
        field.placeholderString = SettingsAssistantStrings.keyPlaceholder
        field.setAccessibilityLabel(SettingsAssistantStrings.key)
        field.setAccessibilityIdentifier("settings-assistant-key")
        field.delegate = context.coordinator
        context.coordinator.update(field, reset: reset, isEditable: isEditable, onInput: onInput)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.update(field, reset: reset, isEditable: isEditable, onInput: onInput)
    }

    static func dismantleNSView(_ field: NSSecureTextField, coordinator: Coordinator) {
        coordinator.clear(field)
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var reset: UUID?
        private var isUpdating = false
        private var onInput: ((String) -> Void)?

        func update(_ field: NSSecureTextField, reset: UUID, isEditable: Bool,
                    onInput: @escaping (String) -> Void) {
            self.onInput = onInput
            field.isEnabled = isEditable
            guard self.reset != reset else { return }
            self.reset = reset
            clear(field)
        }

        func clear(_ field: NSSecureTextField) {
            // Do not forward resets as blank input: that would undo staged Clear.
            isUpdating = true
            field.stringValue = ""
            field.currentEditor()?.string = ""
            isUpdating = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSSecureTextField,
                  field.isEnabled else { return }
            onInput?(field.stringValue)
        }
    }
}
