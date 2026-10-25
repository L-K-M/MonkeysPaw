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

enum PickerControlStyle {
    case standard, night
    case paper(FieldProvenance, WishInkPhase)
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
    var resetRevision: UInt64 = 0
    var style: PickerControlStyle = .standard
    var fieldHelp: String? = nil

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
        context.coordinator.render(value, in: field, resetRevision: resetRevision)
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
        field.setAccessibilityHelp(fieldHelp)
        field.toolTip = fieldHelp
        if case .paper(let provenance, let phase) = style {
            field.font = WishCardStyle.fieldFont(provenance)
            field.textColor = WishCardStyle.ink(provenance, phase: phase)
            field.placeholderAttributedString = NSAttributedString(string: label,
                attributes: [.font: WishCardStyle.fieldFont(.defaultValue),
                             .foregroundColor: WishCardStyle.nsColor(0x857A97)])
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            if let editor = field.currentEditor() as? NSTextView {
                editor.font = field.font
                editor.textColor = field.textColor
                editor.insertionPointColor = WishCardStyle.nsColor(0xE58A22)
                editor.selectedTextAttributes = [.backgroundColor: WishCardStyle.nsColor(0xFFB547).withAlphaComponent(0.38)]
            }
        }
        if case .standard = style {
            field.textColor = .labelColor
            if let editor = field.currentEditor() as? NSTextView {
                editor.textColor = .labelColor
                editor.insertionPointColor = .labelColor
            }
        }
        if case .night = style {
            field.textColor = WishCardStyle.nsColor(0xECE7F6)
            field.placeholderAttributedString = NSAttributedString(string: label,
                attributes: [.foregroundColor: WishCardStyle.nsColor(0x7E7699)])
            if let editor = field.currentEditor() as? NSTextView {
                editor.textColor = field.textColor
                editor.insertionPointColor = WishCardStyle.nsColor(0xFFB547)
            }
        }
        field.pickerFocus.update(view: field, wantsFocus: wantsFocus, revision: focusRevision)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        private var resetRevision: UInt64?
        private var isUpdating = false
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func render(_ value: String, in field: NSTextField, resetRevision: UInt64) {
            let reset = self.resetRevision != resetRevision
            self.resetRevision = resetRevision
            let editor = field.currentEditor() as? NSTextView
            guard reset || editor?.hasMarkedText() != true else { return }
            let nativeValue = editor?.string ?? field.stringValue
            guard reset || !nativeValue.utf8.elementsEqual(value.utf8) else { return }
            let selection = editor?.selectedRange()
            isUpdating = true
            defer { isUpdating = false }
            editor?.inputContext?.discardMarkedText()
            editor?.unmarkText()
            field.stringValue = value
            // The cell and its live field editor can hold different strings.
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = value
                editor.breakUndoCoalescing()
                editor.undoManager?.removeAllActions()
                if let selection {
                    let length = value.utf16.count
                    let location = min(selection.location, length)
                    editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let field = notification.object as? NSTextField else { return }
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
    var resetRevision: UInt64 = 0
    var style: PickerControlStyle = .standard
    var fieldHelp: String? = nil

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
        context.coordinator.render(value, in: text, resetRevision: resetRevision)
        text.isEditable = context.environment.isEnabled
        text.onFocus = onFocus
        text.identifier = NSUserInterfaceItemIdentifier(identifier)
        text.setAccessibilityLabel(label)
        text.setAccessibilityHelp(fieldHelp)
        text.toolTip = fieldHelp
        if case .paper(let provenance, let phase) = style {
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            text.drawsBackground = false
            text.focusRingType = .none
            text.font = WishCardStyle.fieldFont(provenance, kind: .multiline)
            text.textColor = WishCardStyle.ink(provenance, phase: phase)
            text.insertionPointColor = WishCardStyle.nsColor(0xE58A22)
            text.selectedTextAttributes = [.backgroundColor: WishCardStyle.nsColor(0xFFB547).withAlphaComponent(0.38)]
            text.textContainerInset = NSSize(width: 7, height: 7)
        }
        text.pickerFocus.update(view: text, wantsFocus: wantsFocus, revision: focusRevision)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        private var resetRevision: UInt64?
        private var isUpdating = false
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func render(_ value: String, in text: NSTextView, resetRevision: UInt64) {
            let reset = self.resetRevision != resetRevision
            self.resetRevision = resetRevision
            guard reset || !text.hasMarkedText() else { return }
            guard reset || !text.string.utf8.elementsEqual(value.utf8) else { return }
            let selection = text.selectedRange()
            isUpdating = true
            defer { isUpdating = false }
            text.inputContext?.discardMarkedText()
            text.unmarkText()
            text.string = value
            text.breakUndoCoalescing()
            text.undoManager?.removeAllActions()
            let length = value.utf16.count
            let location = min(selection.location, length)
            text.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let text = notification.object as? NSTextView else { return }
            onChange(text.string)
        }
    }
}

class PickerChoiceButton: NSPopUpButton {
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
