import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Hosted coverage for the native source editor's find bar, temporary syntax
/// colors and revision-driven focus. The real controls run without SwiftUI.
final class MacLibrarySourceAppearanceTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        super.tearDown()
    }

    private func makeEditor(onEdit: @escaping (String) -> Void = { _ in })
        throws -> (coordinator: LibrarySourceEditor.Coordinator, scroll: NSScrollView, text: LibrarySourceTextView) {
        let coordinator = LibrarySourceEditor.Coordinator(onEdit: onEdit)
        let scroll = LibrarySourceEditor.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LibrarySourceTextView)
        return (coordinator, scroll, text)
    }

    @discardableResult
    private func host(_ scroll: NSScrollView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        self.window = window
        return window
    }

    private func foreground(_ text: NSTextView, at index: Int, range: NSRangePointer? = nil) -> NSColor? {
        text.layoutManager?.temporaryAttribute(.foregroundColor,
            atCharacterIndex: index, effectiveRange: range) as? NSColor
    }

    func testFindBarIncrementalSearchAndBorderlessScroll() throws {
        let (coordinator, scroll, text) = try makeEditor()
        defer { coordinator.deactivate() }
        XCTAssertEqual(scroll.borderType, .noBorder)
        XCTAssertTrue(text.usesFindBar)
        XCTAssertTrue(text.isIncrementalSearchingEnabled)
    }

    func testFrontMatterAndPlaceholdersColorAsTemporaryAttributes() throws {
        let source = "---\ntitle: Note\n---\nBody {{tone}} and \\{{escaped}} {{9bad}} {{unclosed"
        let (coordinator, _, text) = try makeEditor()
        defer { coordinator.deactivate() }
        coordinator.update(text, source: source, path: "one.md", isEditable: true, onEdit: { _ in })
        let ns = source as NSString
        XCTAssertEqual(foreground(text, at: 0), .secondaryLabelColor)
        XCTAssertEqual(foreground(text, at: ns.range(of: "title").location), .secondaryLabelColor)
        XCTAssertEqual(foreground(text, at: ns.range(of: "---", options: .backwards).location),
            .secondaryLabelColor, "The closing delimiter belongs to the block")
        XCTAssertNil(foreground(text, at: ns.range(of: "Body").location))
        XCTAssertEqual(foreground(text, at: ns.range(of: "{{tone}}").location), .controlAccentColor)
        XCTAssertNil(foreground(text, at: ns.range(of: "{{escaped}}").location),
            "An escaped opener renders literally")
        XCTAssertNil(foreground(text, at: ns.range(of: "{{9bad}}").location),
            "An invalid name is not a placeholder")
        XCTAssertNil(foreground(text, at: ns.range(of: "{{unclosed").location))
    }

    func testFrontMatterKeepsSecondaryColorAndUnclosedBlocksUseBodyColors() throws {
        let (coordinator, _, text) = try makeEditor()
        defer { coordinator.deactivate() }
        let closed = "---\nyaml: {{inner}}\n---\n{{outer}}\n--- rule ---"
        coordinator.update(text, source: closed, path: "one.md", isEditable: true, onEdit: { _ in })
        let ns = closed as NSString
        XCTAssertEqual(foreground(text, at: ns.range(of: "{{inner}}").location), .secondaryLabelColor)
        XCTAssertEqual(foreground(text, at: ns.range(of: "{{outer}}").location), .controlAccentColor)
        XCTAssertNil(foreground(text, at: ns.range(of: "--- rule").location),
            "A --- line outside the first line is body text")
        // An unclosed opener leaves the lines below to the body, like Core.
        coordinator.update(text, source: "---\nyaml: {{inner}}", path: "one.md", revision: 1,
            isEditable: true, onEdit: { _ in })
        XCTAssertNil(foreground(text, at: 0), "An unclosed --- preamble is not a front matter block")
        XCTAssertEqual(foreground(text, at: ("---\nyaml: {{inner}}" as NSString).range(of: "{{inner}}").location),
            .controlAccentColor)
    }

    func testSyntaxColorRangesHonorUnicodeBoundaries() throws {
        let source = "---\ntitle: 😀 e\u{301}\n---\n😀 {{ok_1}}e\u{301}{{ name }} {{bad name}} end"
        let frontMatter = "---\ntitle: 😀 e\u{301}\n---\n"
        let ns = source as NSString
        let ranges = LibrarySourceEditor.Coordinator.syntaxColorRanges(in: source)
        XCTAssertEqual(ranges.map { $0.range },
            [0..<frontMatter.utf8.count, ns.range(of: "{{ok_1}}").toByteRange(in: source),
             ns.range(of: "{{ name }}").toByteRange(in: source)])
        XCTAssertEqual(ranges.map { $0.color }, [.secondaryLabelColor, .controlAccentColor, .controlAccentColor])

        let (coordinator, _, text) = try makeEditor()
        defer { coordinator.deactivate() }
        coordinator.update(text, source: source, path: "one.md", isEditable: true, onEdit: { _ in })
        var effective = NSRange()
        XCTAssertEqual(foreground(text, at: ns.range(of: "😀").location + 1, range: &effective),
            .secondaryLabelColor, "A surrogate-pair interior stays inside the front matter range")
        XCTAssertEqual(effective, ns.range(of: frontMatter))
        XCTAssertNil(foreground(text, at: ns.range(of: "{{ok_1}}").location - 1))
        XCTAssertEqual(foreground(text, at: ns.range(of: "ok_1").location, range: &effective),
            .controlAccentColor)
        XCTAssertEqual(effective, ns.range(of: "{{ok_1}}"))
        XCTAssertNil(foreground(text, at: NSMaxRange(ns.range(of: "{{ok_1}}"))),
            "The combining mark after a placeholder stays outside its range")
        XCTAssertEqual(foreground(text, at: ns.range(of: "name").location, range: &effective),
            .controlAccentColor, "Edge whitespace is still inside the placeholder span")
        XCTAssertEqual(effective, ns.range(of: "{{ name }}"))
        XCTAssertNil(foreground(text, at: ns.range(of: "bad name").location),
            "Interior whitespace invalidates the name")
    }

    func testEditsUndoRedoAndModelUpdatesRefreshColorsWithoutTouchingStorage() throws {
        var edits: [String] = []
        let (coordinator, scroll, text) = try makeEditor { edits.append($0) }
        let window = host(scroll)
        defer { scroll.removeFromSuperview(); coordinator.deactivate() }
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true, onEdit: { edits.append($0) })
        XCTAssertTrue(window.makeFirstResponder(text))
        let undo = try XCTUnwrap(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" {{tone}}", replacementRange: NSRange(location: 4, length: 0))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        let accent = ("Body {{tone}}" as NSString).range(of: "{{tone}}").location
        XCTAssertEqual(foreground(text, at: accent), .controlAccentColor)
        XCTAssertTrue(undo.canUndo)

        // A same-source render adds no storage attribute and no undo action.
        let canUndo = undo.canUndo
        coordinator.update(text, source: text.string, path: "one.md", isEditable: true, onEdit: { edits.append($0) })
        XCTAssertEqual(undo.canUndo, canUndo)
        let stored = text.textStorage?.attribute(.foregroundColor, at: accent, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(stored, .controlAccentColor)
        XCTAssertNotEqual(stored, .secondaryLabelColor)

        undo.undo()
        XCTAssertEqual(text.string, "Body")
        XCTAssertNil(foreground(text, at: 1), "Undo removes the placeholder and its temporary color")
        undo.redo()
        XCTAssertEqual(foreground(text, at: accent), .controlAccentColor)

        // Manual grouping is still on: a model rewrite registers its own undo step.
        undo.beginUndoGrouping()
        coordinator.update(text, source: "---\nk: v\n---\nPlain", path: "one.md",
            isEditable: true, onEdit: { edits.append($0) })
        undo.endUndoGrouping()
        XCTAssertEqual(foreground(text, at: 0), .secondaryLabelColor)
        XCTAssertEqual(foreground(text, at: accent), .secondaryLabelColor,
            "Model rewrites replace the whole temporary color map")
        XCTAssertNil(foreground(text, at: ("---\nk: v\n---\nPlain" as NSString).range(of: "Plain").location))
        XCTAssertTrue(edits.contains("Body"))
    }

    func testQuoteBackgroundStaysIndependentOfSyntaxColors() throws {
        let source = "See {{tone}} now"
        let byteStart = Data(source.utf8).count - 3
        let (coordinator, scroll, text) = try makeEditor()
        host(scroll)
        defer { scroll.removeFromSuperview(); coordinator.deactivate() }
        coordinator.update(text, source: source, path: "one.md", isEditable: true, onEdit: { _ in },
            highlight: LibrarySourceHighlight(byteRange: byteStart..<(byteStart + 3),
                sourceBytes: Data(source.utf8)))
        let ns = source as NSString
        XCTAssertEqual(foreground(text, at: ns.range(of: "{{tone}}").location), .controlAccentColor)
        XCTAssertEqual(text.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: ns.range(of: "now").location, effectiveRange: nil) as? NSColor,
            NSColor.systemYellow.withAlphaComponent(0.35))

        // An edit clears the quote background but keeps the placeholder color.
        text.insertText("!", replacementRange: NSRange(location: ns.length, length: 0))
        XCTAssertNil(text.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: ns.range(of: "now").location, effectiveRange: nil))
        XCTAssertEqual(foreground(text, at: ns.range(of: "{{tone}}").location), .controlAccentColor)
    }

    func testFocusRevisionAppliesFirstResponderOncePerChange() throws {
        let (coordinator, scroll, text) = try makeEditor()
        let window = host(scroll)
        let other = FocusableView(frame: .zero)
        window.contentView?.addSubview(other)
        defer { scroll.removeFromSuperview(); other.removeFromSuperview(); coordinator.deactivate() }

        // An unattached update does not consume the revision.
        scroll.removeFromSuperview()
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 1)
        XCTAssertNil(text.window)
        window.contentView?.addSubview(scroll)
        XCTAssertTrue(window.firstResponder === text, "Attachment applies the pending focus without another render")

        // Repeating a render with the same revision never steals focus back.
        XCTAssertTrue(window.makeFirstResponder(other))
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 1)
        XCTAssertTrue(window.firstResponder === other)

        coordinator.update(text, source: "Body", path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 2)
        XCTAssertTrue(window.firstResponder === text, "A changed revision refocuses once")

        // Composition defers a newer revision instead of being disturbed.
        text.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 3)
        XCTAssertTrue(text.hasMarkedText(), "A focus update must not retire composition")
        text.unmarkText()
        XCTAssertTrue(window.makeFirstResponder(other))
        coordinator.update(text, source: text.string, path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 3)
        XCTAssertTrue(window.firstResponder === text, "The deferred revision applies after composition")
        XCTAssertTrue(window.makeFirstResponder(other))
        coordinator.update(text, source: text.string, path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 3)
        XCTAssertTrue(window.firstResponder === other, "An applied revision never re-steals")
    }

    func testPreviewVisibilityKeepsNativeUndoAndSelection() throws {
        let (coordinator, scroll, text) = try makeEditor()
        let window = host(scroll)
        defer { scroll.removeFromSuperview(); coordinator.deactivate() }
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true, onEdit: { _ in })
        XCTAssertTrue(window.makeFirstResponder(text))
        let undo = try XCTUnwrap(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        undo.endUndoGrouping()
        let selection = NSRange(location: 5, length: 2)
        text.setSelectedRange(selection)
        LibrarySourceEditor.updateVisibility(false, in: scroll)
        XCTAssertTrue(scroll.isHidden)
        XCTAssertFalse(window.firstResponder === text, "Preview cannot keep editing a hidden source")
        LibrarySourceEditor.updateVisibility(true, in: scroll)
        XCTAssertFalse(scroll.isHidden)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(text.string, "Body")
    }

    func testFocusRevisionZeroNeverFocuses() throws {
        let (coordinator, scroll, text) = try makeEditor()
        let window = host(scroll)
        let other = FocusableView(frame: .zero)
        window.contentView?.addSubview(other)
        defer { scroll.removeFromSuperview(); other.removeFromSuperview(); coordinator.deactivate() }
        XCTAssertTrue(window.makeFirstResponder(other))
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true, onEdit: { _ in })
        coordinator.update(text, source: "Body", path: "one.md", isEditable: true,
            onEdit: { _ in }, focusRevision: 0)
        XCTAssertTrue(window.firstResponder === other)
    }
}

/// A plain view that accepts first responder, to prove focus leaves and
/// returns only on changed revisions.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private extension NSRange {
    /// Test-only bridge: a UTF-16 range's byte span inside its source string.
    func toByteRange(in source: String) -> Range<Int> {
        guard let range: Range<String.Index> = Range(self, in: source) else { return 0..<0 }
        let lower = source[..<range.lowerBound].utf8.count
        return lower..<(lower + source[range].utf8.count)
    }
}
