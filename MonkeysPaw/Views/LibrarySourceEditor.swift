import AppKit
import MonkeysPawCore
import SwiftUI

/// NSTextView supplies undo, the editing responder chain and input methods.
/// SwiftUI publications must never replace an active marked-text composition.
struct LibrarySourceEditor: NSViewRepresentable {
    let source: String
    let path: RelativePath?
    let revision: UInt64
    let isEditable: Bool
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView(coordinator: context.coordinator)
        if let text = scroll.documentView as? LibrarySourceTextView {
            context.coordinator.update(text, source: source, path: path, revision: revision,
                isEditable: isEditable, onEdit: onEdit)
        }
        return scroll
    }

    /// Hosted tests exercise these same native controls without relying on
    /// SwiftUI's lazy view or accessibility trees.
    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        let text = LibrarySourceTextView(frame: .zero)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(EditorStrings.source)
        text.setAccessibilityIdentifier("library-source")
        text.delegate = coordinator
        text.onCommit = { [weak coordinator, weak text] in
            guard let text else { return }
            coordinator?.publish(text)
        }
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? LibrarySourceTextView else { return }
        context.coordinator.update(text, source: source, path: path, revision: revision,
            isEditable: isEditable, onEdit: onEdit)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let text = scroll.documentView as? LibrarySourceTextView else { return }
        text.delegate = nil
        text.onCommit = nil
        coordinator.deactivate()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var onEdit: (String) -> Void
        private var path: RelativePath?
        private var revision: UInt64 = 0
        private var isActive = true
        private var isUpdating = false

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func update(_ text: NSTextView, source: String, path: RelativePath?, revision: UInt64 = 0,
                    isEditable: Bool, onEdit: @escaping (String) -> Void) {
            guard isActive else { return }
            let changedSession = self.path != path || self.revision != revision
            if changedSession {
                // Retire native input before assigning the new model callback.
                // unmarkText can publish synchronously through onCommit.
                isUpdating = true
                text.inputContext?.discardMarkedText()
                text.unmarkText()
                isUpdating = false
            }
            self.onEdit = onEdit
            text.isEditable = isEditable
            text.isSelectable = true
            guard !text.hasMarkedText() else { return }
            self.path = path
            self.revision = revision
            guard changedSession || !text.string.utf8.elementsEqual(source.utf8) else { return }
            isUpdating = true
            let selection = text.selectedRange()
            text.string = source
            text.undoManager?.removeAllActions()
            let length = (source as NSString).length
            text.setSelectedRange(changedSession ? NSRange(location: 0, length: 0)
                : NSRange(location: min(selection.location, length), length: 0))
            isUpdating = false
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            publish(text)
        }

        func publish(_ text: NSTextView) {
            // Track marked text as a draft too, so a mouse close or app quit
            // cannot bypass the discard guard. update never overwrites it.
            guard isActive, !isUpdating, text.isEditable else { return }
            onEdit(text.string)
        }

        func deactivate() { isActive = false; onEdit = { _ in } }
    }
}

final class LibrarySourceTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func unmarkText() {
        super.unmarkText()
        onCommit?()
    }
}
