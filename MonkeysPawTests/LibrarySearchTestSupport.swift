import AppKit
import XCTest
@testable import MonkeysPaw

enum LibrarySearchTestSupport {
    static func begin(_ controller: LibraryWindowController) throws -> (field: NSSearchField, editor: NSTextView) {
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        controller.searchLibrary(nil)
        let field = try XCTUnwrap(controller.searchItem?.searchField)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        return (field, editor)
    }

    @discardableResult
    static func type(_ query: String, in controller: LibraryWindowController) throws -> (field: NSSearchField, editor: NSTextView) {
        let input = try begin(controller)
        input.editor.insertText(query, replacementRange: NSRange(location: 0, length: (input.editor.string as NSString).length))
        // Toolbar updates can replace the shared field editor during typing.
        let editor = try XCTUnwrap(input.field.currentEditor() as? NSTextView)
        XCTAssertTrue(controller.window?.firstResponder === editor)
        XCTAssertEqual(editor.string, query)
        XCTAssertEqual(controller.presentation.snapshot.filter, query, "Native typing must reach Core")
        return (input.field, editor)
    }
}
