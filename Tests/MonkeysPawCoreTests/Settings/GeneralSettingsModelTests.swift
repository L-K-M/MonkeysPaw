import Foundation
import XCTest
@testable import MonkeysPawCore

final class GeneralSettingsModelTests: XCTestCase {
    func testInitialStateUsesRunningFolderRatherThanSavedChoiceOrDefaultMarker() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/saved")
        h.library.activeLibraryPath = "/running"
        let model = h.makeModel()

        XCTAssertEqual(model.state.activeLibraryPath, "/running")
        XCTAssertFalse(model.state.isDefaultLibrary)
        XCTAssertFalse(model.state.isReadOnly)
        XCTAssertNil(model.state.settingsError)
        XCTAssertNil(model.state.lastSwitchMessage)
        XCTAssertTrue(h.library.switches.isEmpty)
    }

    func testEveryOutcomePublishesItsMessageAndRetainsOrReplacesTheActivePath() {
        let outcomes: [LibrarySwitchOutcome] = [
            .switched, .settingsNotSaved(.writeFailed(.ioFailure)), .deliveryInFlight,
            .invalidTarget(.notAbsolute), .invalidTarget(.missing), .invalidTarget(.notDirectory),
            .invalidTarget(.unreadable), .invalidTarget(.symlink), .invalidTarget(.outsideSandboxHome),
            .invalidTarget(.rejectedByStore(.invalidRoot)), .libraryUnavailable(.ioFailure)
        ]
        for outcome in outcomes {
            let h = GeneralSettingsHarness()
            h.library.outcome = outcome
            let model = h.makeModel()
            var changes = 0
            model.onChange = { changes += 1 }
            model.chooseFolder("/chosen")

            switch outcome {
            case .invalidTarget, .deliveryInFlight:
                XCTAssertEqual(model.state.activeLibraryPath, "/active")
            case .switched, .settingsNotSaved, .libraryUnavailable:
                XCTAssertEqual(model.state.activeLibraryPath, "/chosen")
            }
            XCTAssertEqual(model.state.lastSwitchMessage, outcome == .switched ? nil : outcome)
            XCTAssertEqual(model.state.settingsError,
                outcome == .settingsNotSaved(.writeFailed(.ioFailure)) ? .writeFailed(.ioFailure) : nil)
            XCTAssertFalse(model.state.isDefaultLibrary)
            XCTAssertFalse(model.state.isReadOnly)
            XCTAssertEqual(changes, 1, "A switch publishes one coherent state")
            XCTAssertEqual(h.library.switches.count, 1)
            XCTAssertEqual(h.library.switches[0], "/chosen")
            if outcome == .switched { XCTAssertNil(GeneralSettingsStrings.message(for: outcome)) }
            else { XCTAssertFalse(GeneralSettingsStrings.message(for: outcome)?.isEmpty ?? true, "\(outcome)") }
        }
    }

    func testSettingsFailureKeepsNewGraphAndSuccessfulSwitchClearsBothErrors() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/saved")
        let model = h.makeModel()
        h.library.outcome = .settingsNotSaved(.writeFailed(.ioFailure))
        model.chooseFolder("/new")

        XCTAssertEqual(model.state.activeLibraryPath, "/new")
        XCTAssertEqual(h.settings.libraryFolderPath, "/saved")
        XCTAssertEqual(model.state.settingsError, h.settings.error)
        XCTAssertEqual(model.state.lastSwitchMessage, .settingsNotSaved(.writeFailed(.ioFailure)))

        // Re-choosing the unsaved running folder retries through composition,
        // which owns the save-only-after-a-healthy-start rule.
        h.library.outcome = .switched
        model.chooseFolder("/new/.")
        XCTAssertEqual(h.library.switches.count, 2)
        XCTAssertNil(model.state.lastSwitchMessage)
        XCTAssertNil(model.state.settingsError)
        XCTAssertEqual(h.settings.libraryFolderPath, "/new/.")

        h.library.outcome = .switched
        model.chooseFolder("/another")
        XCTAssertEqual(model.state.activeLibraryPath, "/another")
        XCTAssertEqual(h.settings.libraryFolderPath, "/another")
        XCTAssertNil(model.state.settingsError)
        XCTAssertNil(model.state.lastSwitchMessage)
    }

    func testDefaultDetectionUsesNormalizedByteIdentityRatherThanSavedMarker() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/explicit")
        h.library.defaultLibraryPath = "/documents/library"
        h.library.activeLibraryPath = "//documents/./unused/../library///"
        let model = h.makeModel()
        XCTAssertTrue(model.state.isDefaultLibrary)

        for (active, defaultPath, expected) in [
            ("/", "/../.././", true),
            ("/\u{301}folder", "/\u{301}folder/", true),
            ("/café", "/cafe\u{301}", false),
            ("/Library", "/library", false),
            ("/default-other", "/default", false),
            ("/folder/.\u{301}", "/folder", false),
            ("relative", "relative", false)
        ] {
            h.library.activeLibraryPath = active
            h.library.defaultLibraryPath = defaultPath
            model.refresh()
            XCTAssertEqual(model.state.isDefaultLibrary, expected)
        }
    }

    func testAlreadyActiveFolderIsNoOpSuccessForEachNormalizedSpelling() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/active")
        let model = h.makeModel()
        let accesses = h.files.accessCount
        var changes = 0
        model.onChange = { changes += 1 }

        for path in ["/active", "/active/", "//active///", "/./active/.", "/other/../active", "/../../active"] {
            model.chooseFolder(path)
            XCTAssertEqual(model.state.activeLibraryPath, "/active")
            XCTAssertNil(model.state.lastSwitchMessage)
        }
        XCTAssertTrue(h.library.switches.isEmpty)
        XCTAssertEqual(h.files.accessCount, accesses)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(h.settings.libraryFolderPath, "/active")

        h.library.outcome = .deliveryInFlight
        model.chooseFolder("/other")
        XCTAssertEqual(changes, 1)
        model.chooseFolder("/active/.")
        XCTAssertEqual(changes, 2)
        XCTAssertNil(model.state.lastSwitchMessage)
        XCTAssertEqual(h.library.switches.count, 1)
    }

    func testReChoosingAnUnsavedActiveFolderRetriesThroughComposition() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/saved")
        let model = h.makeModel()

        // A→B whose startup failed leaves B running but unsaved. Choosing B
        // again must restart it through composition, never save it directly.
        h.library.outcome = .libraryUnavailable(.ioFailure)
        model.chooseFolder("/b")
        model.chooseFolder("/b/")
        XCTAssertEqual(h.library.switches, ["/b", "/b/"])
        XCTAssertEqual(h.settings.libraryFolderPath, "/saved")
        XCTAssertEqual(model.state.lastSwitchMessage, .libraryUnavailable(.ioFailure))

        h.library.outcome = .switched
        model.chooseFolder("/b")
        XCTAssertEqual(h.library.switches.count, 3)
        XCTAssertEqual(h.settings.libraryFolderPath, "/b")
        XCTAssertNil(model.state.lastSwitchMessage)

        // Once saved, the running folder is a no-op again.
        model.chooseFolder("/b")
        XCTAssertEqual(h.library.switches.count, 3)
    }

    func testChoosingTheDefaultPathSelectsTheDefaultByIntent() {
        let h = GeneralSettingsHarness()
        h.settings.setLibraryFolder("/active")
        let model = h.makeModel()

        // Both platforms then apply their default rules (creation, symlink).
        model.chooseFolder("/default/")
        XCTAssertEqual(h.library.switches, [nil])
        XCTAssertNil(h.settings.libraryFolderPath)
        XCTAssertTrue(model.state.isDefaultLibrary)

        model.chooseFolder("/default")
        XCTAssertEqual(h.library.switches, [nil])
    }

    func testCanonicalUnicodeTwinsAndCaseChangesAreSwitchesWithOriginalSpelling() {
        let h = GeneralSettingsHarness()
        h.library.activeLibraryPath = "/café"
        let model = h.makeModel()
        var changes = 0
        model.onChange = { changes += 1 }
        for path in ["/cafe\u{301}", "/Café", "/café", "/literal/../spelling"] {
            model.chooseFolder(path)
            XCTAssertEqual(Array(model.state.activeLibraryPath.utf8), Array(path.utf8))
            XCTAssertEqual((h.library.switches.last ?? nil).map { Array($0.utf8) }, Array(path.utf8))
        }
        XCTAssertEqual(h.library.switches.count, 4)
        XCTAssertEqual(changes, 4)
    }

    func testInvalidPathSpellingCannotTriggerANormalizedNoOp() {
        let h = GeneralSettingsHarness()
        let model = h.makeModel()
        h.library.outcome = .invalidTarget(.notAbsolute)
        model.chooseFolder("active")
        h.library.outcome = .invalidTarget(.rejectedByStore(.invalidRoot))
        model.chooseFolder("/bad\n/../active")
        XCTAssertEqual(h.library.switches.count, 2)
        XCTAssertEqual(model.state.activeLibraryPath, "/active")
        XCTAssertEqual(model.state.lastSwitchMessage, .invalidTarget(.rejectedByStore(.invalidRoot)))
    }

    func testDefaultIntentForwardsNilAndClearsExplicitChoiceEvenWhenAlreadyDefault() {
        let h = GeneralSettingsHarness()
        h.library.activeLibraryPath = h.library.defaultLibraryPath
        h.settings.setLibraryFolder(h.library.defaultLibraryPath)
        let model = h.makeModel()
        var changes = 0
        model.onChange = { changes += 1 }

        model.useDefaultFolder()
        XCTAssertEqual(h.library.switches.count, 1)
        XCTAssertNil(h.library.switches[0])
        XCTAssertNil(h.settings.libraryFolderPath)
        XCTAssertTrue(model.state.isDefaultLibrary)
        XCTAssertEqual(changes, 0, "Changing only the saved marker leaves General state unchanged")

        model.chooseFolder("/other")
        model.useDefaultFolder()
        XCTAssertEqual(model.state.activeLibraryPath, "/default")
        XCTAssertTrue(model.state.isDefaultLibrary)
        XCTAssertNil(model.state.lastSwitchMessage)
        XCTAssertEqual(changes, 2)
    }

    func testReadOnlyErrorsAreVisibleAtInitializationAndAfterSettingsNotSaved() throws {
        for (source, expected) in [(#"{"version":2}"#, SettingsError.futureVersion(2)),
                                   (#"{"version":0}"#, .unsupportedVersion(0)), ("corrupt", .corruptFile)] {
            let h = GeneralSettingsHarness()
            try h.files.put(source, at: "settings.json")
            h.settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: h.files)))
            h.library.settings = h.settings
            h.library.outcome = .settingsNotSaved(expected)
            let model = h.makeModel()
            XCTAssertTrue(model.state.isReadOnly)
            XCTAssertEqual(model.state.settingsError, expected)
            model.chooseFolder("/chosen")
            XCTAssertEqual(model.state.activeLibraryPath, "/chosen")
            XCTAssertTrue(model.state.isReadOnly)
            XCTAssertEqual(model.state.lastSwitchMessage, .settingsNotSaved(expected))
            model.refresh()
            XCTAssertEqual(model.state.settingsError, expected)
            XCTAssertEqual(try h.files.text(at: "settings.json"), source)
        }
    }

    func testReadOnlyTransitionInSharedSettingsUpdatesGeneralWithoutReplacingViewHook() throws {
        let h = GeneralSettingsHarness()
        let model = h.makeModel()
        var settingsChanges = 0
        var generalChanges = 0
        h.settings.onChange = { settingsChanges += 1 }
        model.onChange = { generalChanges += 1 }
        try h.files.put(#"{"version":2}"#, at: "settings.json")
        h.settings.markSeedsOffered()

        XCTAssertTrue(model.state.isReadOnly)
        XCTAssertEqual(model.state.settingsError, .futureVersion(2))
        XCTAssertEqual(settingsChanges, 1)
        XCTAssertEqual(generalChanges, 1)
        model.refresh()
        XCTAssertEqual(settingsChanges, 2)
        XCTAssertEqual(generalChanges, 1)
    }

    func testRefreshUpdatesGraphAndSettingsButNotifiesOnlyForVisibleChanges() throws {
        let h = GeneralSettingsHarness()
        let model = h.makeModel()
        var changes = 0
        model.onChange = { changes += 1 }
        model.refresh()
        h.settings.markSetupPresented()
        XCTAssertEqual(changes, 0, "First-run progress is not General state")

        h.library.activeLibraryPath = "/external"
        model.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.state.activeLibraryPath, "/external")
        model.refresh()
        XCTAssertEqual(changes, 1)
        h.files.failNextWrite = true
        h.settings.markSeedsOffered()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
        model.refresh()
        XCTAssertEqual(changes, 3)
        XCTAssertNil(model.state.settingsError)
    }

    func testRepeatedRefusalAndRevealDoNotNotifyAndSuccessClearsTheMessage() {
        let h = GeneralSettingsHarness()
        let model = h.makeModel()
        var changes = 0
        model.onChange = { changes += 1 }
        h.library.outcome = .invalidTarget(.missing)
        model.chooseFolder("/missing")
        model.chooseFolder("/another-missing")
        model.refresh()
        model.revealFolder()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(h.library.reveals, 1)
        XCTAssertEqual(h.library.revealedPaths, ["/active"])

        h.library.outcome = .switched
        model.chooseFolder("/chosen")
        XCTAssertEqual(changes, 2)
        XCTAssertNil(model.state.lastSwitchMessage)
        model.revealFolder()
        XCTAssertEqual(h.library.revealedPaths, ["/active", "/chosen"])
        XCTAssertEqual(changes, 2)
    }

    func testRefreshReflectsAnotherCompositionDriversUnavailableSwitch() {
        let h = GeneralSettingsHarness()
        let model = h.makeModel()
        h.library.outcome = .libraryUnavailable(.ioFailure)
        var changes = 0
        model.onChange = { changes += 1 }
        h.main.run {
            XCTAssertEqual(h.library.switchLibrary(to: "/external"), .libraryUnavailable(.ioFailure))
        }
        XCTAssertEqual(model.state.activeLibraryPath, "/active")
        XCTAssertEqual(changes, 0, "Failed startup produces no settings event")
        model.refresh()
        XCTAssertEqual(model.state.activeLibraryPath, "/external")
        XCTAssertEqual(changes, 1)
    }

    func testStateAndPortCallsUseInjectedMainThreadUnderBothSchedulingModes() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = GeneralSettingsHarness()
            h.main.mode = mode
            let model = h.makeModel()
            var changes = 0
            model.onChange = {
                XCTAssertTrue(h.main.isRunning)
                changes += 1
            }
            model.chooseFolder("/chosen")
            if mode == .deferred {
                XCTAssertEqual(changes, 0)
                XCTAssertTrue(h.library.switches.isEmpty)
                XCTAssertEqual(model.state.activeLibraryPath, "/active")
            }
            h.main.drain()
            XCTAssertEqual(changes, 1)
            XCTAssertEqual(model.state.activeLibraryPath, "/chosen")

            h.settings.setLibraryFolder("relative")
            if mode == .deferred { XCTAssertNil(model.state.settingsError) }
            h.main.drain()
            XCTAssertEqual(model.state.settingsError, .invalidLibraryFolder)
            XCTAssertEqual(changes, 2)
            model.refresh()
            h.main.drain()
            XCTAssertNil(model.state.settingsError)
            XCTAssertEqual(changes, 3)
            model.useDefaultFolder()
            model.revealFolder()
            h.main.drain()
            XCTAssertTrue(model.state.isDefaultLibrary)
            XCTAssertEqual(changes, 4)
            XCTAssertEqual(h.library.reveals, 1)
        }
    }

    func testMultipleModelsObserveIndependentlyAndAreReleased() {
        let h = GeneralSettingsHarness()
        var first: GeneralSettingsModel? = h.makeModel()
        var second: GeneralSettingsModel? = h.makeModel()
        weak var released = first
        var firstChanges = 0
        var secondChanges = 0
        first?.onChange = { firstChanges += 1 }
        second?.onChange = { secondChanges += 1 }
        h.settings.setLibraryFolder("relative")
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)
        first = nil
        XCTAssertNil(released)
        h.settings.refresh()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 2)
        released = second
        second = nil
        XCTAssertNil(released)
        h.settings.setLibraryFolder("/another")
        XCTAssertEqual(secondChanges, 2)
    }

    func testQueuedMutationAndRevealIntentsSurviveModelRelease() {
        let cases: [(intent: (GeneralSettingsModel) -> Void, active: String, saved: String?, reveals: Int)] = [
            ({ $0.chooseFolder("/chosen") }, "/chosen", "/chosen", 0),
            ({ $0.useDefaultFolder() }, "/default", nil, 0),
            ({ $0.revealFolder() }, "/active", "/saved", 1)
        ]
        for item in cases {
            let h = GeneralSettingsHarness()
            h.settings.setLibraryFolder("/saved")
            h.main.mode = .deferred
            var model: GeneralSettingsModel? = h.makeModel()
            weak var released = model
            item.intent(model!)
            model = nil
            XCTAssertTrue(h.library.switches.isEmpty)
            XCTAssertEqual(h.library.reveals, 0)
            h.main.drain()

            XCTAssertEqual(h.library.activeLibraryPath, item.active)
            XCTAssertEqual(h.settings.libraryFolderPath, item.saved)
            XCTAssertEqual(h.library.reveals, item.reveals)
            XCTAssertEqual(h.library.switches.count, item.reveals == 0 ? 1 : 0)
            XCTAssertNil(released, "The queued intent releases the model once it runs")
        }
    }

    func testStringsAndTypedDiagnosticsCarryNoPathsContentOrErrorBodies() throws {
        let h = GeneralSettingsHarness()
        let sensitive = ["/private/secret-library", "PROMPT_SECRET_BODY", "FIELD_SECRET_VALUE"]
        h.library.activeLibraryPath = sensitive[0]
        let model = h.makeModel()
        let outcomes: [LibrarySwitchOutcome] = [
            .switched, .deliveryInFlight, .invalidTarget(.notAbsolute), .invalidTarget(.missing),
            .invalidTarget(.notDirectory), .invalidTarget(.unreadable), .invalidTarget(.symlink)
        ] + allFileErrors.flatMap { [.invalidTarget(.rejectedByStore($0)), .libraryUnavailable($0)] }
            + allSettingsErrors.map { .settingsNotSaved($0) }

        // The model has no logger. Exercise the boundary then log only its typed
        // diagnostics through the real formatter, captured without global stderr.
        let pipe = Pipe()
        let log = StandardErrorLog(output: pipe.fileHandleForWriting)
        for (index, outcome) in outcomes.enumerated() {
            h.library.outcome = outcome
            model.chooseFolder("/private/" + sensitive[1] + "/" + sensitive[2] + "/\(index)")
            let diagnostic = String(describing: outcome)
            let text = GeneralSettingsStrings.message(for: outcome) ?? ""
            XCTAssertFalse(text.contains("\u{2014}"))
            for value in sensitive {
                XCTAssertFalse(diagnostic.contains(value))
                XCTAssertFalse(text.contains(value))
            }
            log.write(.warning, diagnostic)
        }
        try pipe.fileHandleForWriting.close()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for value in sensitive { XCTAssertFalse(lines.contains(value)) }
        for error in allSettingsErrors {
            let text = GeneralSettingsStrings.settingsError(error)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("\u{2014}"))
        }
    }

    private var allFileErrors: [FileStoreError] {
        [.invalidPath, .outsideRoot, .invalidRoot, .notFound, .notRegularFile, .alreadyExists, .ioFailure]
    }

    private var allSettingsErrors: [SettingsError] {
        [.futureVersion(2), .unsupportedVersion(0), .corruptFile, .invalidLibraryFolder]
            + allFileErrors.flatMap { [.readFailed($0), .writeFailed($0)] }
    }
}

private final class GeneralSettingsHarness {
    let files = MemoryFileStore()
    let main = FakeMainThread()
    var settings: SettingsModel
    let library: FakeLibraryLocationControl

    init() {
        settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
        library = FakeLibraryLocationControl(settings: settings, files: files, main: main)
    }

    func makeModel() -> GeneralSettingsModel {
        GeneralSettingsModel(settings: settings, library: library, mainThread: main)
    }
}

private final class FakeLibraryLocationControl: LibraryLocationControl {
    var activeLibraryPath = "/active"
    var defaultLibraryPath = "/default"
    var outcome = LibrarySwitchOutcome.switched
    var settings: SettingsModel
    private let files: MemoryFileStore
    private let main: FakeMainThread
    private(set) var switches: [String?] = []
    private(set) var reveals = 0
    private(set) var revealedPaths: [String] = []

    init(settings: SettingsModel, files: MemoryFileStore, main: FakeMainThread) {
        self.settings = settings
        self.files = files
        self.main = main
    }

    func switchLibrary(to path: String?) -> LibrarySwitchOutcome {
        XCTAssertTrue(main.isRunning)
        switches.append(path)
        switch outcome {
        case .invalidTarget, .deliveryInFlight: return outcome
        case .libraryUnavailable: activeLibraryPath = path ?? defaultLibraryPath
        case .switched, .settingsNotSaved:
            activeLibraryPath = path ?? defaultLibraryPath
            if case .settingsNotSaved = outcome { files.failNextWrite = true }
            if let path { settings.setLibraryFolder(path) }
            else { settings.clearLibraryFolder() }
        }
        return outcome
    }

    func revealLibrary() {
        XCTAssertTrue(main.isRunning)
        reveals += 1
        revealedPaths.append(activeLibraryPath)
    }
}
