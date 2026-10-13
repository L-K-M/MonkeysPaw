import Foundation
import XCTest
@testable import MonkeysPawCore

final class SettingsStoreTests: XCTestCase {
    private let defaultsJSON = #"{"automaticUpdateChecks":"enabled","carbonShortcuts":{"repeatLast":null,"togglePicker":"Ctrl+Alt+p"},"delivery":{"clipboardRestore":"off","linuxDefaultPasteChord":"standard"},"firstRun":{"libraryFolderCompleted":false,"seedsOffered":false,"setupPresented":false,"tourCompleted":false},"libraryFolderPath":null,"version":1}"#

    func testPreTourSettingsInferCompletionFromSetupWhileFreshDefaultsStayPending() throws {
        for setupPresented in [false, true] {
            let files = MemoryFileStore()
            let original = """
                {"version":1,"firstRun":{"setupPresented":\(setupPresented),
                "libraryFolderCompleted":true,"seedsOffered":true}}
                """
            try files.put(original, at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            let progress = try XCTUnwrap(JSONSerialization.jsonObject(with:
                JSONEncoder().encode(settings.snapshot.document.firstRun)) as? [String: Any])
            XCTAssertEqual(progress["tourCompleted"] as? Bool, setupPresented)
            XCTAssertFalse(settings.snapshot.isReadOnly)
            XCTAssertEqual(try files.text(at: "settings.json"), original)
        }
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(SettingsDocument().firstRun)) as? [String: Any])
        XCTAssertEqual(fresh["tourCompleted"] as? Bool, false)
    }

    func testMissingFileUsesDefaultsUntilFirstSuccessfulIntentWritesSettings() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))

        XCTAssertEqual(settings.snapshot.document, SettingsDocument())
        XCTAssertEqual(settings.snapshot.document.version, 1)
        XCTAssertFalse(settings.snapshot.isReadOnly)
        XCTAssertNil(try files.stamp(at: "settings.json"))

        try settings.setLibraryFolder(nil)

        XCTAssertEqual(try files.text(at: "settings.json"), defaultsJSON)
        XCTAssertFalse(files.isPrivate(at: "settings.json"))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["settings.json"])
    }

    func testExplicitTourFlagWinsOverUpgradeRuleAndSurvivesSetupAndFolderChanges() throws {
        for setupPresented in [false, true] {
            for completed in [false, true] {
                let files = MemoryFileStore()
                try files.put("""
                    {"version":1,"firstRun":{"setupPresented":\(setupPresented),
                    "libraryFolderCompleted":true,"seedsOffered":true,"tourCompleted":\(completed)}}
                    """, at: "settings.json")
                let settings = SettingsService(store: SettingsStore(files: files))
                XCTAssertEqual(settings.snapshot.document.firstRun.tourCompleted, completed)
                try settings.markSetupPresented()
                try settings.setLibraryFolder("/chosen")
                try settings.setLibraryFolder(nil)
                XCTAssertEqual(settings.snapshot.document.firstRun.tourCompleted, completed)
                XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
            }
        }
    }

    func testTourCompletionWritesVersionOneBeforePublicationAndIsIdempotent() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.markSetupPresented()
        try settings.completeLibraryFolderStep()
        try settings.markSeedsOffered()
        XCTAssertFalse(settings.snapshot.document.firstRun.tourCompleted)
        let previous = settings.snapshot
        var writes = 0
        files.onWrite = { _ in writes += 1 }
        files.failNextWrite = true
        XCTAssertThrowsError(try settings.completeTour()) {
            XCTAssertEqual($0 as? SettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(settings.snapshot, previous)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, previous)
        try settings.completeTour()
        try settings.completeTour()
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(settings.snapshot.document.firstRun.tourCompleted)
        XCTAssertEqual(settings.snapshot.document.version, 1)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    func testCurrentVersionLoadsChosenFolderAndIndependentProgressWithoutRewriting() throws {
        let files = MemoryFileStore()
        let original = #"{"version":1,"libraryFolderPath":"/chosen library","firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":false}}"#
        try files.put(original, at: "settings.json")
        var writes = 0
        files.onWrite = { _ in writes += 1 }

        let settings = SettingsService(store: SettingsStore(files: files, legacyFirstRun: .setupPresented))

        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/chosen library")
        XCTAssertEqual(settings.snapshot.document.firstRun,
                       FirstRunProgress(setupPresented: true, libraryFolderCompleted: true, tourCompleted: true))
        XCTAssertNil(settings.snapshot.readOnlyError)
        try settings.markSetupPresented()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try files.text(at: "settings.json"), original)
    }

    func testLegacySetupImportLeavesLibraryStepPendingAndPersistsWithNextChange() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files, legacyFirstRun: .setupPresented))

        XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(setupPresented: true, tourCompleted: true))
        XCTAssertNil(try files.stamp(at: "settings.json"))
        try settings.setLibraryFolder("/existing library")

        let reopened = SettingsService(store: SettingsStore(files: files))
        XCTAssertEqual(reopened.snapshot.document, settings.snapshot.document)
        XCTAssertTrue(reopened.snapshot.document.firstRun.setupPresented)
        XCTAssertFalse(reopened.snapshot.document.firstRun.libraryFolderCompleted)
        XCTAssertFalse(reopened.snapshot.document.firstRun.seedsOffered)
    }

    func testCurrentSettingsTakePrecedenceOverLegacyFlag() throws {
        let files = MemoryFileStore()
        try files.put(defaultsJSON, at: "settings.json")
        let settings = SettingsService(store: SettingsStore(files: files, legacyFirstRun: .setupPresented))

        XCTAssertFalse(settings.snapshot.document.firstRun.setupPresented)
        try settings.completeLibraryFolderStep()
        XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(libraryFolderCompleted: true))
    }

    func testSyntheticOlderShapeMigratesOnLoadThenRewritesAtomicallyWithNextChange() throws {
        let files = MemoryFileStore()
        let original = #"{"version":0,"folder":"/legacy","shown":true,"futureOption":{"keep":7}}"#
        try files.put(original, at: "settings.json")
        var versions = [Int]()
        let migration = SettingsMigration(fromVersion: 0) { object in
            versions.append(object["version"] as! Int)
            var migrated = object
            migrated["libraryFolderPath"] = migrated.removeValue(forKey: "folder")
            let shown = migrated.removeValue(forKey: "shown") as! Bool
            migrated["firstRun"] = ["setupPresented": shown,
                                    "libraryFolderCompleted": false, "seedsOffered": false]
            return migrated
        }
        let settings = SettingsService(store: SettingsStore(files: files, migrations: [migration]))

        XCTAssertEqual(versions, [0])
        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/legacy")
        XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(setupPresented: true, tourCompleted: true))
        XCTAssertEqual(try files.text(at: "settings.json"), original)

        let before = settings.snapshot
        files.failNextWrite = true
        XCTAssertThrowsError(try settings.completeLibraryFolderStep()) {
            XCTAssertEqual($0 as? SettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(settings.snapshot, before)
        XCTAssertEqual(try files.text(at: "settings.json"), original)

        try settings.completeLibraryFolderStep()
        let object = try json(files)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNil(object["folder"])
        XCTAssertNil(object["shown"])
        XCTAssertEqual((object["futureOption"] as? [String: Int])?["keep"], 7)
        let reopened = SettingsService(store: SettingsStore(files: files))
        XCTAssertEqual(reopened.snapshot, settings.snapshot)
    }

    func testSyntheticChainAppliesEveryVersionInOrderAndLoaderOwnsVersionAdvance() throws {
        var visited = [Int]()
        let first = SettingsMigration(fromVersion: 1) { object in
            XCTAssertEqual(object["version"] as? Int, 1)
            visited.append(1)
            var migrated = object
            migrated["middle"] = migrated.removeValue(forKey: "old")
            return migrated
        }
        let second = SettingsMigration(fromVersion: 2) { object in
            XCTAssertEqual(object["version"] as? Int, 2)
            visited.append(2)
            var migrated = object
            migrated["new"] = migrated.removeValue(forKey: "middle")
            return migrated
        }
        // Registration order must not skip a link in the version chain.
        let loader = SettingsLoader(currentVersion: 3, migrations: [second, first])
        let result = try loader.load(Data(#"{"version":1,"old":"kept","unknown":true}"#.utf8))

        XCTAssertEqual(visited, [1, 2])
        XCTAssertEqual(result.sourceVersion, 1)
        XCTAssertEqual(result.object["version"] as? Int, 3)
        XCTAssertEqual(result.object["new"] as? String, "kept")
        XCTAssertEqual(result.object["unknown"] as? Bool, true)
        XCTAssertNil(result.object["old"])
        XCTAssertNil(result.object["middle"])
    }

    func testMissingMigrationLinkAndFailedTransformFailClosed() throws {
        let missing = SettingsLoader(currentVersion: 3, migrations: [
            SettingsMigration(fromVersion: 1) { $0 }
        ])
        XCTAssertThrowsError(try missing.load(Data(#"{"version":1}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsError, .unsupportedVersion(2))
        }

        let files = MemoryFileStore()
        let original = #"{"version":0}"#
        try files.put(original, at: "settings.json")
        let failure = SettingsMigration(fromVersion: 0) { _ in
            throw NSError(domain: "untrusted error body", code: 1)
        }
        let settings = SettingsService(store: SettingsStore(files: files, migrations: [failure]))
        XCTAssertEqual(settings.snapshot.readOnlyError, .corruptFile)
        XCTAssertEqual(settings.snapshot.document, SettingsDocument())
        XCTAssertThrowsError(try settings.markSetupPresented())
        XCTAssertEqual(try files.text(at: "settings.json"), original)
    }

    func testFutureVersionIsReadOnlyEvenWhenKnownFieldsHaveDifferentShapes() throws {
        for original in [#"{"version":2}"#, #"{"version":99,"firstRun":[],"libraryFolderPath":7}"#] {
            let files = MemoryFileStore()
            try files.put(original, at: "settings.json")
            let version = try json(files)["version"] as! Int
            let settings = SettingsService(store: SettingsStore(files: files, legacyFirstRun: .setupPresented))

            XCTAssertEqual(settings.snapshot.document, SettingsDocument())
            XCTAssertEqual(settings.snapshot.readOnlyError, .futureVersion(version))
            XCTAssertTrue(settings.snapshot.isReadOnly)
            let accesses = files.accessCount
            for operation in allChanges(settings) {
                XCTAssertThrowsError(try operation()) {
                    XCTAssertEqual($0 as? SettingsError, .futureVersion(version))
                }
            }
            XCTAssertEqual(files.accessCount, accesses)
            XCTAssertEqual(try files.text(at: "settings.json"), original)
        }
    }

    func testCorruptDocumentsAndUnsupportedOlderVersionsNeverGetOverwritten() throws {
        let invalid = [
            "not JSON", "[]", "{}", #"{"version":true}"#, #"{"version":1.5}"#,
            #"{"version":1}"#,
            #"{"version":1,"firstRun":{"setupPresented":true}}"#,
            #"{"version":1,"libraryFolderPath":7,"firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false}}"#,
            #"{"version":1,"libraryFolderPath":"relative/path","firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false}}"#,
            #"{"version":1,"libraryFolderPath":"/bad\u0000path","firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false}}"#,
            #"{"version":1,"firstRun":{"setupPresented":1,"libraryFolderCompleted":false,"seedsOffered":false}}"#,
            #"{"version":1,"firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":true,"tourCompleted":null}}"#,
            #"{"version":1,"firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":true,"tourCompleted":1}}"#,
            #"{"version":1,"firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":true,"tourCompleted":"true"}}"#,
            #"{"version":0}"#, #"{"version":-1}"#
        ]
        for original in invalid {
            let files = MemoryFileStore()
            try files.put(original, at: "settings.json")
            let settings = SettingsService(store: SettingsStore(files: files))
            let expected: SettingsError
            switch original {
            case #"{"version":0}"#: expected = .unsupportedVersion(0)
            case #"{"version":-1}"#: expected = .unsupportedVersion(-1)
            default: expected = .corruptFile
            }
            XCTAssertEqual(settings.snapshot.document, SettingsDocument())
            XCTAssertEqual(settings.snapshot.readOnlyError, expected)
            for operation in allChanges(settings) {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? SettingsError, expected) }
            }
            XCTAssertEqual(try files.text(at: "settings.json"), original)
        }
    }

    func testReadFailuresAreTypedOrSanitizedAndRemainReadOnlyUntilRecreated() throws {
        let privateDomain = "private path/body"
        let privateBody = "opaque untrusted error body"
        let failures: [Error] = [FileStoreError.invalidRoot,
            NSError(domain: privateDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: privateBody])]
        for failure in failures {
            let files = MemoryFileStore()
            files.onRead = { _ in throw failure }
            let settings = SettingsService(store: SettingsStore(files: files))
            let expected = SettingsError.readFailed(failure as? FileStoreError ?? .ioFailure)
            XCTAssertEqual(settings.snapshot.readOnlyError, expected)

            files.onRead = nil
            XCTAssertThrowsError(try settings.markSetupPresented()) {
                XCTAssertEqual($0 as? SettingsError, expected)
                let description = String(describing: $0)
                XCTAssertFalse(description.contains(privateDomain))
                XCTAssertFalse(description.contains(privateBody))
            }
            XCTAssertNil(try files.stamp(at: "settings.json"))
            let recovered = SettingsService(store: SettingsStore(files: files))
            XCTAssertNil(recovered.snapshot.readOnlyError)
            try recovered.markSetupPresented()
            XCTAssertTrue(recovered.snapshot.document.firstRun.setupPresented)
        }
    }

    func testWriteFailureRetainsPreviousFileAndMemoryAndAllowsRetry() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLibraryFolder("/previous")
        try settings.markSetupPresented()
        let original = try files.read(at: "settings.json")
        let before = settings.snapshot

        files.failNextWrite = true
        XCTAssertThrowsError(try settings.setLibraryFolder("/next")) {
            XCTAssertEqual($0 as? SettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(settings.snapshot, before)
        XCTAssertEqual(try files.read(at: "settings.json"), original)

        try settings.setLibraryFolder("/next")
        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/next")
        XCTAssertEqual(settings.snapshot.document.firstRun, before.document.firstRun)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    func testFailedInitialWriteLeavesNoFileAndNoProgress() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        files.failNextWrite = true
        XCTAssertThrowsError(try settings.markSeedsOffered())
        XCTAssertEqual(settings.snapshot.document, SettingsDocument())
        XCTAssertFalse(settings.snapshot.isReadOnly)
        XCTAssertNil(try files.stamp(at: "settings.json"))
        try settings.markSeedsOffered()
        XCTAssertTrue(settings.snapshot.document.firstRun.seedsOffered)
    }

    func testUnknownRootAndProgressKeysRoundTripThroughEveryKindOfChange() throws {
        let files = MemoryFileStore()
        let original = #"{"version":1,"libraryFolderPath":null,"firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false,"futureProgress":{"keep":[true,7,null,"text"]}},"futureOption":{"a":false,"nested":{"n":1.25}},"futureNull":null}"#
        try files.put(original, at: "settings.json")
        let before = try json(files)
        let settings = SettingsService(store: SettingsStore(files: files))

        for operation in allChanges(settings) { try operation() }

        let after = try json(files)
        XCTAssertTrue((before["futureOption"] as! NSDictionary).isEqual(after["futureOption"] as! NSDictionary))
        XCTAssertTrue(after["futureNull"] is NSNull)
        let beforeProgress = before["firstRun"] as! [String: Any]
        let afterProgress = after["firstRun"] as! [String: Any]
        XCTAssertTrue((beforeProgress["futureProgress"] as! NSDictionary)
            .isEqual(afterProgress["futureProgress"] as! NSDictionary))
        XCTAssertEqual(after["version"] as? Int, 1)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    func testReplacementWithNewerOrCorruptSettingsDuringSessionFailsClosed() throws {
        for (replacement, expected) in [(#"{"version":2}"#, SettingsError.futureVersion(2)),
                                        ("corrupt", .corruptFile)] {
            let files = MemoryFileStore()
            let settings = SettingsService(store: SettingsStore(files: files))
            try settings.setLibraryFolder("/old")
            try files.put(replacement, at: "settings.json")

            XCTAssertThrowsError(try settings.setLibraryFolder(nil)) {
                XCTAssertEqual($0 as? SettingsError, expected)
            }
            XCTAssertEqual(settings.snapshot.document, SettingsDocument())
            XCTAssertEqual(settings.snapshot.readOnlyError, expected)
            XCTAssertEqual(try files.text(at: "settings.json"), replacement)
        }
    }

    func testValidReplacementIsRereadAndMergedWithoutLosingProgressOrUnknownKeys() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLibraryFolder("/cached")
        try files.put(#"{"version":1,"libraryFolderPath":"/external","firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":false,"futureProgress":7},"futureOption":"kept"}"#,
                      at: "settings.json")

        try settings.markSeedsOffered()

        XCTAssertEqual(settings.snapshot.document.libraryFolderPath, "/external")
        XCTAssertEqual(settings.snapshot.document.firstRun,
                       FirstRunProgress(setupPresented: true, libraryFolderCompleted: true,
                                        seedsOffered: true, tourCompleted: true))
        let object = try json(files)
        XCTAssertEqual(object["futureOption"] as? String, "kept")
        XCTAssertEqual((object["firstRun"] as? [String: Any])?["futureProgress"] as? Int, 7)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    func testSetLibraryFolderRejectsRelativePathsAndControlCharactersWithoutChangingStoredFile() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.setLibraryFolder("/valid")
        let original = try files.read(at: "settings.json")
        let before = settings.snapshot
        var writes = 0
        files.onWrite = { _ in writes += 1 }

        for path in ["relative/path", "/bad\u{0}path", "/bad\npath"] {
            XCTAssertThrowsError(try settings.setLibraryFolder(path)) {
                XCTAssertEqual($0 as? SettingsError, .invalidLibraryFolder)
            }
            XCTAssertEqual(settings.snapshot, before)
            XCTAssertEqual(try files.read(at: "settings.json"), original)
        }
        XCTAssertEqual(writes, 0)
    }

    func testSettingAndClearingLibraryFolderKeepEveryCompletedFirstRunFlag() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        try settings.markSetupPresented()
        try settings.completeLibraryFolderStep()
        try settings.markSeedsOffered()
        try settings.completeTour()
        let completed = FirstRunProgress(
            setupPresented: true, libraryFolderCompleted: true, seedsOffered: true, tourCompleted: true)
        XCTAssertEqual(settings.snapshot.document.firstRun, completed)

        let paths: [String?] = ["/another", nil]
        for path in paths {
            try settings.setLibraryFolder(path)
            XCTAssertEqual(settings.snapshot.document.libraryFolderPath, path)
            XCTAssertEqual(settings.snapshot.document.firstRun, completed)
            XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
        }
    }

    func testConcurrentChangesKeepEveryProgressFlag() throws {
        let files = MemoryFileStore()
        let settings = SettingsService(store: SettingsStore(files: files))
        // FileStore access occurs only under SettingsStore's lock until the barrier.
        DispatchQueue.concurrentPerform(iterations: 50) { number in
            do {
                switch number % 5 {
                case 0: try settings.setLibraryFolder("/folder\(number)")
                case 1: try settings.markSetupPresented()
                case 2: try settings.completeLibraryFolderStep()
                case 3: try settings.markSeedsOffered()
                default: try settings.completeTour()
                }
            } catch { XCTFail("Concurrent settings change failed.") }
        }
        XCTAssertEqual(settings.snapshot.document.firstRun,
                       FirstRunProgress(setupPresented: true, libraryFolderCompleted: true,
                                        seedsOffered: true, tourCompleted: true))
        XCTAssertNotNil(settings.snapshot.document.libraryFolderPath)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, settings.snapshot)
    }

    private func json(_ files: MemoryFileStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
    }

    private func allChanges(_ settings: SettingsService) -> [() throws -> Void] {
        [ { try settings.setLibraryFolder("/new") }, { try settings.setLibraryFolder(nil) },
          { try settings.markSetupPresented() }, { try settings.completeLibraryFolderStep() },
          { try settings.markSeedsOffered() }, { try settings.completeTour() },
          { try settings.setLinuxDefaultPasteChord(.terminal) },
          { try settings.setClipboardRestore(.previousText) },
          { try settings.setAutomaticUpdateChecks(.disabled) } ]
    }
}
