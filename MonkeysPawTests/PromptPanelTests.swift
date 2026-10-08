import AppKit
import XCTest
@testable import MonkeysPaw

final class PromptPanelTests: XCTestCase {
    func testPreservesFloatingPanelRecipe() {
        let panel = PromptPanel(content: NSView())
        defer { panel.close() }

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .canJoinAllApplications,
                                                 .fullScreenAuxiliary, .transient])
        XCTAssertEqual(panel.animationBehavior, .none)
    }

    func testCommandWUsesEscapeCancellationPath() throws {
        let panel = PromptPanel(content: NSView())
        defer { panel.close() }
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }

        panel.cancelOperation(nil)
        XCTAssertEqual(cancellations, 1)

        let modifiers: [NSEvent.ModifierFlags] = [
            .command,
            [.command, .capsLock],
            [.command, .numericPad, .function],
        ]

        for (index, flags) in modifiers.enumerated() {
            let event = try commandWEvent(for: panel, modifiers: flags)

            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertEqual(cancellations, index + 2)
        }
    }

    func testOtherWCombinationsDoNotCancel() throws {
        let panel = PromptPanel(content: NSView())
        defer { panel.close() }
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }

        let modifiers: [NSEvent.ModifierFlags] = [
            [], [.command, .shift], [.command, .option], [.command, .control],
        ]

        for flags in modifiers {
            let event = try commandWEvent(for: panel, modifiers: flags)

            _ = panel.performKeyEquivalent(with: event)
            XCTAssertEqual(cancellations, 0)
        }
    }

    private func commandWEvent(for panel: PromptPanel,
                               modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let characters = modifiers.contains(.capsLock) ? "W" : "w"

        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                             modifierFlags: modifiers, timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil,
                                             characters: characters,
                                             charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: 13)) // macOS W key.
    }
}
