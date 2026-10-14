import Foundation
import XCTest
@testable import MonkeysPawCore

final class UpdateSettingsModelTests: XCTestCase {
    func testRefreshIsPassiveAndPreferencePreservesEveryExistingSetting() async throws {
        let h = UpdateHarness()
        h.settings.setLibraryFolder("/chosen/library")
        h.settings.setLinuxDefaultPasteChord(.terminal)
        h.settings.setClipboardRestore(.previousText)
        h.settings.completeTour()
        let model = h.model()
        _ = await h.status()
        var changes = 0
        model.onChange = { XCTAssertTrue(h.main.isRunning); changes += 1 }
        model.refresh()
        _ = await h.status()
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        h.main.deferred = true
        model.setAutomaticUpdateChecks(.disabled)
        XCTAssertEqual(model.state.automaticUpdateChecks, .enabled)
        h.main.drain()
        h.main.deferred = false
        _ = await h.status()
        XCTAssertEqual(model.state.automaticUpdateChecks, .disabled)
        XCTAssertFalse(model.state.isReadOnly)
        XCTAssertNil(model.state.settingsError)
        XCTAssertEqual(h.settings.libraryFolderPath, "/chosen/library")
        XCTAssertEqual(h.settings.deliveryPreferences, DeliveryPreferences(linuxDefaultPasteChord: .terminal,
            clipboardRestore: .previousText))
        XCTAssertTrue(h.settings.firstRun.tourCompleted)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: h.settingsFiles)).snapshot.document.automaticUpdateChecks,
                       .disabled)
        XCTAssertGreaterThan(changes, 0)
    }

    func testFailedPreferenceWritePublishesCommittedValueAndError() async {
        let h = UpdateHarness()
        let model = h.model()
        _ = await h.status()
        h.settingsFiles.failNextWrite = true
        model.setAutomaticUpdateChecks(.disabled)
        _ = await h.status()
        XCTAssertEqual(model.state.automaticUpdateChecks, .enabled)
        XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
        model.setAutomaticUpdateChecks(.disabled)
        _ = await h.status()
        XCTAssertEqual(model.state.automaticUpdateChecks, .disabled)
        XCTAssertNil(model.state.settingsError)
    }

    func testCheckingResultAndExplicitPageOpeningPublishThroughMainThread() async {
        let h = UpdateHarness([.held])
        let model = h.model()
        _ = await h.status()
        model.setAutomaticUpdateChecks(.disabled)
        model.onChange = { XCTAssertTrue(h.main.isRunning) }
        model.checkNow()
        await h.transport.waitUntilSent()
        _ = await h.status()
        XCTAssertTrue(model.state.update?.isChecking == true)
        await h.transport.release(updateResponse(htmlURL: "https://evil.example/install"))
        _ = await h.completed(in: self)
        XCTAssertEqual(model.state.update?.result, .updateAvailable(ReleaseVersion("2.0.0")!))
        XCTAssertEqual(model.state.update?.lastSuccessfulCheck, h.clock.now())
        XCTAssertTrue(h.opener.urls.isEmpty)
        model.viewRelease()
        _ = await h.status()
        XCTAssertEqual(h.opener.urls.map(\.absoluteString), ["https://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0"])
    }

    func testReadOnlySettingsAreVisibleAndManualIsAvailable() async throws {
        let files = MemoryFileStore()
        try files.put("corrupt", at: "settings.json")
        let h = UpdateHarness(settingsFiles: files)
        let model = h.model()
        _ = await h.status()
        XCTAssertTrue(model.state.isReadOnly)
        XCTAssertEqual(model.state.settingsError, .corruptFile)
        model.setAutomaticUpdateChecks(.disabled)
        _ = await h.status()
        XCTAssertEqual(model.state.automaticUpdateChecks, .enabled)
        XCTAssertFalse(h.settings.allowsAutomaticUpdateChecks)
        model.checkNow()
        _ = await h.completed(in: self)
        XCTAssertEqual(model.state.update?.result, .updateAvailable(ReleaseVersion("2.0.0")!))
        XCTAssertEqual(try files.text(at: "settings.json"), "corrupt")
    }

    func testMultipleModelsObserveIndependentlyAndRetirementDropsQueuedIntents() async {
        let h = UpdateHarness()
        let first = h.model()
        let second = h.model()
        _ = await h.status()
        var firstChanges = 0
        var secondChanges = 0
        first.onChange = { firstChanges += 1 }
        second.onChange = { secondChanges += 1 }
        first.setAutomaticUpdateChecks(.disabled)
        _ = await h.status()
        XCTAssertGreaterThan(firstChanges, 0)
        XCTAssertGreaterThan(secondChanges, 0)
        let previousFirst = firstChanges
        h.main.deferred = true
        first.checkNow()
        first.viewRelease()
        first.setAutomaticUpdateChecks(.enabled)
        first.retire()
        h.main.drain()
        h.main.deferred = false
        _ = await h.status()
        XCTAssertEqual(firstChanges, previousFirst)
        XCTAssertEqual(second.state.automaticUpdateChecks, .disabled)
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(h.opener.urls.isEmpty)
    }

    func testAcceptedPreferenceSurvivesOrdinaryReleaseAndLateReportsDoNotRetainModel() async {
        let h = UpdateHarness()
        var model: UpdateSettingsModel? = h.model()
        _ = await h.status()
        weak var released = model
        h.main.deferred = true
        model?.setAutomaticUpdateChecks(.disabled)
        model = nil
        h.main.drain()
        h.main.deferred = false
        _ = await h.status()
        XCTAssertEqual(h.settings.automaticUpdateChecks, .disabled)
        XCTAssertNil(released)
        released = nil

        var pending: UpdateSettingsModel? = h.model()
        _ = await h.status()
        h.main.deferred = true
        pending?.checkNow()
        pending?.viewRelease()
        pending = nil
        h.main.drain()
        h.main.deferred = false
        _ = await h.status()
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }
}
