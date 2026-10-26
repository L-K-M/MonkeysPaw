import Foundation
import XCTest
import MonkeysPawCore

final class SettingsModelTests: XCTestCase {
    func testAbsolutePathWithLeadingCombiningMarkInFirstComponentIsValid() throws {
        let path = "/\u{301}folder"
        let document = try SettingsDocument(libraryFolderPath: path)
        XCTAssertEqual(Array(document.libraryFolderPath!.utf8), Array(path.utf8))

        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        model.setLibraryFolder(path)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.state.document, document)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot.document, document)
    }

    func testFolderIntentsPreserveVerbatimAbsolutePathsAndCanClearToDefault() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        let model = SettingsModel(settings: settings)
        XCTAssertNil(model.libraryFolderPath)

        for path in ["/", "/spaces and 👋/folder", "/literal/../folder", "/home/café", "/home/cafe\u{301}"] {
            model.setLibraryFolder(path)
            XCTAssertNil(model.error)
            XCTAssertEqual(Array(model.libraryFolderPath!.utf8), Array(path.utf8))
            let reopened = SettingsService(store: SettingsStore(files: files))
            XCTAssertEqual(Array(reopened.snapshot.document.libraryFolderPath!.utf8), Array(path.utf8))
        }
        model.clearLibraryFolder()
        XCTAssertNil(model.libraryFolderPath)
        XCTAssertNil(model.error)
        XCTAssertNil(SettingsService(store: SettingsStore(files: files)).snapshot.document.libraryFolderPath)
    }

    func testInvalidFolderIntentSurfacesTypedErrorAndLeavesPreviousSelectionIntact() throws {
        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        model.setLibraryFolder("/valid")
        let original = try files.read(at: "settings.json")
        let before = model.state

        for path in ["", "relative/path", "~/Documents", "file:///folder", "C:\\folder", "/bad\0path", "/bad\npath"] {
            model.setLibraryFolder(path)
            XCTAssertEqual(model.error, .invalidLibraryFolder)
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(model.libraryFolderPath, "/valid")
            XCTAssertFalse(model.isReadOnly)
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
        model.clearLibraryFolder()
        XCTAssertNil(model.error)
    }

    func testFirstRunQueriesAndIntentsAreIndependentAndSurviveReopeningAndFolderChanges() {
        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        XCTAssertTrue(model.needsSetupPresentation)
        XCTAssertTrue(model.needsLibraryFolderStep)
        XCTAssertTrue(model.needsSeedOffer)
        XCTAssertTrue(model.needsTourPresentation)

        model.markSetupPresented()
        XCTAssertFalse(model.needsSetupPresentation)
        XCTAssertTrue(model.needsLibraryFolderStep)
        XCTAssertTrue(model.needsSeedOffer)
        model.completeLibraryFolderStep()
        XCTAssertNil(model.libraryFolderPath)
        XCTAssertFalse(model.needsLibraryFolderStep)
        model.markSeedsOffered()
        XCTAssertTrue(model.needsTourPresentation)
        model.completeTour()
        model.setLibraryFolder("/another")
        model.clearLibraryFolder()

        let reopened = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        XCTAssertFalse(reopened.needsSetupPresentation)
        XCTAssertFalse(reopened.needsLibraryFolderStep)
        XCTAssertFalse(reopened.needsSeedOffer)
        XCTAssertFalse(reopened.needsTourPresentation)
        XCTAssertNil(reopened.error)
    }

    func testLegacyImportStillRequiresNewLibraryFolderStep() {
        let model = SettingsModel(settings: SettingsService(store:
            SettingsStore(files: MemoryFileStore(), legacyFirstRun: .setupPresented)))
        XCTAssertFalse(model.needsSetupPresentation)
        XCTAssertTrue(model.needsLibraryFolderStep)
        XCTAssertTrue(model.needsSeedOffer)
        XCTAssertFalse(model.needsTourPresentation)
    }

    func testReadOnlyStateIsVisibleImmediatelyAndEveryIntentRetainsTheRejectedFile() throws {
        for (original, expected) in [(#"{"version":2}"#, SettingsError.futureVersion(2)),
                                    ("corrupt", .corruptFile),
                                    (#"{"version":1,"firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false}}"#,
                                     .readFailed(.ioFailure))] {
            let files = MemoryFileStore()
            try files.put(original, at: "settings.json")
            if case .readFailed = expected {
                files.onRead = { _ in throw FileStoreError.ioFailure }
            }
            let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
            files.onRead = nil
            XCTAssertTrue(model.isReadOnly)
            XCTAssertEqual(model.error, expected)
            XCTAssertEqual(model.state.readOnlyError, expected)
            XCTAssertFalse(model.needsSetupPresentation)
            XCTAssertFalse(model.needsLibraryFolderStep)
            XCTAssertFalse(model.needsSeedOffer)
            XCTAssertFalse(model.needsTourPresentation)
            let intents = [ { model.setLibraryFolder("/chosen") }, { model.clearLibraryFolder() },
                            { model.markSetupPresented() }, { model.completeLibraryFolderStep() },
                            { model.markSeedsOffered() }, { model.completeTour() },
                            { model.setLinuxDefaultPasteChord(.terminal) },
                            { model.setClipboardRestore(.previousText) },
                            { model.setAutomaticUpdateChecks(.disabled) },
                            { model.setCreepy(.disabled) }, { model.refresh() } ]
            for intent in intents {
                intent()
                XCTAssertEqual(model.error, expected)
                XCTAssertEqual(model.state.document, SettingsDocument())
                XCTAssertFalse(model.needsSetupPresentation)
                XCTAssertFalse(model.needsLibraryFolderStep)
                XCTAssertFalse(model.needsSeedOffer)
                XCTAssertFalse(model.needsTourPresentation)
                XCTAssertEqual(try files.text(at: "settings.json"), original)
            }
        }
    }

    func testFailedCompletionDoesNotAdvanceProgressAndRetryClearsError() {
        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        files.failNextWrite = true
        model.markSeedsOffered()

        XCTAssertEqual(model.error, .writeFailed(.ioFailure))
        XCTAssertFalse(model.isReadOnly)
        XCTAssertTrue(model.needsSeedOffer)
        model.markSeedsOffered()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.needsSeedOffer)
        XCTAssertTrue(model.needsSetupPresentation)
        XCTAssertTrue(model.needsLibraryFolderStep)
    }

    func testOnChangePublishesCommittedStateAndErrorsInlineOnTheCallingUIThread() {
        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        let main = FakeMainThread()
        var states = [SettingsSnapshot]()
        var errors = [SettingsError?]()
        model.onChange = {
            XCTAssertTrue(main.isRunning)
            states.append(model.state)
            errors.append(model.error)
        }

        main.run { model.setLibraryFolder("/chosen") }
        files.failNextWrite = true
        main.run { model.completeLibraryFolderStep() }
        main.run { model.completeLibraryFolderStep() }

        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0].document.libraryFolderPath, "/chosen")
        XCTAssertFalse(states[1].document.firstRun.libraryFolderCompleted)
        XCTAssertTrue(states[2].document.firstRun.libraryFolderCompleted)
        XCTAssertEqual(errors, [nil, .writeFailed(.ioFailure), nil])
    }

    func testRefreshRepublishesChangesMadeThroughTheSharedService() throws {
        let settings = SettingsService(store: SettingsStore(files: MemoryFileStore()))
        let model = SettingsModel(settings: settings)
        try settings.markSetupPresented()
        XCTAssertTrue(model.needsSetupPresentation)

        var changes = 0
        model.onChange = { changes += 1 }
        model.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(model.needsSetupPresentation)
    }

    func testObserversNotifyOnlyForRealChangesWithoutReplacingTheViewHook() {
        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        let main = FakeMainThread()
        var snapshots = [SettingsSnapshot]()
        var errors = [SettingsError?]()
        var viewChanges = 0
        let token = model.addObserver { snapshot, error in
            XCTAssertTrue(main.isRunning)
            snapshots.append(snapshot)
            errors.append(error)
        }
        model.onChange = { viewChanges += 1 }
        main.run { model.refresh() }
        main.run { model.setLibraryFolder("/folder") }
        main.run { model.setLibraryFolder("/folder") }
        main.run { model.setLibraryFolder("relative") }
        main.run { model.setLibraryFolder("relative") }
        main.run { model.refresh() }

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.map { $0.document.libraryFolderPath }, ["/folder", "/folder", "/folder"])
        XCTAssertEqual(errors, [nil, .invalidLibraryFolder, nil])
        XCTAssertEqual(viewChanges, 6)
        model.removeObserver(token)
        main.run { model.clearLibraryFolder() }
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(viewChanges, 7)
    }

    func testIndependentObserversReceiveByteDistinctPathChangesAndCanRemoveThemselves() {
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: MemoryFileStore())))
        var firstChanges = 0
        var secondChanges = 0
        var token: UUID?
        token = model.addObserver { _, _ in
            firstChanges += 1
            model.removeObserver(token!)
        }
        let second = model.addObserver { _, _ in secondChanges += 1 }
        model.setLibraryFolder("/café")
        model.setLibraryFolder("/cafe\u{301}")
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 2)
        model.removeObserver(second)
        model.clearLibraryFolder()
        XCTAssertEqual(secondChanges, 2)
    }

    func testDocumentAndPersistedSchemaContainOnlyTypedNonSecretSettings() throws {
        // The public document has no arbitrary string map or content/secret API.
        let document = try SettingsDocument(libraryFolderPath: "/library", firstRun:
            FirstRunProgress(setupPresented: true, libraryFolderCompleted: true,
                             seedsOffered: true, tourCompleted: true))
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.libraryFolderPath, "/library")
        XCTAssertEqual(document.firstRun, FirstRunProgress(
            setupPresented: true, libraryFolderCompleted: true, seedsOffered: true, tourCompleted: true))

        let files = MemoryFileStore()
        let model = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        model.setLibraryFolder(document.libraryFolderPath!)
        model.markSetupPresented()
        model.completeLibraryFolderStep()
        model.markSeedsOffered()
        model.completeTour()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            files.read(at: "settings.json")) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
            ["version", "libraryFolderPath", "firstRun", "delivery", "automaticUpdateChecks", "creepy", "carbonShortcuts"])
        XCTAssertEqual(object["delivery"] as? [String: String],
            ["linuxDefaultPasteChord": "standard", "clipboardRestore": "off"])
        XCTAssertEqual(object["automaticUpdateChecks"] as? String, "enabled")
        XCTAssertEqual(object["creepy"] as? String, "enabled")
        let shortcuts = try XCTUnwrap(object["carbonShortcuts"] as? [String: Any])
        XCTAssertEqual(Set(shortcuts.keys), ["togglePicker", "repeatLast"])
        XCTAssertEqual(shortcuts["togglePicker"] as? String, "Ctrl+Alt+p")
        XCTAssertTrue(shortcuts["repeatLast"] is NSNull)
        let progress = try XCTUnwrap(object["firstRun"] as? [String: Bool])
        XCTAssertEqual(Set(progress.keys), ["setupPresented", "libraryFolderCompleted", "seedsOffered", "tourCompleted"])
        XCTAssertTrue(progress.values.allSatisfy { $0 })
    }
}
