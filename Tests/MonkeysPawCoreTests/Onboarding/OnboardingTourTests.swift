import Foundation
import XCTest
@testable import MonkeysPawCore

final class OnboardingTourTests: XCTestCase {
    func testUpgradeFromPreTourVersionOneSettingsNeverOffersTour() throws {
        for folderCompleted in [false, true] {
            for seedsOffered in [false, true] {
                let files = MemoryFileStore()
                try files.put("""
                    {"version":1,"libraryFolderPath":null,"firstRun":{"setupPresented":true,
                    "libraryFolderCompleted":\(folderCompleted),"seedsOffered":\(seedsOffered)}}
                    """, at: "settings.json")
                let h = OnboardingHarness(settingsFiles: files)
                let model = h.makeModel()
                XCTAssertTrue(h.settings.firstRun.tourCompleted)
                XCTAssertFalse(h.settings.needsTourPresentation)
                model.useDefaultFolder()
                model.declineSeeds()
                model.completeTour()
                XCTAssertEqual(model.state.step, .complete)
                XCTAssertEqual(h.restart().makeModel().state.step, .complete)
                XCTAssertEqual(h.copies, 0)
            }
        }
    }

    func testTourWriteFailureKeepsDiskAndStepPendingUntilDurableCompletionPublishes() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.settings.markSeedsOffered()
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .tour)
        let previous = try h.settingsFiles.read(at: "settings.json")
        var steps: [OnboardingModel.Step] = []
        model.onChange = { [weak model] in
            XCTAssertTrue(h.main.isRunning)
            guard let model else { return }
            steps.append(model.state.step)
            XCTAssertEqual(h.restart().settings.firstRun.tourCompleted, model.state.step == .complete)
        }
        defer {
            model.onChange = nil
            h.settingsFiles.onWrite = nil
        }

        h.settingsFiles.failNextWrite = true
        model.completeTour()
        XCTAssertEqual(model.state.step, .tour)
        XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
        XCTAssertFalse(h.settings.firstRun.tourCompleted)
        XCTAssertEqual(try h.settingsFiles.read(at: "settings.json"), previous)
        XCTAssertEqual(h.restart().makeModel().state.step, .tour)

        h.settingsFiles.onWrite = { _ in
            XCTAssertEqual(model.state.step, .tour, "Completion cannot publish before the write")
            XCTAssertTrue(h.restart().settings.firstRun.tourCompleted)
        }
        model.completeTour()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertNil(model.state.settingsError)
        XCTAssertTrue(h.settings.firstRun.tourCompleted)
        XCTAssertEqual(h.restart().makeModel().state.step, .complete)
        XCTAssertEqual(steps, [.tour, .complete])
    }

    func testRestartMidTourResumesAfterEitherSeedDecisionAndCompletionNeverRepeats() {
        for accept in [false, true] {
            let h = OnboardingHarness()
            let model = h.makeModel()
            model.markSetupPresented()
            model.useDefaultFolder()
            if accept { model.acceptSeeds() } else { model.declineSeeds() }
            XCTAssertEqual(model.state.step, .tour)
            XCTAssertFalse(h.settings.firstRun.tourCompleted)

            let restarted = h.restart()
            let reopened = restarted.makeModel()
            XCTAssertEqual(reopened.state.step, .tour)
            reopened.acceptSeeds()
            reopened.declineSeeds()
            XCTAssertEqual(restarted.copies, 0)
            reopened.completeTour() // Closing the screen uses the same intent.
            reopened.refresh()
            XCTAssertEqual(reopened.state.step, .complete)
            XCTAssertEqual(restarted.restart().makeModel().state.step, .complete)
        }
    }

    func testNoSeedOfferGoesDirectlyFromFolderToTour() throws {
        for hasServer in [false, true] {
            let h = OnboardingHarness()
            h.serverConfigured = hasServer
            if !hasServer { try h.location.graph.files.put("Your prompt", at: "mine.md") }
            let model = h.makeModel()
            model.markSetupPresented()
            XCTAssertEqual(model.state.step, .libraryFolder)
            model.useDefaultFolder()
            XCTAssertEqual(model.state.step, .tour)
            XCTAssertFalse(h.settings.firstRun.seedsOffered)
            XCTAssertEqual(h.copies, 0)
            model.completeTour()
            model.refresh()
            XCTAssertEqual(model.state.step, .complete)
            XCTAssertTrue(h.settings.firstRun.tourCompleted)
        }
    }

    func testRecoveryWithPendingFirstRunNeverShowsTourEvenAfterSeedsAndRefresh() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = OnboardingHarness(health: .unavailableAtStartup)
            h.main.mode = mode
            let model = h.makeModel()
            var steps: [OnboardingModel.Step] = []
            model.onChange = { [weak model] in
                if let model { steps.append(model.state.step) }
            }
            model.markSetupPresented()
            h.main.drain()
            XCTAssertEqual(model.state.step, .libraryFolder)
            model.useDefaultFolder()
            h.main.drain()
            XCTAssertEqual(model.state.step, .seedOffer)
            model.declineSeeds()
            model.completeTour()
            model.refresh()
            h.main.drain()
            XCTAssertEqual(model.state.step, .complete)
            XCTAssertFalse(steps.contains(.tour))
            XCTAssertFalse(h.settings.firstRun.tourCompleted)
            XCTAssertEqual(h.status.state, .available)
        }
    }

    func testReadOnlySettingsSkipTourWithAnAvailableLibrary() throws {
        let files = MemoryFileStore()
        let source = #"{"version":2}"#
        try files.put(source, at: "settings.json")
        let h = OnboardingHarness(settingsFiles: files)
        let model = h.makeModel()
        let accesses = files.accessCount
        model.completeTour()
        model.refresh()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertTrue(model.state.isReadOnly)
        XCTAssertEqual(model.state.settingsError, .futureVersion(2))
        XCTAssertEqual(files.accessCount, accesses)
        XCTAssertEqual(try files.text(at: "settings.json"), source)
    }

    func testSettingsBecomingReadOnlyDuringTourSkipsItWithoutReplacingFile() throws {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.settings.markSeedsOffered()
        let model = h.makeModel()
        XCTAssertEqual(model.state.step, .tour)
        let source = #"{"version":2}"#
        try h.settingsFiles.put(source, at: "settings.json")
        model.completeTour()
        XCTAssertEqual(model.state.step, .complete)
        XCTAssertTrue(model.state.isReadOnly)
        XCTAssertEqual(model.state.settingsError, .futureVersion(2))
        XCTAssertEqual(try h.settingsFiles.text(at: "settings.json"), source)
    }

    func testTourCompletionBeforeEligibleStepDoesNotRecordProgress() {
        let h = OnboardingHarness()
        let model = h.makeModel()
        for step in [OnboardingModel.Step.setup, .libraryFolder, .seedOffer] {
            XCTAssertEqual(model.state.step, step)
            let accesses = h.settingsFiles.accessCount
            model.completeTour()
            XCTAssertEqual(model.state.step, step)
            XCTAssertFalse(h.settings.firstRun.tourCompleted)
            XCTAssertEqual(h.settingsFiles.accessCount, accesses)
            if step == .setup { model.markSetupPresented() }
            else if step == .libraryFolder { model.useDefaultFolder() }
        }
    }

    func testQueuedTourCompletionSurvivesModelReleaseThenReleasesIt() {
        let h = OnboardingHarness()
        h.completeInitialSteps()
        h.settings.markSeedsOffered()
        var model: OnboardingModel? = h.makeModel()
        weak var released = model
        h.main.mode = .deferred
        model?.completeTour()
        model = nil
        XCTAssertNotNil(released)
        XCTAssertFalse(h.settings.firstRun.tourCompleted)
        h.main.drain()
        XCTAssertTrue(h.settings.firstRun.tourCompleted)
        XCTAssertNil(released)
    }

    func testTourCopyCoversPickerFormAndDeliveryInHouseStyle() {
        let copy = OnboardingStrings.tourHelp
        for term in ["hotkey", "picker", "search", "form", "Tab", "Return", "Escape", "Copy", "Deliver", "clipboard"] {
            XCTAssertTrue(copy.contains(term), "Missing tour instruction: \(term)")
        }
        XCTAssertTrue(copy.contains("your"))
        for value in [OnboardingStrings.tourTitle, copy, OnboardingStrings.completeTour] {
            XCTAssertFalse(value.contains("\u{2014}"))
        }
    }
}
