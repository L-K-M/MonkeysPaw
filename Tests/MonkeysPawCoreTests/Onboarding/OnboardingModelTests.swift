import Foundation
import XCTest
@testable import MonkeysPawCore

final class OnboardingModelTests: XCTestCase {
    func testFreshInstallPresentsSetupFolderSeedsTourThenCompletesOnce() throws {
        let h = OnboardingHarness()
        let model = h.makeModel()
        var steps: [OnboardingModel.Step] = []
        model.onChange = { steps.append(model.state.step) }
        XCTAssertEqual(model.state.step, .setup)
        model.useDefaultFolder()
        model.acceptSeeds()
        XCTAssertFalse(h.settings.firstRun.libraryFolderCompleted)
        XCTAssertFalse(h.settings.firstRun.seedsOffered)
        XCTAssertTrue(h.location.switches.isEmpty)

        model.markSetupPresented()
        XCTAssertEqual(model.state.step, .libraryFolder)
        model.useDefaultFolder()
        XCTAssertEqual(h.location.switches.count, 1)
        XCTAssertNil(h.location.switches[0])
        XCTAssertNil(h.settings.libraryFolderPath)
        XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
        XCTAssertEqual(model.state.step, .seedOffer)
        h.location.graph.files.onCreate = { _ in
            let reopened = SettingsService(store: SettingsStore(files: h.settingsFiles))
            XCTAssertTrue(reopened.snapshot.document.firstRun.seedsOffered,
                          "The offer must be on disk before the first create")
        }
        model.acceptSeeds()
        model.acceptSeeds()
        model.declineSeeds()
        model.refresh()
        XCTAssertEqual(model.state.step, .tour)
        XCTAssertEqual(model.state.seedSummary,
            SeedSummary(seededCount: SeedCatalog.prompts.count, skippedExistingCount: 0))
        XCTAssertNil(model.state.seedFailure)
        XCTAssertTrue(h.settings.firstRun.seedsOffered)
        XCTAssertEqual(h.copies, 1)
        XCTAssertEqual(try h.location.graph.library.entries().count, SeedCatalog.prompts.count)
        model.completeTour()
        model.completeTour()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertTrue(h.settings.firstRun.tourCompleted)
        XCTAssertEqual(h.restart().makeModel().state.step, .complete)
        XCTAssertEqual(steps, [.libraryFolder, .seedOffer, .tour, .complete])
    }

    func testLegacySetupFactLeavesFolderPendingAndPersistsWithItsCompletion() {
        let h = OnboardingHarness(legacy: .setupPresented)
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .libraryFolder)
        XCTAssertTrue(h.settings.firstRun.setupPresented)
        XCTAssertFalse(h.settings.firstRun.libraryFolderCompleted)
        model.useDefaultFolder()
        XCTAssertEqual(model.state.step, .seedOffer)
        let reopened = h.restart()
        XCTAssertTrue(reopened.settings.firstRun.setupPresented)
        XCTAssertTrue(reopened.settings.firstRun.libraryFolderCompleted)
        XCTAssertEqual(reopened.makeModel().state.step, .seedOffer)
    }

    func testChoosingFolderCompletesOnlyForSuccessfulSwitchAndReportsEveryOutcome() {
        let outcomes: [LibrarySwitchOutcome] = [
            .switched, .settingsNotSaved(.writeFailed(.ioFailure)), .deliveryInFlight,
            .repeatInvalidationFailed,
            .invalidTarget(.notAbsolute), .invalidTarget(.missing), .invalidTarget(.notDirectory),
            .invalidTarget(.unreadable), .invalidTarget(.symlink),
            .invalidTarget(.rejectedByStore(.invalidRoot)), .libraryUnavailable(.ioFailure)
        ]
        for outcome in outcomes {
            let h = OnboardingHarness(legacy: .setupPresented)
            h.location.outcome = outcome
            let model = h.makeModel()
            model.chooseFolder("/chosen")
            XCTAssertEqual(h.location.switches, ["/chosen"])
            XCTAssertEqual(h.settings.firstRun.libraryFolderCompleted, outcome == .switched)
            XCTAssertEqual(model.state.step, outcome == .switched ? .seedOffer : .libraryFolder)
            XCTAssertEqual(model.state.lastSwitchMessage, outcome == .switched ? nil : outcome)
            switch outcome {
            case .switched:
                XCTAssertEqual(h.settings.libraryFolderPath, "/chosen")
                XCTAssertNil(model.state.settingsError)
            case .settingsNotSaved(let error):
                XCTAssertEqual(model.state.settingsError, error)
                XCTAssertNil(h.settings.libraryFolderPath)
            default: XCTAssertNil(h.settings.libraryFolderPath)
            }
        }
    }

    func testSavedAlreadyActiveHealthyFolderCompletesWithoutReplacingGraph() {
        let h = OnboardingHarness(legacy: .setupPresented)
        let model = h.makeModel()
        model.chooseFolder("//default/unused/.././")
        XCTAssertTrue(h.location.switches.isEmpty)
        XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
        XCTAssertEqual(model.state.step, .seedOffer)
    }

    func testUnavailableAlreadyActiveFolderRetriesThroughCompositionIncludingDefaultIntent() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = OnboardingHarness(legacy: .setupPresented, health: .unavailableAtStartup)
            h.main.mode = mode
            let model = h.makeModel()
            model.chooseFolder("//default/./")
            h.main.drain()
            XCTAssertEqual(h.location.switches.count, 1)
            XCTAssertNil(h.location.switches[0])
            XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
            XCTAssertEqual(model.state.step, .seedOffer)
            XCTAssertEqual(h.status.state, .available)
        }
    }

    func testCompletionWriteFailureLeavesFolderPendingAndAlreadyActiveRetryCompletesIt() {
        let h = OnboardingHarness(legacy: .setupPresented)
        let model = h.makeModel()
        h.settingsFiles.onWrite = { _ in
            h.settingsFiles.onWrite = nil
            h.settingsFiles.failNextWrite = true
        }
        model.chooseFolder("/chosen")
        XCTAssertEqual(h.settings.libraryFolderPath, "/chosen")
        XCTAssertFalse(h.settings.firstRun.libraryFolderCompleted)
        XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
        XCTAssertEqual(model.state.step, .libraryFolder)
        model.chooseFolder("/chosen/.")
        XCTAssertEqual(h.location.switches.count, 1)
        XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
        XCTAssertNil(model.state.settingsError)
        XCTAssertEqual(model.state.step, .seedOffer)
    }

    func testSwitchUsesNewGraphsEligibilityAndSeedDestination() throws {
        let h = OnboardingHarness(legacy: .setupPresented)
        let original = h.location.graph
        try original.files.put("Original prompt", at: "mine.md")
        let chosen = OnboardingLibraryGraph()
        h.location.install(chosen, at: "/chosen")
        let model = h.makeModel()
        model.chooseFolder("/chosen")
        XCTAssertEqual(model.state.step, .seedOffer)
        model.acceptSeeds()
        XCTAssertEqual(try chosen.library.entries().count, SeedCatalog.prompts.count)
        XCTAssertEqual(try original.files.listFiles().map(\.relativePath), ["mine.md"])
        XCTAssertEqual(try original.files.text(at: "mine.md"), "Original prompt")
    }

    func testDecliningRecordsOfferAndDoesNotCopyAcrossRestart() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        model.declineSeeds()
        XCTAssertTrue(h.settings.firstRun.seedsOffered)
        XCTAssertEqual(model.state.step, .tour)
        XCTAssertNil(model.state.seedSummary)
        XCTAssertEqual(h.copies, 0)
        let restarted = h.restart()
        let reopened = restarted.makeModel()
        reopened.acceptSeeds()
        XCTAssertEqual(reopened.state.step, .tour)
        reopened.completeTour()
        XCTAssertEqual(reopened.state.step, .complete)
        XCTAssertEqual(restarted.restart().makeModel().state.step, .complete)
        XCTAssertEqual(restarted.copies, 0)
    }

    func testFailedOfferRecordNeverCopiesAndAcceptOrDeclineCanRetry() {
        for accept in [true, false] {
            let h = OnboardingHarness()
            h.completeInitialSteps()
            let model = h.makeModel()
            h.settingsFiles.failNextWrite = true
            if accept { model.acceptSeeds() } else { model.declineSeeds() }
            XCTAssertEqual(model.state.step, .seedOffer)
            XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
            XCTAssertFalse(h.settings.firstRun.seedsOffered)
            XCTAssertEqual(h.copies, 0)
            XCTAssertFalse(h.restart().settings.firstRun.seedsOffered)
            if accept { model.acceptSeeds() } else { model.declineSeeds() }
            XCTAssertTrue(h.settings.firstRun.seedsOffered)
            XCTAssertEqual(model.state.step, .tour)
            XCTAssertNil(model.state.settingsError)
            XCTAssertEqual(h.copies, accept ? 1 : 0)
        }
    }

    func testExistingEligiblePromptsIncludingMalformedOnesSuppressOfferWithoutConsumingFlag() throws {
        for path in ["mine.md", "nested/README.md", ".prompt.md"] {
            let h = OnboardingHarness()
            try h.location.graph.files.write(Data([0xff]), at: path)
            h.completeInitialSteps()
            let model = h.makeModel()
            XCTAssertEqual(model.state.step, .tour)
            XCTAssertFalse(h.settings.firstRun.seedsOffered)
            model.acceptSeeds()
            XCTAssertEqual(h.copies, 0)
        }
    }

    func testIgnoredFilesLeaveOfferEligible() throws {
        let h = OnboardingHarness()
        for path in ["README.md", ".DS_Store", "notes.txt", "_private.md", "_drafts/a.md", ".git/a.md"] {
            try h.location.graph.files.put("Keep", at: path)
        }
        h.completeInitialSteps()
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .seedOffer)
        model.acceptSeeds()
        XCTAssertEqual(model.state.seedSummary?.seededCount, SeedCatalog.prompts.count)
        XCTAssertEqual(try h.location.graph.files.text(at: "README.md"), "Keep")
    }

    func testRecoveryFolderIntentClearsAnEarlierSeedResult() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        model.acceptSeeds()
        XCTAssertNotNil(model.state.seedSummary)

        // A later recovery step must not keep showing the first-run result.
        h.status.update(.unavailableAtStartup)
        XCTAssertEqual(model.state.step, .libraryFolder)
        model.useDefaultFolder()
        XCTAssertNil(model.state.seedSummary)
        XCTAssertNil(model.state.seedFailure)
    }

    func testSeedSummaryCopyUsesSingularForOne() {
        XCTAssertEqual(OnboardingStrings.seedSummary(SeedSummary(seededCount: 1, skippedExistingCount: 1)),
            "You added 1 starter prompt and skipped 1 occupied destination.")
        XCTAssertEqual(OnboardingStrings.seedSummary(SeedSummary(seededCount: 2, skippedExistingCount: 0)),
            "You added 2 starter prompts and skipped 0 occupied destinations.")
    }

    func testPromptArrivingAfterOfferMakesSeedServiceSkipAllCopying() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        try h.location.graph.files.put("External prompt", at: "mine.md")
        model.acceptSeeds()
        XCTAssertEqual(model.state.seedSummary, SeedSummary(seededCount: 0, skippedExistingCount: 0))
        XCTAssertTrue(h.settings.firstRun.seedsOffered)
        XCTAssertEqual(h.copies, 1)
        XCTAssertEqual(try h.location.graph.files.listFiles().map(\.relativePath), ["mine.md"])
        XCTAssertEqual(try h.location.graph.files.text(at: "mine.md"), "External prompt")
    }

    func testOccupiedDestinationIsReportedAsSkippedWithoutReplacement() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        let path = try XCTUnwrap(SeedCatalog.prompts.first?.relativePath)
        h.location.graph.files.onCreate = { candidate in
            XCTAssertEqual(candidate, path)
            h.location.graph.files.onCreate = nil
            try h.location.graph.files.put("External prompt", at: candidate)
        }
        model.acceptSeeds()
        XCTAssertEqual(model.state.seedSummary,
            SeedSummary(seededCount: SeedCatalog.prompts.count - 1, skippedExistingCount: 1))
        XCTAssertEqual(try h.location.graph.files.text(at: path), "External prompt")
    }

    func testPartialOrEarlyCopyFailureKeepsOfferRecordedAndNeverRepeatsOnRestart() throws {
        for failedCreate in [1, 2] {
            let h = OnboardingHarness()
            h.completeInitialSteps()
            let model = h.makeModel()
            var creates = 0
            h.location.graph.files.onCreate = { _ in
                creates += 1
                if creates == failedCreate { throw FileStoreError.ioFailure }
            }
            model.acceptSeeds()
            XCTAssertTrue(h.settings.firstRun.seedsOffered)
            XCTAssertEqual(model.state.step, .tour)
            XCTAssertEqual(model.state.seedFailure, .fileStore(.ioFailure))
            XCTAssertNil(model.state.seedSummary)
            let paths = try h.location.graph.files.listFiles().map(\.relativePath)
            XCTAssertEqual(paths.count, failedCreate - 1)
            h.location.graph.files.onCreate = nil
            let restarted = h.restart()
            let reopened = restarted.makeModel()
            reopened.acceptSeeds()
            reopened.refresh()
            XCTAssertEqual(reopened.state.step, .tour)
            XCTAssertEqual(restarted.copies, 0)
            XCTAssertEqual(try restarted.location.graph.files.listFiles().map(\.relativePath), paths)
        }
    }

    func testRestartResumesAtFirstIncompleteStep() {
        let initial = OnboardingHarness()
        XCTAssertEqual(initial.makeModel().state.step, .setup)
        initial.makeModel().markSetupPresented()
        let afterSetup = initial.restart()
        XCTAssertEqual(afterSetup.makeModel().state.step, .libraryFolder)
        afterSetup.makeModel().useDefaultFolder()
        let afterFolder = afterSetup.restart()
        XCTAssertEqual(afterFolder.makeModel().state.step, .seedOffer)
        XCTAssertEqual(afterFolder.copies, 0)
        afterFolder.makeModel().declineSeeds()
        let afterSeeds = afterFolder.restart()
        let tour = afterSeeds.makeModel()
        XCTAssertEqual(tour.state.step, .tour)
        tour.completeTour()
        XCTAssertEqual(afterSeeds.restart().makeModel().state.step, .complete)
    }

    func testReadOnlySettingsSuppressEveryStepAndKeepErrorVisibleIncludingRecovery() throws {
        for (source, error) in [("corrupt", SettingsError.corruptFile),
                                (#"{"version":2}"#, .futureVersion(2)),
                                (#"{"version":0}"#, .unsupportedVersion(0))] {
            let files = MemoryFileStore()
            try files.put(source, at: "settings.json")
            let h = OnboardingHarness(settingsFiles: files, health: .unavailableAtStartup)
            let model = h.makeModel()
            let accesses = files.accessCount
            model.markSetupPresented()
            model.useDefaultFolder()
            model.chooseFolder("/chosen")
            model.acceptSeeds()
            model.declineSeeds()
            model.completeTour()
            model.refresh()
            XCTAssertEqual(model.state.step, .complete)
            XCTAssertTrue(model.state.isReadOnly)
            XCTAssertEqual(model.state.settingsError, error)
            XCTAssertTrue(h.location.switches.isEmpty)
            XCTAssertEqual(h.emptinessChecks, 0)
            XCTAssertEqual(h.copies, 0)
            XCTAssertEqual(files.accessCount, accesses)
            XCTAssertEqual(try files.text(at: "settings.json"), source)
            XCTAssertEqual(h.notifier.requests, 1)
        }
    }

    func testBecomingReadOnlyWhileRecordingOfferSkipsCopyAndSurfacesSettingsError() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        try h.settingsFiles.put(#"{"version":2}"#, at: "settings.json")
        model.acceptSeeds()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertEqual(model.state.settingsError, .futureVersion(2))
        XCTAssertTrue(model.state.isReadOnly)
        XCTAssertEqual(h.copies, 0)
        XCTAssertEqual(try h.settingsFiles.text(at: "settings.json"), #"{"version":2}"#)
    }

    func testStartupUnavailabilityNotifiesOnceAndReopensCompletedFolderWithoutResettingFlag() throws {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let saved = OnboardingHarness()
            saved.completeInitialSteps()
            saved.settings.markSeedsOffered()
            let previous = try saved.settingsFiles.read(at: "settings.json")
            let h = OnboardingHarness(settingsFiles: saved.settingsFiles, health: .unavailableAtStartup)
            h.main.mode = mode
            let model = h.makeModel()
            h.status.update(.unavailableAtStartup)
            h.main.drain()
            XCTAssertEqual(h.notifier.requests, 1)
            XCTAssertEqual(model.state.step, .libraryFolder)
            XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
            XCTAssertEqual(try h.settingsFiles.read(at: "settings.json"), previous)
            h.location.outcome = .settingsNotSaved(.writeFailed(.ioFailure))
            model.chooseFolder("/chosen")
            h.main.drain()
            XCTAssertEqual(h.status.state, .available)
            XCTAssertEqual(model.state.step, .libraryFolder, "Recovery awaits durable acceptance")
            h.location.outcome = .switched
            model.chooseFolder("/chosen")
            h.main.drain()
            XCTAssertEqual(model.state.step, .complete)
            XCTAssertEqual(h.notifier.requests, 1)
            XCTAssertEqual(h.copies, 0)
            XCTAssertTrue(h.settings.firstRun.libraryFolderCompleted)
            XCTAssertFalse(h.settings.firstRun.tourCompleted, "Recovery does not consume a pending tour")
            XCTAssertEqual(h.restart().makeModel().state.step, .tour)
        }
    }

    func testRuntimeLossChangesHealthOnlyWithoutNotificationFolderReopenOrFlagWrites() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.settings.markSeedsOffered()
        let model = h.makeModel()
        let previous = try h.settingsFiles.read(at: "settings.json")
        h.status.update(.lostWhileRunning)
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertEqual(model.state.libraryStatus, .lostWhileRunning)
        XCTAssertEqual(h.status.menuLabel, "Library unavailable")
        XCTAssertEqual(h.notifier.requests, 0)
        model.useDefaultFolder()
        model.chooseFolder("/chosen")
        h.status.update(.available)
        XCTAssertEqual(h.status.state, .lostWhileRunning)
        XCTAssertTrue(h.location.switches.isEmpty)
        XCTAssertEqual(try h.settingsFiles.read(at: "settings.json"), previous)
    }

    func testRuntimeLossDuringSeedOfferPreventsCopyWithoutRecordingOffer() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        let model = h.makeModel()
        h.status.update(.lostWhileRunning)
        model.acceptSeeds()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertFalse(h.settings.firstRun.seedsOffered)
        XCTAssertEqual(h.copies, 0)
        XCTAssertEqual(h.notifier.requests, 0)
    }

    func testSyncPredicateSuppressesOfferAndIsRecheckedBeforeAccepting() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.serverConfigured = true
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .tour)
        XCTAssertEqual(h.emptinessChecks, 0)
        h.serverConfigured = false
        model.refresh()
        XCTAssertEqual(model.state.step, .seedOffer)
        h.serverConfigured = true
        model.acceptSeeds()
        XCTAssertEqual(model.state.step, .tour)
        XCTAssertFalse(h.settings.firstRun.seedsOffered)
        XCTAssertEqual(h.copies, 0)
    }

    func testEligibilityFailureIsSanitizedAndRefreshCanOfferAfterRecovery() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.emptinessFailure = NSError(domain: "/sensitive/library PROMPT_SECRET FIELD_SECRET", code: 1)
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertEqual(model.state.seedFailure, .library(.operationFailed))
        XCTAssertFalse(h.settings.firstRun.seedsOffered)
        h.emptinessFailure = nil
        model.refresh()
        XCTAssertEqual(model.state.step, .seedOffer)
        XCTAssertNil(model.state.seedFailure)
    }

    func testCopyFailuresPreserveKnownTypesAndSanitizeUnknownErrorsAndStrings() throws {
        let marker = "/sensitive/library PROMPT_SECRET FIELD_SECRET"
        let failures: [(Error, SeedFailure)] = [
            (FileStoreError.ioFailure, .fileStore(.ioFailure)),
            (LibraryError.keyedStateConflict, .library(.keyedStateConflict)),
            (PromptWriteError.invalidPrompt, .promptWrite(.invalidPrompt)),
            (PromptWriteError.unsupportedFormat(try XCTUnwrap(PromptFormatVersion(2))),
                .promptWrite(.unsupportedFormat(try XCTUnwrap(PromptFormatVersion(2))))),
            (ULIDGenerationError.invalidEntropyLength, .identity(.invalidEntropyLength)),
            (NSError(domain: marker, code: 1, userInfo: [NSLocalizedDescriptionKey: marker]),
                .library(.operationFailed))
        ]
        for (failure, expected) in failures {
            let h = OnboardingHarness()
            h.completeInitialSteps()
            h.copyFailure = failure
            let model = h.makeModel()
            model.acceptSeeds()
            XCTAssertEqual(model.state.seedFailure, expected)
            XCTAssertTrue(h.settings.firstRun.seedsOffered)
            let diagnostic = String(describing: model.state.seedFailure)
            let copy = OnboardingStrings.seedFailure(expected)
            XCTAssertFalse(diagnostic.contains(marker))
            XCTAssertFalse(copy.contains(marker))
            XCTAssertFalse(copy.contains("\u{2014}"))
        }
        let copy = [OnboardingStrings.libraryFolderTitle, OnboardingStrings.libraryFolderHelp,
            OnboardingStrings.seedOfferTitle, OnboardingStrings.seedOfferHelp,
            OnboardingStrings.libraryUnavailableNotificationTitle,
            OnboardingStrings.libraryUnavailableNotificationBody, OnboardingStrings.restartForLibrary,
            OnboardingStrings.seedSummary(SeedSummary(seededCount: 7, skippedExistingCount: 3))]
        for value in copy {
            XCTAssertFalse(value.contains("\u{2014}"))
            XCTAssertFalse(value.contains("/"))
            XCTAssertFalse(value.contains(marker))
        }
        XCTAssertTrue(copy.last?.contains("7") == true)
        XCTAssertTrue(copy.last?.contains("3") == true)
    }

    func testSettingsAndStatusSubscriptionsStayIndependentAndReleaseWithModels() {
        let h = OnboardingHarness()
        var first: OnboardingModel? = h.makeModel()
        var second: OnboardingModel? = h.makeModel()
        weak var released = first
        var firstChanges = 0
        var secondChanges = 0
        var settingsViewChanges = 0
        var statusMenuChanges = 0
        first?.onChange = { firstChanges += 1 }
        second?.onChange = { secondChanges += 1 }
        h.settings.onChange = { settingsViewChanges += 1 }
        let menuToken = h.status.addObserver { _ in statusMenuChanges += 1 }
        h.settings.markSetupPresented()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)
        XCTAssertEqual(settingsViewChanges, 1)
        first = nil
        XCTAssertNil(released)
        h.status.update(.unavailableAtStartup)
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 2)
        XCTAssertEqual(statusMenuChanges, 1)
        h.status.removeObserver(menuToken)
        released = second
        second = nil
        XCTAssertNil(released)
        h.status.update(.available)
        XCTAssertEqual(secondChanges, 2)
        XCTAssertEqual(statusMenuChanges, 1)
    }

    func testStateServiceCallsAndCallbacksUseMainThreadInInlineAndQueuedModes() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = OnboardingHarness()
            h.main.mode = mode
            let model = h.makeModel()
            var changes = 0
            model.onChange = {
                XCTAssertTrue(h.main.isRunning)
                changes += 1
            }
            model.markSetupPresented()
            if mode == .deferred {
                XCTAssertEqual(model.state.step, .setup)
                XCTAssertFalse(h.settings.firstRun.setupPresented)
            }
            h.main.drain()
            XCTAssertEqual(model.state.step, .libraryFolder)
            model.useDefaultFolder()
            if mode == .deferred { XCTAssertTrue(h.location.switches.isEmpty) }
            h.main.drain()
            XCTAssertEqual(model.state.step, .seedOffer)
            model.acceptSeeds()
            model.acceptSeeds()
            if mode == .deferred { XCTAssertEqual(h.copies, 0) }
            h.main.drain()
            XCTAssertEqual(h.copies, 1)
            XCTAssertEqual(model.state.step, .tour)
            model.completeTour()
            model.completeTour()
            if mode == .deferred {
                XCTAssertFalse(h.settings.firstRun.tourCompleted)
                XCTAssertEqual(model.state.step, .tour)
            }
            h.main.drain()
            XCTAssertEqual(model.state.step, .complete)
            XCTAssertEqual(changes, 4)
            h.settings.setLibraryFolder("relative")
            if mode == .deferred { XCTAssertNil(model.state.settingsError) }
            h.main.drain()
            XCTAssertEqual(model.state.settingsError, .invalidLibraryFolder)
        }
    }

    func testQueuedAcceptedIntentSurvivesModelReleaseAndThenReleasesIt() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        var model: OnboardingModel? = h.makeModel()
        weak var released = model
        h.main.mode = .deferred
        model?.acceptSeeds()
        model = nil
        XCTAssertNotNil(released)
        XCTAssertEqual(h.copies, 0)
        h.main.drain()
        XCTAssertEqual(h.copies, 1)
        XCTAssertTrue(h.settings.firstRun.seedsOffered)
        XCTAssertNil(released)
    }
}
