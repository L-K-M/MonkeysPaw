import Foundation
import MonkeysPawCore
import XCTest

final class DeliverySettingsModelTests: XCTestCase {
    func testInitialSnapshotAndRefreshNeverReadClipboardCaptureFocusOrRequestConsent() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = Harness(session: .flatpak(host: .kdeWayland), mode: mode)
            let model = h.makeModel()
            var changes = 0
            model.onChange = { XCTAssertTrue(h.delivery.main.isRunning); changes += 1 }
            h.delivery.main.drain()
            XCTAssertEqual(model.state.preferences, DeliveryPreferences())
            XCTAssertEqual(model.state.delivery?.pasteLadder, [.remoteDesktopPortal])
            XCTAssertEqual(model.state.permissionRows.first(where: { $0.kind == .portal })?.status, .unknown)
            XCTAssertEqual(model.state.test, .idle)
            let afterInitial = changes
            model.refresh()
            h.delivery.main.drain()
            XCTAssertEqual(changes, afterInitial)
            XCTAssertTrue(h.delivery.recorder.events.isEmpty)
            XCTAssertEqual(h.delivery.clipboard.readCount, 0)
            XCTAssertTrue(h.backend.registered.isEmpty)
            XCTAssertTrue(h.probe.fixes.isEmpty)
            XCTAssertEqual(h.delivery.cache.resets, 0)
        }
    }

    func testPreferenceIntentsPublishCommittedStateOnMainThreadUnderBothModes() throws {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = Harness(mode: mode)
            let model = h.makeModel()
            h.delivery.main.drain()
            var changes: [DeliveryPreferences] = []
            model.onChange = {
                XCTAssertTrue(h.delivery.main.isRunning)
                changes.append(model.state.preferences)
            }
            model.setLinuxDefaultPasteChord(.terminal)
            if mode == .deferred {
                XCTAssertTrue(changes.isEmpty)
                XCTAssertEqual(model.state.preferences.linuxDefaultPasteChord, .standard)
            }
            h.delivery.main.drain()
            model.setClipboardRestore(.previousText)
            h.delivery.main.drain()
            model.setClipboardRestore(.previousText)
            h.delivery.main.drain()
            XCTAssertEqual(changes, [DeliveryPreferences(linuxDefaultPasteChord: .terminal),
                DeliveryPreferences(linuxDefaultPasteChord: .terminal, clipboardRestore: .previousText)])
            XCTAssertEqual(SettingsService(store: SettingsStore(files: h.files)).snapshot.document.delivery,
                           model.state.preferences)
            XCTAssertEqual(h.delivery.clipboard.readCount, 0)
            XCTAssertTrue(h.delivery.recorder.events.isEmpty)
        }
    }

    func testFailedWritePublishesErrorWithoutAnOptimisticPreferenceAndRetrySucceeds() throws {
        let h = Harness(mode: .deferred)
        h.settings.setLibraryFolder("/chosen")
        let model = h.makeModel()
        h.delivery.main.drain()
        let original = try h.files.read(at: "settings.json")
        var published: [DeliverySettingsModel.State] = []
        model.onChange = { XCTAssertTrue(h.delivery.main.isRunning); published.append(model.state) }
        h.files.failNextWrite = true
        model.setClipboardRestore(.previousText)
        h.delivery.main.drain()
        XCTAssertEqual(model.state.preferences.clipboardRestore, .off)
        XCTAssertEqual(model.state.settingsError, .writeFailed(.ioFailure))
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].preferences.clipboardRestore, .off)
        XCTAssertEqual(try h.files.read(at: "settings.json"), original)
        model.setClipboardRestore(.previousText)
        h.delivery.main.drain()
        XCTAssertEqual(model.state.preferences.clipboardRestore, .previousText)
        XCTAssertNil(model.state.settingsError)
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(h.settings.libraryFolderPath, "/chosen")
    }

    func testReadOnlySettingsSurfaceErrorAndRejectPreferenceChanges() throws {
        for source in [#"{"version":99}"#, "corrupt"] {
            let files = MemoryFileStore()
            try files.put(source, at: "settings.json")
            let h = Harness(files: files, mode: .deferred)
            let model = h.makeModel()
            h.delivery.main.drain()
            let before = model.state
            XCTAssertTrue(before.isReadOnly)
            XCTAssertNotNil(before.settingsError)
            model.setLinuxDefaultPasteChord(.terminal)
            model.setClipboardRestore(.previousText)
            h.delivery.main.drain()
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(try files.text(at: "settings.json"), source)
            XCTAssertFalse(h.settings.allowsAutomaticUpdateChecks)
        }
    }

    func testSettingsAndSetupChangesUseTheModelsOwnMainThread() {
        let h = Harness()
        let modelMain = FakeMainThread()
        modelMain.mode = .deferred
        let model = DeliverySettingsModel(settings: h.settings, delivery: h.delivery.service,
            setup: h.setup, mainThread: modelMain)
        modelMain.drain()
        var changes = 0
        model.onChange = { XCTAssertTrue(modelMain.isRunning); changes += 1 }
        h.settings.setClipboardRestore(.previousText)
        XCTAssertEqual(changes, 0)
        modelMain.drain()
        XCTAssertEqual(changes, 1)
        h.probe.portal = .needsAction(fix: "Allow portal access in Setup")
        h.setup.refresh { _ in }
        XCTAssertEqual(changes, 1)
        modelMain.drain()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(model.state.permissionRows.first(where: { $0.kind == .portal })?.status,
                       h.probe.portal)
    }

    func testMultipleModelsObserveIndependentlyWithoutReplacingExistingViewHooks() {
        let h = Harness()
        var first: DeliverySettingsModel? = h.makeModel()
        let second = h.makeModel()
        weak var released = first
        var firstChanges = 0
        var secondChanges = 0
        var settingsChanges = 0
        first?.onChange = { firstChanges += 1 }
        second.onChange = { secondChanges += 1 }
        h.settings.onChange = { settingsChanges += 1 }
        h.settings.setClipboardRestore(.previousText)
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)
        XCTAssertEqual(settingsChanges, 1)
        first = nil
        XCTAssertNil(released)
        h.settings.setLinuxDefaultPasteChord(.terminal)
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 2)
        XCTAssertEqual(settingsChanges, 2)
        h.settings.completeTour()
        h.settings.setAutomaticUpdateChecks(.disabled)
        XCTAssertEqual(secondChanges, 2, "Unrelated settings do not change Delivery state")
        released = nil
    }

    func testAcceptedPreferenceWriteSurvivesViewRelease() {
        let h = Harness(mode: .deferred)
        var model: DeliverySettingsModel? = h.makeModel()
        h.delivery.main.drain()
        weak var released = model
        model?.setClipboardRestore(.previousText)
        model = nil
        h.delivery.main.drain()
        XCTAssertEqual(h.settings.deliveryPreferences.clipboardRestore, .previousText)
        XCTAssertNil(released)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        released = nil
    }

    func testReleasedAndRetiredModelsDropQueuedNavigationTestAndLatePublications() {
        for retire in [false, true] {
            let h = Harness(mode: .deferred)
            var model: DeliverySettingsModel? = h.makeModel()
            weak var released = model
            let initial = model?.state
            var changes = 0
            var openings = 0
            model?.onChange = { changes += 1 }
            model?.onOpenSetup = { openings += 1 }
            if retire { model?.setClipboardRestore(.previousText) }
            model?.runSelfTest()
            model?.openSetup()
            if retire { model?.retire() } else { model = nil }
            h.delivery.main.drain()
            XCTAssertEqual(h.settings.deliveryPreferences.clipboardRestore, .off)
            XCTAssertEqual(changes, 0)
            XCTAssertEqual(openings, 0)
            XCTAssertTrue(h.delivery.recorder.events.isEmpty)
            if retire {
                XCTAssertEqual(model?.state, initial)
                model?.onChange = { changes += 1 }
                h.settings.setLinuxDefaultPasteChord(.terminal)
                h.setup.refresh { _ in }
                model?.refresh()
                h.delivery.main.drain()
                XCTAssertEqual(changes, 0)
                model = nil
            }
            XCTAssertNil(released)
            released = nil
        }
    }

    func testTestPasteUsesSharedSelfTestOnceAndSetupNavigationUsesMainThread() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = Harness(mode: mode)
            let model = h.makeModel()
            h.delivery.main.drain()
            h.delivery.target.received = [DeliveryStrings.testPrompt, DeliveryStrings.testPrompt]
            var states: [DeliverySettingsModel.TestState] = []
            var openings = 0
            model.onChange = { XCTAssertTrue(h.delivery.main.isRunning); states.append(model.state.test) }
            model.onOpenSetup = { XCTAssertTrue(h.delivery.main.isRunning); openings += 1 }
            model.openSetup()
            model.runSelfTest()
            model.runSelfTest()
            h.delivery.main.drain()
            XCTAssertEqual(openings, 1)
            XCTAssertEqual(states, [.testing])
            h.finishSelfTest()
            XCTAssertEqual(states, [.testing, .tested(SelfTestReport(session: .gnomeWayland,
                results: [.init(backend: .remoteDesktopPortal, status: .pasted),
                          .init(backend: .ydotool, status: .pasted)]))])
            XCTAssertEqual(h.delivery.cache.resets, 1)
            XCTAssertNil(model.state.delivery?.lastDelivery)
            XCTAssertTrue(h.probe.fixes.isEmpty)
        }
    }

    func testRetirementOrReleaseDropsLateTestCompletionWithoutStoppingOtherSetupObservers() {
        for retire in [false, true] {
            let h = Harness()
            let setupModel = SetupModel(setup: h.setup)
            var model: DeliverySettingsModel? = h.makeModel()
            weak var released = model
            var changes = 0
            model?.onChange = { changes += 1 }
            model?.runSelfTest()
            XCTAssertEqual(changes, 1)
            if retire { model?.retire() } else { model = nil }
            h.finishSelfTest()
            h.probe.portal = .ok
            setupModel.refresh()
            XCTAssertEqual(setupModel.rows.first(where: { $0.kind == .portal })?.status, .ok)
            XCTAssertEqual(changes, 1)
            if retire { XCTAssertEqual(model?.state.test, .testing); model = nil }
            XCTAssertNil(released)
            released = nil
        }
    }

    func testPreferencesDoNotChangeExistingExplicitDeliveryOrActivateClipboardRestore() {
        let h = Harness()
        let model = h.makeModel()
        model.setLinuxDefaultPasteChord(.terminal)
        model.setClipboardRestore(.previousText)
        h.delivery.arm()
        h.delivery.deliver(mode: .paste(.standard))
        h.delivery.settle()
        XCTAssertEqual(h.delivery.injectors[.remoteDesktopPortal]?.chords, [.standard])
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
    }

    private final class Harness {
        let files: MemoryFileStore
        let delivery: DeliveryHarness
        let backend = FakeHotkeyBackend()
        let probe = FakeSetupProbe()
        let settings: SettingsModel
        let setup: SetupService

        init(files: MemoryFileStore = MemoryFileStore(), session: DesktopSession = .gnomeWayland,
             mode: FakeCompletionMode = .immediate) {
            self.files = files
            delivery = DeliveryHarness(session: session)
            delivery.main.mode = mode
            settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: files)))
            let shortcuts = ShortcutService(backend: backend, scheduler: delivery.scheduler,
                                            mainThread: delivery.main)
            let selfTest = SelfTest(target: delivery.target, delivery: delivery.service, session: delivery.session,
                scheduler: delivery.scheduler, mainThread: delivery.main)
            setup = SetupService(probe: probe, session: delivery.session, shortcuts: shortcuts,
                                 selfTest: selfTest, mainThread: delivery.main)
        }

        func makeModel() -> DeliverySettingsModel {
            DeliverySettingsModel(settings: settings, delivery: delivery.service,
                                  setup: setup, mainThread: delivery.main)
        }

        func finishSelfTest() {
            for _ in PasteLadder.backends(for: delivery.session.session) {
                delivery.settle()
                delivery.main.drain()
                delivery.scheduler.advance(by: Limits.selfTestReadBackDelay)
                delivery.main.drain()
            }
        }
    }
}
