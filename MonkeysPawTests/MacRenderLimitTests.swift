import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacRenderLimitTests: XCTestCase {
    func testOversizedPreviewKeepsSourceCommandsAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("library")
        let files = try RootedFileStore(root: root)
        let value = String(repeating: "a", count: 1_024)
        let source = "---\nfields: {x: {default: " + value + "}}\n---\n" + String(repeating: "{{x}}", count: 2_049)
        try files.write(Data(source.utf8), at: "expanded.md")
        let originalMenu = NSApp.mainMenu
        let delegate = AppDelegate(libraryRoot: root, dataRoot: directory.appendingPathComponent("data"),
            launchURI: { _ in XCTFail("Preview must not launch another app") })
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = originalMenu
            try? FileManager.default.removeItem(at: directory)
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.showLibrary()
        let window = try XCTUnwrap(delegate.libraryWindow)
        defer { window.window?.close() }
        let presentation = window.presentation
        presentation.selectPath("expanded.md")
        let deadline = Date().addingTimeInterval(5)
        while presentation.editorState.previewOutputFailure == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(presentation.editorState.previewOutputFailure, .outputTooLarge)
        XCTAssertNil(presentation.editorState.previewFailure)
        XCTAssertTrue(presentation.editorState.canSave)
        XCTAssertTrue(presentation.canToggleFavorite)
        presentation.editorMode = .preview
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }
}
