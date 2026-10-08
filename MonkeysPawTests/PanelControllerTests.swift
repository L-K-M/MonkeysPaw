import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class PanelControllerTests: XCTestCase {
    func testHideBeforeShowingDoesNotNotify() {
        let controller = PanelController(mainThread: DispatchMainThread(),
                                         scheduler: DispatchScheduler(), log: OSLogSink())
        controller.onHide = { _ in XCTFail("A hidden panel has no dismissal to report") }
        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }

    func testRepeatedHideReportsOnlyTheFirstDismissal() {
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        let controller = PanelController(mainThread: DispatchMainThread(),
                                         scheduler: DispatchScheduler(), log: OSLogSink())
        var reasons: [PanelController.HideReason] = []
        controller.onHide = { reasons.append($0) }
        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(reasons.count, 1)

        let firstDismissal = reasons
        controller.hide()
        XCTAssertEqual(reasons, firstDismissal)
    }

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
                                                        keyWindow: nil), .dismissal)
        XCTAssertEqual(PanelController.dismissalReason(requested: .dismissal, panel: panel,
                                                        keyWindow: setup), .blur)
        XCTAssertEqual(PanelController.dismissalReason(requested: .blur, panel: panel,
                                                        keyWindow: nil), .blur)
        XCTAssertEqual(PanelController.dismissalReason(requested: .delivery, panel: panel,
                                                        keyWindow: setup), .delivery)
    }
}
