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
    static func type(_ query: String, in controller: LibraryWindowController,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (field: NSSearchField, editor: NSTextView) {
        let input = try begin(controller)
        var ended = "no end-edit notification"
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification,
            object: input.field, queue: nil) { notification in
                let state = controller.presentation.editorState
                let movement = notification.userInfo?["NSTextMovement"] as? Int
                let key = NSApp.currentEvent.flatMap { $0.type == .keyDown ? String($0.keyCode) : nil } ?? "none"
                let queuedCurrent = state.queuedActions.contains { action in
                    guard case .open(let selection) = action else { return false }
                    return selection.relativePath == state.prompt?.relativePath
                }
                ended = "movement=\(movement.map { String($0) } ?? "none"), keyCode=\(key), "
                    + "queued=\(state.queuedActions.count), queuedCurrent=\(queuedCurrent), "
                    + "pending=\(state.pendingDecision != nil)\n" + Thread.callStackSymbols.joined(separator: "\n")
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        input.editor.insertText(query, replacementRange: NSRange(location: 0, length: (input.editor.string as NSString).length))
        let state = controller.presentation.editorState
        let responder = controller.window?.firstResponder
        let responderType = responder.map { String(describing: Swift.type(of: $0)) } ?? "none"
        let opensCurrent: Bool
        if let decision = state.pendingDecision, case .open(let selection) = decision.action {
            opensCurrent = selection.relativePath == state.prompt?.relativePath
        } else { opensCurrent = false }
        let ownership = "responder=\(responderType), enabled=\(input.field.isEnabled), "
            + "sameField=\(input.field === controller.searchItem?.searchField), "
            + "pending=\(state.pendingDecision != nil), opensCurrent=\(opensCurrent), "
            + "newPrompt=\(controller.presentation.newPromptRequest != nil), "
            + "canFocus=\(controller.presentation.canFocusFilter)\n\(ended)"
        let editor = try XCTUnwrap(input.field.currentEditor() as? NSTextView, ownership, file: file, line: line)
        XCTAssertTrue(controller.window?.firstResponder === editor, ownership, file: file, line: line)
        XCTAssertEqual(editor.string, query, file: file, line: line)
        XCTAssertEqual(controller.presentation.snapshot.filter, query, "Native typing must reach Core", file: file, line: line)
        return (input.field, editor)
    }
}
