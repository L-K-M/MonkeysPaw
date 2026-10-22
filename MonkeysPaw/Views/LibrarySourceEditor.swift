import AppKit
import MonkeysPawCore
import SwiftUI

struct LibrarySourceHighlight {
    let byteRange: Range<Int>
    let sourceBytes: Data
    let id = UUID()
}

/// NSTextView supplies undo, the editing responder chain and input methods.
/// SwiftUI publications must never replace an active marked-text composition.
struct LibrarySourceEditor: NSViewRepresentable {
    let source: String
    let path: RelativePath?
    let revision: UInt64
    let isEditable: Bool
    let onEdit: (String) -> Void
    var highlight: LibrarySourceHighlight? = nil
    var focusRevision: UInt64 = 0
    var isVisible = true

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView(coordinator: context.coordinator)
        Self.updateVisibility(isVisible, in: scroll)
        if let text = scroll.documentView as? LibrarySourceTextView {
            context.coordinator.update(text, source: source, path: path, revision: revision,
                isEditable: isEditable, onEdit: onEdit, highlight: highlight, focusRevision: focusRevision)
        }
        return scroll
    }

    /// Hosted tests exercise these same native controls without relying on
    /// SwiftUI's lazy view or accessibility trees.
    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let text = LibrarySourceTextView(frame: .zero)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
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
        text.onAttachedToWindow = { [weak coordinator, weak text] in
            guard let text else { return }
            coordinator?.applyPendingFocus(to: text)
        }
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        Self.updateVisibility(isVisible, in: scroll)
        guard let text = scroll.documentView as? LibrarySourceTextView else { return }
        context.coordinator.update(text, source: source, path: path, revision: revision,
            isEditable: isEditable, onEdit: onEdit, highlight: highlight, focusRevision: focusRevision)
    }

    static func updateVisibility(_ visible: Bool, in scroll: NSScrollView) {
        scroll.isHidden = !visible
        guard !visible, let text = scroll.documentView as? LibrarySourceTextView,
              let window = text.window, window.firstResponder === text else { return }
        window.makeFirstResponder(nil)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let text = scroll.documentView as? LibrarySourceTextView else { return }
        text.delegate = nil
        text.onSourceChange = nil
        text.onAttachedToWindow = nil
        coordinator.deactivate()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var onEdit: (String) -> Void
        private var path: RelativePath?
        private var revision: UInt64 = 0
        private var isActive = true
        private var isUpdating = false
        private var highlightID: UUID?
        private var appliedFocusRevision: UInt64 = 0
        private var requestedFocusRevision: UInt64 = 0
        private weak var textView: NSTextView?
        private let undo = UndoManager()

        init(onEdit: @escaping (String) -> Void) {
            self.onEdit = onEdit
            super.init()
            // Native undo/redo can replace text without textDidChange. Publish
            // the completed operation synchronously from this view's manager.
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoDidChange(_:)),
                name: .NSUndoManagerDidUndoChange, object: undo)
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedoDidChange(_:)),
                name: .NSUndoManagerDidRedoChange, object: undo)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func update(_ text: NSTextView, source: String, path: RelativePath?, revision: UInt64 = 0,
                    isEditable: Bool, onEdit: @escaping (String) -> Void,
                    highlight: LibrarySourceHighlight? = nil, focusRevision: UInt64 = 0) {
            guard isActive else { return }
            requestedFocusRevision = focusRevision
            textView = text
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
            applyPendingFocus(to: text)
            guard changedSession || !text.string.utf8.elementsEqual(source.utf8) else {
                updateHighlight(text, highlight: highlight)
                updateSyntaxColors(text)
                return
            }
            updateHighlight(text, highlight: nil)
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
            highlightID = nil
            updateHighlight(text, highlight: highlight)
            updateSyntaxColors(text)
        }

        func applyPendingFocus(to text: NSTextView) {
            guard isActive, requestedFocusRevision != 0, requestedFocusRevision != appliedFocusRevision,
                  !text.hasMarkedText(), let window = text.window, window.makeFirstResponder(text) else { return }
            appliedFocusRevision = requestedFocusRevision
        }

        private func updateHighlight(_ text: NSTextView, highlight: LibrarySourceHighlight?) {
            guard highlightID != highlight?.id else { return }
            let fullRange = NSRange(location: 0, length: (text.string as NSString).length)
            text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            highlightID = nil
            guard let highlight, highlight.sourceBytes == Data(text.string.utf8),
                  let range = Self.utf16Range(for: highlight.byteRange, in: text.string) else { return }
            highlightID = highlight.id
            // Temporary layout attributes never enter the source or undo stack.
            text.layoutManager?.addTemporaryAttribute(.backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: range)
            text.setSelectedRange(range)
            text.scrollRangeToVisible(range)
        }

        /// Syntax colors live only in temporary layout attributes, like the
        /// quote background: they never touch storage, undo or marked text.
        private func updateSyntaxColors(_ text: NSTextView) {
            guard let layout = text.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (text.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            let bytes = Array(text.string.utf8)
            var previousByteEnd = 0
            var previousUTF16End = 0
            // Ranges are ordered and disjoint. Convert each gap/span once so
            // a template with many placeholders still takes one linear pass.
            for (range, color) in Self.syntaxColorRanges(in: text.string) {
                let gap = String(decoding: bytes[previousByteEnd..<range.lowerBound], as: UTF8.self)
                let span = String(decoding: bytes[range], as: UTF8.self)
                let converted = NSRange(location: previousUTF16End + gap.utf16.count, length: span.utf16.count)
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: converted)
                previousByteEnd = range.upperBound
                previousUTF16End = NSMaxRange(converted)
            }
        }

        /// Byte ranges matching what Core parses: the closed `---` opening
        /// block of PromptCodec.split is front matter, and `{{name}}` spans
        /// in the body are placeholders under Template.parse rules.
        static func syntaxColorRanges(in source: String) -> [(range: Range<Int>, color: NSColor)] {
            let bytes = Array(source.utf8)
            var ranges = [(range: Range<Int>, color: NSColor)]()

            func line(at start: Int) -> (contentEnd: Int, next: Int) {
                var end = start
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                let contentEnd = end < bytes.count && end > start && bytes[end - 1] == 13 ? end - 1 : end
                return (contentEnd, end < bytes.count ? end + 1 : end)
            }
            func isDelimiter(_ range: Range<Int>) -> Bool {
                bytes[range].elementsEqual([45, 45, 45])
            }

            var bodyStart = 0
            let first = line(at: 0)
            if isDelimiter(0..<first.contentEnd) {
                // Unclosed front matter still leaves the lines below to the body.
                bodyStart = first.next
                var start = first.next
                while start < bytes.count {
                    let current = line(at: start)
                    guard isDelimiter(start..<current.contentEnd) else {
                        start = current.next
                        continue
                    }
                    ranges.append((0..<current.next, .secondaryLabelColor))
                    bodyStart = current.next
                    break
                }
            }

            var position = bodyStart
            while position < bytes.count {
                if bytes[position] == 92, position + 2 < bytes.count,
                   bytes[position + 1] == 123, bytes[position + 2] == 123 {
                    position += 3
                    continue
                }
                guard bytes[position] == 123, position + 1 < bytes.count, bytes[position + 1] == 123 else {
                    position += 1
                    continue
                }
                var end = position + 2
                while end + 1 < bytes.count, !(bytes[end] == 125 && bytes[end + 1] == 125) { end += 1 }
                guard end + 1 < bytes.count else { break }
                var nameStart = position + 2
                var nameEnd = end
                while nameStart < nameEnd, bytes[nameStart] == 32 || bytes[nameStart] == 9 { nameStart += 1 }
                while nameEnd > nameStart, bytes[nameEnd - 1] == 32 || bytes[nameEnd - 1] == 9 { nameEnd -= 1 }
                if isPlaceholderName(bytes[nameStart..<nameEnd]) {
                    ranges.append((position..<(end + 2), .controlAccentColor))
                }
                position = end + 2
            }
            return ranges
        }

        private static func isPlaceholderName(_ bytes: ArraySlice<UInt8>) -> Bool {
            func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
            guard let first = bytes.first, isLetter(first) || first == 95 else { return false }
            return bytes.dropFirst().allSatisfy {
                isLetter($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
            }
        }

        static func utf16Range(for byteRange: Range<Int>, in source: String) -> NSRange? {
            let bytes = Array(source.utf8)
            guard byteRange.lowerBound >= 0, byteRange.upperBound <= bytes.count, !byteRange.isEmpty,
                  let prefix = String(bytes: bytes[..<byteRange.lowerBound], encoding: .utf8),
                  let quote = String(bytes: bytes[byteRange], encoding: .utf8) else { return nil }
            return NSRange(location: prefix.utf16.count, length: quote.utf16.count)
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

        @objc private func undoOrRedoDidChange(_ notification: Notification) {
            guard let textView else { return }
            publish(textView)
        }

        func publish(_ text: NSTextView) {
            // Track marked text as a draft too, so a mouse close or app quit
            // cannot bypass the discard guard. update never overwrites it.
            guard isActive, !isUpdating, text.isEditable else { return }
            updateHighlight(text, highlight: nil)
            updateSyntaxColors(text)
            onEdit(text.string)
        }

        func deactivate() {
            if let textView { updateHighlight(textView, highlight: nil) }
            isActive = false
            onEdit = { _ in }
            NotificationCenter.default.removeObserver(self)
            textView = nil
            undo.removeAllActions()
        }
    }
}

final class LibrarySourceTextView: NSTextView {
    var onSourceChange: (() -> Void)?
    var onAttachedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A newly mounted Edit pane receives focus only after AppKit attaches it.
        if window != nil { onAttachedToWindow?() }
    }

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
