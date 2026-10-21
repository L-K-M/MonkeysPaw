import AppKit
import MonkeysPawCore
import SwiftUI

/// Focus is requested only on a model focus change or panel presentation, so
/// preview/value updates cannot steal a click on another control or button.
final class PickerFocusRequest {
    private weak var view: NSView?
    private var wantsFocus = false
    private var revision: UInt64?
    private var pending = false
    private var isActive = true
    private var keyObserver: NSObjectProtocol?

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// Root replacement can retain old representables until SwiftUI updates.
    /// Revoke their queued focus work before the reused window shows again.
    func deactivate() {
        isActive = false
        pending = false
        view = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    func update(view: NSView, wantsFocus: Bool, revision: UInt64) {
        guard isActive else { return }
        self.view = view
        if wantsFocus && (!self.wantsFocus || self.revision != revision) { pending = true }
        if !wantsFocus { pending = false }
        self.wantsFocus = wantsFocus
        self.revision = revision
        schedule()
    }

    func attached(_ view: NSView) {
        guard isActive else { return }
        self.view = view
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window = view.window else {
            pending = false
            return
        }
        // Native activation can settle after the deferred request. Retain
        // that pending request until this window actually becomes key.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.schedule() }
        schedule()
    }

    private func schedule() {
        guard pending else { return }
        // A representable can update before it is attached or before makeKey.
        // The controller's didShow revision retries after native presentation.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pending, let view = self.view,
                  let window = view.window, window.isVisible, window.isKeyWindow else { return }
            self.pending = false
            window.makeFirstResponder(view)
        }
    }
}

final class PickerTextField: NSTextField {
    let pickerFocus = PickerFocusRequest()
    var fieldKind: FieldKind?
    var onFocus: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pickerFocus.attached(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

struct PickerTextInput: NSViewRepresentable {
    let value: String
    let label: String
    let identifier: String
    var kind: FieldKind? = .text
    let wantsFocus: Bool
    let focusRevision: UInt64
    let onChange: (String) -> Void
    var onFocus: () -> Void = {}
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var isBezeled = true

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> PickerTextField {
        let field = PickerTextField(string: value)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: PickerTextField, context: Context) {
        context.coordinator.onChange = onChange
        if field.stringValue != value { field.stringValue = value }
        field.fieldKind = kind
        field.isEnabled = context.environment.isEnabled
        field.onFocus = onFocus
        if field.font != font { field.font = font }
        if field.isBezeled != isBezeled || (!isBezeled && field.isBordered) {
            field.isBordered = false
            field.isBezeled = isBezeled
        }
        field.drawsBackground = isBezeled
        field.focusRingType = isBezeled ? .exterior : .none
        field.placeholderString = label
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityLabel(label)
        field.pickerFocus.update(view: field, wantsFocus: wantsFocus, revision: focusRevision)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? PickerTextField)?.onFocus?()
        }
    }
}

final class PickerMultilineTextView: NSTextView {
    let pickerFocus = PickerFocusRequest()
    var onFocus: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pickerFocus.attached(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

struct PickerMultilineInput: NSViewRepresentable {
    let value: String
    let label: String
    let identifier: String
    let wantsFocus: Bool
    let focusRevision: UInt64
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = PickerMultilineTextView(frame: .zero)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        text.allowsUndo = true
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? PickerMultilineTextView else { return }
        context.coordinator.onChange = onChange
        if text.string != value { text.string = value }
        text.isEditable = context.environment.isEnabled
        text.onFocus = onFocus
        text.identifier = NSUserInterfaceItemIdentifier(identifier)
        text.setAccessibilityLabel(label)
        text.pickerFocus.update(view: text, wantsFocus: wantsFocus, revision: focusRevision)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            onChange(text.string)
        }
    }
}

final class PickerChoiceButton: NSPopUpButton {
    let pickerFocus = PickerFocusRequest()
    var onFocus: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pickerFocus.attached(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct PickerChoiceInput: NSViewRepresentable {
    let value: String
    let options: [FieldOption]
    let label: String
    let identifier: String
    let wantsFocus: Bool
    let focusRevision: UInt64
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> PickerChoiceButton {
        let button = PickerChoiceButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.focusRingType = .exterior
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: PickerChoiceButton, context: Context) {
        context.coordinator.onChange = onChange
        // Labels and values can differ. Preserve an obsolete remembered value
        // in Core; an unselected menu never silently supplies its first option.
        if context.coordinator.options != options {
            context.coordinator.options = options
            button.removeAllItems()
            let empty = NSMenuItem(title: Strings.chooseValue, action: nil, keyEquivalent: "")
            empty.representedObject = ""
            button.menu?.addItem(empty)
            for entry in options {
                let item = NSMenuItem(title: entry.label, action: nil, keyEquivalent: "")
                item.representedObject = entry.value
                button.menu?.addItem(item)
            }
        }
        if value.isEmpty {
            button.selectItem(at: 0)
        } else if let position = options.firstIndex(where: { $0.value == value }) {
            button.selectItem(at: position + 1)
        } else {
            button.select(nil)
        }
        button.onFocus = onFocus
        button.isEnabled = context.environment.isEnabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.pickerFocus.update(view: button, wantsFocus: wantsFocus, revision: focusRevision)
    }

    final class Coordinator: NSObject {
        var onChange: (String) -> Void
        var options: [FieldOption]?
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            onChange(value)
        }
    }
}

/// Native labels also expose descriptions to VoiceOver below each control.
struct PickerFieldDescription: NSViewRepresentable {
    let text: String
    let name: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = text
        label.identifier = NSUserInterfaceItemIdentifier("fill-description-" + name)
        label.setAccessibilityLabel(text)
    }
}
