import MonkeysPawCore
import XCTest

final class ShortcutActionTests: XCTestCase {
    private final class Harness {
        let delivery = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let files: MemoryFileStore
        let settings: SettingsService
        let shortcuts: ShortcutService
        var fires: [HotkeyAction] = []

        init(files: MemoryFileStore = MemoryFileStore()) {
            self.files = files
            settings = SettingsService(store: SettingsStore(files: files))
            backend.mechanism = .carbon
            shortcuts = ShortcutService(backend: backend, scheduler: delivery.scheduler,
                mainThread: delivery.main, settings: settings)
        }

        func configure() {
            shortcuts.configure([:]) { [weak self] in self?.fires.append($0) }
        }

        @discardableResult
        func set(_ text: String, for action: HotkeyAction) -> Result<HotkeyRegistration, ShortcutRebindError>? {
            var result: Result<HotkeyRegistration, ShortcutRebindError>?
            shortcuts.setAccelerator(text, for: action) { result = $0 }
            return result
        }
    }

    func testRestartLoadsBothPersistedChoicesAndExplicitUnbinding() throws {
        let h = Harness()
        h.configure()
        XCTAssertEqual(h.backend.registered.count, 2)
        XCTAssertEqual(h.backend.registered[0].1, Accelerator.defaultBinding(for: .togglePicker))
        XCTAssertNil(h.backend.registered[1].1)
        XCTAssertNotNil(h.backend.callbacks[.repeatLast])
        _ = try h.set("Cmd+Shift+R", for: .repeatLast)?.get()
        _ = try h.set("Ctrl+Alt+E", for: .togglePicker)?.get()

        let restarted = Harness(files: h.files)
        restarted.configure()
        XCTAssertEqual(restarted.backend.registered[0].1, try Accelerator("Ctrl+Alt+E"))
        XCTAssertEqual(restarted.backend.registered[1].1, try Accelerator("Cmd+Shift+R"))
        XCTAssertEqual(restarted.shortcuts.verification(for: .repeatLast), .notStarted)
        restarted.shortcuts.clear(.togglePicker) { if case .failure = $0 { XCTFail("Clear failed") } }
        let afterClear = Harness(files: h.files)
        afterClear.configure()
        XCTAssertNil(afterClear.backend.registered[0].1)
        XCTAssertEqual(afterClear.backend.registered[1].1, try Accelerator("Cmd+Shift+R"))
    }

    func testClearingRepeatPreservesPickerRegistrationVerificationAndCallback() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        let picker = h.shortcuts.registrations[.togglePicker]
        h.shortcuts.beginVerification()
        h.backend.fire()
        h.delivery.scheduler.advance(by: Limits.toggleDebounce)
        let staleRepeat = try XCTUnwrap(h.backend.callbacks[.repeatLast])

        h.shortcuts.clear(.repeatLast) { if case .failure = $0 { XCTFail("Clear failed") } }

        XCTAssertEqual(h.shortcuts.registrations[.togglePicker], picker)
        XCTAssertEqual(h.shortcuts.verification(for: .togglePicker), .verified)
        XCTAssertEqual(h.shortcuts.registrations[.repeatLast]?.status, .unbound)
        XCTAssertNil(h.settings.snapshot.document.carbonShortcuts.repeatLast)
        XCTAssertNotNil(h.backend.callbacks[.repeatLast])
        h.shortcuts.beginVerification(.repeatLast)
        staleRepeat()
        h.backend.fire(.repeatLast)
        h.backend.fire()
        XCTAssertEqual(h.fires, [.togglePicker, .togglePicker])
        XCTAssertEqual(h.shortcuts.verification(for: .repeatLast), .notStarted)
    }

    func testCarbonCollisionsIncludeCommandAndPlusAliasesBeforeAnyNativeMutation() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Cmd+Plus", for: .togglePicker)?.get()
        let previous = h.shortcuts.registrations
        let registrations = h.backend.registered.count
        for text in ["Super+Shift+Equal", "CmdOrCtrl+Plus", "Cmd+Shift+Equal"] {
            XCTAssertEqual(h.set(text, for: .repeatLast), .failure(.collision(.togglePicker)))
        }
        XCTAssertEqual(h.backend.registered.count, registrations)
        XCTAssertEqual(h.shortcuts.registrations, previous)
        XCTAssertNil(h.settings.snapshot.document.carbonShortcuts.repeatLast)
    }

    func testFailedSaveRestoresOnlyTheChangedActionAndRejectsItsOldCallbacks() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        let repeatRegistration = h.shortcuts.registrations[.repeatLast]
        h.shortcuts.beginVerification(.repeatLast)
        h.backend.fire(.repeatLast)
        let stalePicker = try XCTUnwrap(h.backend.callbacks[.togglePicker])
        let previous = h.settings.snapshot
        h.files.failNextWrite = true

        XCTAssertEqual(h.set("Alt+F8", for: .togglePicker), .failure(.saveFailed(.writeFailed(.ioFailure))))

        XCTAssertEqual(h.settings.snapshot, previous)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: h.files)).snapshot, previous)
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .registered)
        XCTAssertEqual(h.backend.registered.last?.1, previous.document.carbonShortcuts.togglePicker)
        XCTAssertEqual(h.shortcuts.registrations[.repeatLast], repeatRegistration)
        XCTAssertEqual(h.shortcuts.verification(for: .repeatLast), .verified)
        h.shortcuts.beginVerification()
        stalePicker()
        XCTAssertEqual(h.shortcuts.verification(for: .togglePicker), .waiting)
        h.backend.fire()
        XCTAssertEqual(h.shortcuts.verification(for: .togglePicker), .verified)
    }

    func testFailedClearRestoresRepeatAndPersistsNoFalseUnbinding() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        let picker = h.shortcuts.registrations[.togglePicker]
        h.files.failNextWrite = true
        var result: Result<HotkeyRegistration, ShortcutRebindError>?

        h.shortcuts.clear(.repeatLast) { result = $0 }

        XCTAssertEqual(result, .failure(.saveFailed(.writeFailed(.ioFailure))))
        XCTAssertEqual(h.shortcuts.registrations[.repeatLast]?.status, .registered)
        XCTAssertEqual(h.settings.snapshot.document.carbonShortcuts.repeatLast, try Accelerator("Alt+R"))
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker], picker)
    }

    func testFailedNativeRecoveryReportsFailureWithoutSavingRequestedKey() throws {
        let h = Harness()
        h.configure()
        let previous = h.settings.snapshot
        h.backend.registrationOutcomes = [.failed, .failed]

        XCTAssertEqual(h.set("Alt+F8", for: .togglePicker), .failure(.recoveryFailed))

        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .failed)
        XCTAssertEqual(h.settings.snapshot, previous)
        _ = try h.set("Ctrl+Alt+P", for: .togglePicker)?.get()
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .registered)
    }

    func testReadOnlySettingsRejectReplacementBeforeNativeMutation() throws {
        let files = MemoryFileStore()
        try files.put("{\"version\":99}", at: "settings.json")
        let h = Harness(files: files)
        h.configure()
        let previous = h.shortcuts.registrations
        XCTAssertEqual(h.set("Alt+F8", for: .togglePicker), .failure(.saveFailed(.futureVersion(99))))
        XCTAssertEqual(h.shortcuts.registrations, previous)
        XCTAssertEqual(h.backend.registered.count, 2)
        XCTAssertTrue(h.backend.unregistered.isEmpty)
    }

    func testSavingSeesConfirmedNativeStateAndReentrantReplacementIsRejected() throws {
        let h = Harness()
        h.configure()
        var observed = false
        h.files.onWrite = { _ in
            observed = true
            XCTAssertEqual(h.backend.currentRegistrations[.repeatLast]?.status, .registered)
            XCTAssertEqual(h.set("Alt+F8", for: .repeatLast), .failure(.unavailable))
        }
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        XCTAssertTrue(observed)
        XCTAssertEqual(h.settings.snapshot.document.carbonShortcuts.repeatLast, try Accelerator("Alt+R"))
    }

    func testObsoleteDebounceTimerCannotReleaseReboundRepeatEarly() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        h.backend.fire(.repeatLast)
        h.delivery.scheduler.advance(by: .milliseconds(50))
        _ = try h.set("Alt+F8", for: .repeatLast)?.get()
        h.backend.fire(.repeatLast)
        h.delivery.scheduler.advance(by: .milliseconds(50))
        h.backend.fire(.repeatLast)
        XCTAssertEqual(h.fires, [.repeatLast, .repeatLast])
        h.delivery.scheduler.advance(by: .milliseconds(50))
        h.backend.fire(.repeatLast)
        XCTAssertEqual(h.fires, [.repeatLast, .repeatLast, .repeatLast])
    }
}
