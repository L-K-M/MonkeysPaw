import Foundation
import XCTest
@testable import MonkeysPawCore

final class CarbonShortcutSettingsTests: XCTestCase {
    func testMissingChoicesUseDefaultsWithoutRewritingVersionOne() throws {
        for choices in [nil, [:]] as [[String: Any]?] {
            let files = try fixture(choices)
            let original = try files.read(at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            XCTAssertFalse(settings.snapshot.isReadOnly)
            XCTAssertEqual(settings.snapshot.document.carbonShortcuts, CarbonShortcutChoices())
            try settings.setLibraryFolder(nil)
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
    }

    func testNullClearsAndMissingMembersDefaultIndependently() throws {
        let settings = SettingsService(store: SettingsStore(files: try fixture([
            "togglePicker": NSNull(), "repeatLast": "Ctrl+Shift+R",
        ])))
        XCTAssertNil(settings.snapshot.document.carbonShortcuts.togglePicker)
        XCTAssertEqual(settings.snapshot.document.carbonShortcuts.repeatLast, try Accelerator("Ctrl+Shift+R"))
        let repeatOnly = SettingsService(store: SettingsStore(files: try fixture(["repeatLast": NSNull()])))
        XCTAssertEqual(repeatOnly.snapshot.document.carbonShortcuts, CarbonShortcutChoices())
    }

    func testInvalidPresentChoicesFailClosedWithoutOverwriting() throws {
        let invalid: [Any] = [NSNull(), 7, [], "Ctrl+P",
            ["togglePicker": false], ["repeatLast": 5], ["repeatLast": ""],
            ["repeatLast": "Ctrl++R"], ["repeatLast": "Insert"], ["repeatLast": "F21"],
            ["repeatLast": "Cmd+Super+R"], ["repeatLast": "Ctrl+Alt+P"],
            ["togglePicker": "Cmd+Plus", "repeatLast": "Super+Shift+Equal"]]
        for choices in invalid {
            let files = try fixture(choices)
            let original = try files.read(at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            XCTAssertEqual(settings.snapshot.readOnlyError, .corruptFile)
            XCTAssertThrowsError(try settings.setCarbonShortcut(.repeatLast, accelerator: nil))
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
    }

    func testInvalidCarbonChoicesPreserveOtherSettingsWhileRemainingReadOnly() throws {
        let invalid: [Any] = [NSNull(), 7, [], "future format",
            ["togglePicker": false], ["repeatLast": "FutureKey"],
            ["repeatLast": "Ctrl++R"], ["repeatLast": "Insert"], ["repeatLast": "F21"],
            ["repeatLast": "Cmd+Super+R"], ["repeatLast": "Ctrl+Alt+P"],
            ["togglePicker": "Cmd+Plus", "repeatLast": "Super+Shift+Equal"]]
        for choices in invalid {
            let files = try fixture(choices)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
            object["libraryFolderPath"] = "/chosen/library"
            object["firstRun"] = ["setupPresented": true, "libraryFolderCompleted": true,
                "seedsOffered": true, "tourCompleted": true]
            object["delivery"] = ["linuxDefaultPasteChord": "terminal", "clipboardRestore": "previousText"]
            object["automaticUpdateChecks"] = "disabled"
            let original = try JSONSerialization.data(withJSONObject: object)
            try files.write(original, at: "settings.json")

            let settings = SettingsService(store: SettingsStore(files: files))

            XCTAssertEqual(settings.snapshot.readOnlyError, .corruptFile)
            XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/chosen/library")
            XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(setupPresented: true,
                libraryFolderCompleted: true, seedsOffered: true, tourCompleted: true))
            XCTAssertEqual(settings.snapshot.document.delivery.linuxDefaultPasteChord, .terminal)
            XCTAssertEqual(settings.snapshot.document.delivery.clipboardRestore, .previousText)
            XCTAssertEqual(settings.snapshot.document.automaticUpdateChecks, .disabled)
            XCTAssertEqual(settings.snapshot.document.carbonShortcuts, CarbonShortcutChoices())
            XCTAssertFalse(settings.snapshot.allowsAutomaticUpdateChecks)
            XCTAssertThrowsError(try settings.setLibraryFolder("/replacement"))
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
    }

    func testRereadOfInvalidCarbonChoicesPreservesOtherSettingsAndRefusesWrite() throws {
        let files = try fixture(nil)
        let settings = SettingsService(store: SettingsStore(files: files))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
        object["libraryFolderPath"] = "/externally/chosen"
        object["firstRun"] = ["setupPresented": true, "libraryFolderCompleted": true,
            "seedsOffered": false, "tourCompleted": true]
        object["carbonShortcuts"] = ["repeatLast": "FutureKey"]
        let original = try JSONSerialization.data(withJSONObject: object)
        try files.write(original, at: "settings.json")

        XCTAssertThrowsError(try settings.markSeedsOffered()) {
            XCTAssertEqual($0 as? SettingsError, .corruptFile)
        }

        XCTAssertEqual(settings.snapshot.readOnlyError, .corruptFile)
        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/externally/chosen")
        XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(setupPresented: true,
            libraryFolderCompleted: true, seedsOffered: false, tourCompleted: true))
        XCTAssertEqual(try files.read(at: "settings.json"), original)
    }

    func testEverySetterPreservesBothChoicesAndUnknownJSON() throws {
        let files = try fixture(["togglePicker": "Cmd+F20", "repeatLast": "Ctrl+Alt+R", "future": ["keep": 7]])
        let settings = SettingsService(store: SettingsStore(files: files))
        let choices = settings.snapshot.document.carbonShortcuts
        let changes: [() throws -> Void] = [
            { try settings.setLibraryFolder("/chosen") }, { try settings.setLibraryFolder(nil) },
            { try settings.markSetupPresented() }, { try settings.completeLibraryFolderStep() },
            { try settings.markSeedsOffered() }, { try settings.completeTour() },
            { try settings.setLinuxDefaultPasteChord(.terminal) },
            { try settings.setClipboardRestore(.previousText) },
            { try settings.setAutomaticUpdateChecks(.disabled) },
        ]
        for change in changes {
            try change()
            XCTAssertEqual(settings.snapshot.document.carbonShortcuts, choices)
            XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
            let nested = try XCTUnwrap(object["carbonShortcuts"] as? [String: Any])
            XCTAssertEqual(nested["future"] as? [String: Int], ["keep": 7])
            XCTAssertEqual(object["futureRoot"] as? [String: Int], ["keep": 8])
        }
    }

    func testChoiceChangesPreservePreferencesAndPublishOnlyAfterSuccessfulSave() throws {
        let files = try fixture(["togglePicker": "Cmd+F20", "repeatLast": "Ctrl+Alt+R"])
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLinuxDefaultPasteChord(.terminal)
        try settings.setClipboardRestore(.previousText)
        try settings.setAutomaticUpdateChecks(.disabled)
        let previous = settings.snapshot
        files.failNextWrite = true
        XCTAssertThrowsError(try settings.setCarbonShortcut(.repeatLast, accelerator: nil)) {
            XCTAssertEqual($0 as? SettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(settings.snapshot, previous)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, previous)

        try settings.setCarbonShortcut(.repeatLast, accelerator: nil)
        XCTAssertEqual(settings.snapshot.document.delivery, previous.document.delivery)
        XCTAssertEqual(settings.snapshot.document.automaticUpdateChecks, .disabled)
        XCTAssertEqual(settings.snapshot.document.carbonShortcuts.togglePicker, previous.document.carbonShortcuts.togglePicker)
        XCTAssertNil(settings.snapshot.document.carbonShortcuts.repeatLast)
        try settings.setCarbonShortcut(.togglePicker, accelerator: nil)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
        XCTAssertNil(settings.snapshot.document.carbonShortcuts.togglePicker)
    }

    func testSavedSpellingsRoundTripAllParsedKeyAndModifierForms() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setCarbonShortcut(.togglePicker, accelerator: nil)
        let names = ("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
            + (1...20).map { "F\($0)" }
            + ["Space", "Return", "Tab", "Escape", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown",
               "Up", "Down", "Left", "Right", "Comma", "Period", "Slash", "Backslash", "Minus", "Equal", "Plus",
               "Semicolon", "Quote", "Grave", "BracketLeft", "BracketRight"]
        for text in names.map({ "Ctrl+Alt+Shift+Cmd+\($0)" }) + ["Super+R", "CmdOrCtrl+R"] {
            let accelerator = try Accelerator(text)
            try settings.setCarbonShortcut(.repeatLast, accelerator: accelerator)
            let reopened = SettingsService(store: SettingsStore(files: files))
            XCTAssertFalse(reopened.snapshot.isReadOnly, text)
            XCTAssertEqual(reopened.snapshot.document.carbonShortcuts.repeatLast, accelerator, text)
        }
    }

    func testCarbonAliasesCollideBeforeSettingsChange() throws {
        let files = try fixture(["togglePicker": "Cmd+Plus"])
        let settings = SettingsService(store: SettingsStore(files: files))
        let previous = settings.snapshot
        XCTAssertThrowsError(try settings.setCarbonShortcut(.repeatLast, accelerator: Accelerator("Super+Shift+Equal"))) {
            XCTAssertEqual($0 as? ShortcutRebindError, .collision(.togglePicker))
        }
        XCTAssertEqual(settings.snapshot, previous)
    }

    private func fixture(_ choices: Any?) throws -> MemoryFileStore {
        let files = MemoryFileStore()
        var object: [String: Any] = ["version": 1, "libraryFolderPath": NSNull(), "futureRoot": ["keep": 8],
            "firstRun": ["setupPresented": false, "libraryFolderCompleted": false, "seedsOffered": false]]
        object["carbonShortcuts"] = choices
        try files.write(JSONSerialization.data(withJSONObject: object), at: "settings.json")
        return files
    }
}
