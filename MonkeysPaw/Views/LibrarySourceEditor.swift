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
        text.onSourceChange = { [weak coordinator, weak text] in
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
        text.onSourceChange = nil
        coordinator.deactivate()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var onEdit: (String) -> Void
        private var path: RelativePath?
        private var revision: UInt64 = 0
        private var isActive = true
        private var isUpdating = false
        private let undo = UndoManager()

        init(onEdit: @escaping (String) -> Void) { self.onEdit = onEdit }

        func update(_ text: NSTextView, source: String, path: RelativePath?, revision: UInt64 = 0,
                    isEditable: Bool, onEdit: @escaping (String) -> Void) {
            guard isActive else { return }
            let changedSession = self.path != path || self.revision != revision
            if changedSession {
                // Retire native input before assigning the new model callback.
                // unmarkText can publish synchronously through onSourceChange.
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
            defer { isUpdating = false }
            let selection = Self.selectionAfterReplacement(text.selectedRange(), from: text.string, to: source)
            if changedSession || !isEditable {
                text.string = source
                text.undoManager?.removeAllActions()
            } else {
                // Save normalization and favourites belong to this document's
                // undo history. Keep native undo ranges aligned with the rewrite.
                text.breakUndoCoalescing()
                let range = NSRange(location: 0, length: (text.string as NSString).length)
                let replaced = text.performValidatedReplacement(in: range, with: NSAttributedString(string: source))
                if !replaced {
                    // A view that no longer accepts edits must still display
                    // the authoritative model source rather than stale text.
                    text.string = source
                    text.undoManager?.removeAllActions()
                }
                text.breakUndoCoalescing()
            }
            text.setSelectedRange(changedSession ? NSRange(location: 0, length: 0)
                : selection)
        }

        /// Canonical saves can prepend an id/header. Keep a caret or selection
        /// in the unchanged body there, rather than moving it into the new YAML.
        private static func selectionAfterReplacement(_ selection: NSRange, from old: String, to new: String) -> NSRange {
            let before = Array(old.utf16)
            let after = Array(new.utf16)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
            if prefix > 0, prefix < before.count, isLowSurrogate(before[prefix]) { prefix -= 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix,
                  before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
            if suffix > 0, isLowSurrogate(before[before.count - suffix]) { suffix -= 1 }

            let oldEnd = before.count - suffix
            let newEnd = after.count - suffix
            func mapped(_ point: Int) -> Int {
                if point < prefix { return point }
                if point >= oldEnd { return newEnd + point - oldEnd }
                return min(point, newEnd)
            }
            let start = min(max(selection.location, 0), before.count)
            let end = start + min(max(selection.length, 0), before.count - start)
            let mappedStart = mapped(start)
            return NSRange(location: mappedStart, length: max(mapped(end) - mappedStart, 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            publish(text)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func publish(_ text: NSTextView) {
            // Track marked text as a draft too, so a mouse close or app quit
            // cannot bypass the discard guard. update never overwrites it.
            guard isActive, !isUpdating, text.isEditable else { return }
            onEdit(text.string)
        }

        func deactivate() {
            isActive = false
            onEdit = { _ in }
            undo.removeAllActions()
        }
    }
}

final class LibrarySourceTextView: NSTextView {
    var onSourceChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // Input methods need not finish a textDidChange series before quit or
        // navigation. The discard guard must already know about marked text.
        onSourceChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onSourceChange?()
    }
}
