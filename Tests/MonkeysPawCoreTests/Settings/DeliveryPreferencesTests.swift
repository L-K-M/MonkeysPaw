import Foundation
import XCTest
@testable import MonkeysPawCore

final class DeliveryPreferencesTests: XCTestCase {
    private let progress: [String: Any] = [
        "setupPresented": false, "libraryFolderCompleted": false, "seedsOffered": false
    ]

    func testMissingPreferencesUseSafeDefaultsWithoutRewritingVersionOne() throws {
        for delivery in [nil, [:], ["linuxDefaultPasteChord": "standard"],
                         ["clipboardRestore": "off"]] as [[String: Any]?] {
            let files = MemoryFileStore()
            var object: [String: Any] = ["version": 1, "firstRun": progress]
            if let delivery { object["delivery"] = delivery }
            let original = try JSONSerialization.data(withJSONObject: object)
            try files.write(original, at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            XCTAssertEqual(settings.snapshot.document.delivery, DeliveryPreferences())
            XCTAssertEqual(settings.snapshot.document.automaticUpdateChecks, .enabled)
            XCTAssertTrue(settings.snapshot.allowsAutomaticUpdateChecks)
            XCTAssertFalse(settings.snapshot.isReadOnly)
            try settings.setLibraryFolder(nil)
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
        let fresh = SettingsService(store: SettingsStore(files: MemoryFileStore()))
        XCTAssertEqual(fresh.snapshot.document.delivery, DeliveryPreferences())
        XCTAssertTrue(fresh.snapshot.allowsAutomaticUpdateChecks)
    }

    func testPartialPreferencesDefaultOnlyTheirMissingFields() throws {
        let cases: [([String: Any], DeliveryPreferences)] = [
            (["linuxDefaultPasteChord": "terminal"], DeliveryPreferences(linuxDefaultPasteChord: .terminal)),
            (["clipboardRestore": "previousText"], DeliveryPreferences(clipboardRestore: .previousText))
        ]
        for (delivery, expected) in cases {
            let files = MemoryFileStore()
            try files.write(JSONSerialization.data(withJSONObject:
                ["version": 1, "firstRun": progress, "delivery": delivery]), at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            XCTAssertEqual(settings.snapshot.document.delivery, expected)
            XCTAssertFalse(settings.snapshot.isReadOnly)
        }
    }

    func testFolderAndEveryFirstRunEditPreservePersistedPreferences() throws {
        let files = MemoryFileStore()
        try files.write(JSONSerialization.data(withJSONObject: [
            "version": 1, "firstRun": progress, "libraryFolderPath": "/before",
            "delivery": ["linuxDefaultPasteChord": "terminal", "clipboardRestore": "previousText"],
            "automaticUpdateChecks": "disabled"
        ]), at: "settings.json")
        let settings = SettingsService(store: SettingsStore(files: files))
        let expected = settings.snapshot.document.delivery
        let operations: [() throws -> Void] = [
            { try settings.setLibraryFolder("/after") }, { try settings.setLibraryFolder(nil) },
            { try settings.markSetupPresented() }, { try settings.completeLibraryFolderStep() },
            { try settings.markSeedsOffered() }, { try settings.completeTour() }
        ]
        for operation in operations {
            try operation()
            XCTAssertEqual(settings.snapshot.document.delivery, expected)
            XCTAssertEqual(settings.snapshot.document.automaticUpdateChecks, .disabled)
            XCTAssertFalse(settings.snapshot.allowsAutomaticUpdateChecks)
            XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
        }
    }

    func testMalformedPresentPreferencesFailClosedAndNeverAuthorizeAutomaticChecks() throws {
        let badDelivery: [Any] = [NSNull(), true, 1, "terminal", [],
            ["linuxDefaultPasteChord": NSNull()], ["linuxDefaultPasteChord": "future"],
            ["linuxDefaultPasteChord": true], ["linuxDefaultPasteChord": 1],
            ["clipboardRestore": NSNull()], ["clipboardRestore": "future"],
            ["clipboardRestore": true], ["clipboardRestore": 1]]
        let badUpdates: [Any] = [NSNull(), true, 1, [], [:], "future"]
        let cases = badDelivery.map { ["delivery": $0] }
            + badUpdates.map { ["automaticUpdateChecks": $0] }
        for fields in cases {
            let files = MemoryFileStore()
            var object: [String: Any] = ["version": 1, "firstRun": progress]
            object.merge(fields) { _, new in new }
            let original = try JSONSerialization.data(withJSONObject: object)
            try files.write(original, at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            XCTAssertEqual(settings.snapshot.readOnlyError, .corruptFile)
            XCTAssertFalse(settings.snapshot.allowsAutomaticUpdateChecks)
            XCTAssertEqual(settings.snapshot.document.delivery.clipboardRestore, .off)
            let accesses = files.accessCount
            for operation in preferenceChanges(settings) {
                XCTAssertThrowsError(try operation()) {
                    XCTAssertEqual($0 as? SettingsError, .corruptFile)
                }
            }
            XCTAssertEqual(files.accessCount, accesses)
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
    }

    func testEnumModesRoundTripAndPreferenceEditsPreserveFolderAndProgress() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLibraryFolder("/chosen")
        try settings.markSetupPresented()
        try settings.completeLibraryFolderStep()
        try settings.markSeedsOffered()
        try settings.completeTour()
        let before = settings.snapshot.document
        for chord in [PasteChord.standard, .terminal] {
            for restore in ClipboardRestoreMode.allCases {
                for updates in AutomaticUpdateChecks.allCases {
                    try settings.setLinuxDefaultPasteChord(chord)
                    try settings.setClipboardRestore(restore)
                    try settings.setAutomaticUpdateChecks(updates)
                    let reopened = SettingsService(store: SettingsStore(files: files)).snapshot
                    XCTAssertEqual(reopened, settings.snapshot)
                    XCTAssertEqual(reopened.document.delivery,
                        DeliveryPreferences(linuxDefaultPasteChord: chord, clipboardRestore: restore))
                    XCTAssertEqual(reopened.document.automaticUpdateChecks, updates)
                    XCTAssertEqual(reopened.allowsAutomaticUpdateChecks, updates == .enabled)
                    XCTAssertEqual(reopened.document.libraryFolderPath, before.libraryFolderPath)
                    XCTAssertEqual(reopened.document.firstRun, before.firstRun)
                }
            }
        }
    }

    func testUnknownNestedDeliveryFieldsSurviveAllSettingsEdits() throws {
        let files = MemoryFileStore()
        let unknown: [String: Any] = ["list": [true, 7, NSNull(), "future"], "nested": ["n": 1.25]]
        try files.write(JSONSerialization.data(withJSONObject: [
            "version": 1, "firstRun": progress, "futureRoot": unknown,
            "delivery": ["futureDelivery": unknown, "futureNull": NSNull()]
        ]), at: "settings.json")
        let settings = SettingsService(store: SettingsStore(files: files))
        let operations: [() throws -> Void] = preferenceChanges(settings) + [
            { try settings.setLibraryFolder("/chosen") }, { try settings.setLibraryFolder(nil) },
            { try settings.markSetupPresented() }, { try settings.completeLibraryFolderStep() },
            { try settings.markSeedsOffered() }, { try settings.completeTour() }
        ]
        for operation in operations {
            try operation()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
                files.read(at: "settings.json")) as? [String: Any])
            let delivery = try XCTUnwrap(object["delivery"] as? [String: Any])
            XCTAssertTrue((delivery["futureDelivery"] as! NSDictionary).isEqual(unknown as NSDictionary))
            XCTAssertTrue(delivery["futureNull"] is NSNull)
            XCTAssertTrue((object["futureRoot"] as! NSDictionary).isEqual(unknown as NSDictionary))
        }
    }

    func testFailedPreferenceWritesKeepCommittedFileSnapshotAndModelStateUntilRetry() throws {
        let files = MemoryFileStore()
        let service = SettingsService(store: SettingsStore(files: files))
        let model = SettingsModel(settings: service)
        model.setLibraryFolder("/chosen")
        let operations: [() -> Void] = [
            { model.setLinuxDefaultPasteChord(.terminal) },
            { model.setClipboardRestore(.previousText) },
            { model.setAutomaticUpdateChecks(.disabled) }
        ]
        for operation in operations {
            let before = model.state
            let original = try files.read(at: "settings.json")
            var publications: [SettingsSnapshot] = []
            model.onChange = { publications.append(model.state) }
            files.failNextWrite = true
            operation()
            XCTAssertEqual(model.error, .writeFailed(.ioFailure))
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(publications, [before])
            XCTAssertEqual(try files.read(at: "settings.json"), original)
            XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, before)
            operation()
            XCTAssertNil(model.error)
            XCTAssertNotEqual(model.state, before)
            XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, model.state)
            model.onChange = nil
        }
    }

    func testFutureOrReplacedSettingsRemainReadOnlyAndBlockAllPreferenceWrites() throws {
        for (replacement, expected) in [(#"{"version":99,"delivery":null}"#, SettingsError.futureVersion(99)),
                                        (#"{"version":0}"#, .unsupportedVersion(0)),
                                        ("corrupt", .corruptFile)] {
            for replaceDuringSession in [false, true] {
                let files = MemoryFileStore()
                if !replaceDuringSession { try files.put(replacement, at: "settings.json") }
                let settings = SettingsService(store: SettingsStore(files: files))
                if replaceDuringSession {
                    try settings.setClipboardRestore(.previousText)
                    try files.put(replacement, at: "settings.json")
                }
                for operation in preferenceChanges(settings) {
                    XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? SettingsError, expected) }
                    XCTAssertFalse(settings.snapshot.allowsAutomaticUpdateChecks)
                    XCTAssertEqual(settings.snapshot.document.delivery.clipboardRestore, .off)
                    XCTAssertEqual(settings.snapshot.readOnlyError, expected)
                    XCTAssertEqual(try files.text(at: "settings.json"), replacement)
                }
            }
        }
    }

    func testEachPreferenceSetterRereadsExternalSettingsAndPreservesOtherChoices() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLibraryFolder("/cached")
        let external = SettingsService(store: SettingsStore(files: files))
        try external.setLibraryFolder("/external")
        try external.markSetupPresented()
        try external.setClipboardRestore(.previousText)
        try external.setAutomaticUpdateChecks(.disabled)
        try settings.setLinuxDefaultPasteChord(.terminal)
        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/external")
        XCTAssertTrue(settings.snapshot.document.firstRun.setupPresented)
        XCTAssertEqual(settings.snapshot.document.delivery,
            DeliveryPreferences(linuxDefaultPasteChord: .terminal, clipboardRestore: .previousText))
        XCTAssertEqual(settings.snapshot.document.automaticUpdateChecks, .disabled)

        try external.setLinuxDefaultPasteChord(.standard)
        try settings.setClipboardRestore(.off)
        XCTAssertEqual(settings.snapshot.document.delivery, DeliveryPreferences())
        try external.setClipboardRestore(.previousText)
        try settings.setAutomaticUpdateChecks(.enabled)
        XCTAssertEqual(settings.snapshot.document.delivery.clipboardRestore, .previousText)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    private func preferenceChanges(_ settings: SettingsService) -> [() throws -> Void] {
        [{ try settings.setLinuxDefaultPasteChord(.terminal) },
         { try settings.setClipboardRestore(.previousText) },
         { try settings.setAutomaticUpdateChecks(.disabled) }]
    }
}
