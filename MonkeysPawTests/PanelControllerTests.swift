import AppKit
import XCTest
@testable import MonkeysPaw

final class PanelControllerTests: XCTestCase {
    func testEscapeMayRestoreWhilePanelIsKeyButOwnedWindowDismissalMayNot() {
        let panel = PromptPanel(content: NSView())
        let setup = NSWindow()
        setup.isReleasedWhenClosed = false
        defer { panel.close(); setup.close() }

        // Inspect the key window before ordering the panel out: AppKit may make
        // Setup key automatically afterward even when Escape was intentional.
        XCTAssertEqual(PanelController.dismissalReason(requested: .dismissal, panel: panel,
                                                        keyWindow: panel), .dismissal)
        XCTAssertEqual(PanelController.dismissalReason(requested: .dismissal, panel: panel,
                                                        keyWindow: setup), .blur)
        XCTAssertEqual(PanelController.dismissalReason(requested: .blur, panel: panel,
                                                        keyWindow: nil), .blur)
        XCTAssertEqual(PanelController.dismissalReason(requested: .delivery, panel: panel,
                                                        keyWindow: setup), .delivery)
    }
}
