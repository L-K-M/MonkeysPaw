import XCTest
@testable import MonkeysPawCore

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
            shortcuts.configure { [weak self] in self?.fires.append($0) }
        }

        @discardableResult
        func set(_ text: String, for action: HotkeyAction) -> Result<HotkeyRegistration, ShortcutRebindError>? {
            var result: Result<HotkeyRegistration, ShortcutRebindError>?
            shortcuts.setAccelerator(text, for: action) { result = $0 }
            XCTAssertNotNil(result, "The immediate MainThread must deliver the completion before returning")
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

    func testExplicitCarbonCatalogueHonorsBoundRepeatAndClearedPickerWithoutChangingSavedChoices() throws {
        let h = Harness()
        h.configure()
        let saved = h.settings.snapshot
        var fires: [HotkeyAction] = []
        let repeatKey = try Accelerator("Alt+F8")

        h.shortcuts.configure([.repeatLast: repeatKey]) { fires.append($0) }

        XCTAssertEqual(h.backend.registered.suffix(2).map(\.1), [nil, repeatKey])
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .unbound)
        XCTAssertEqual(h.shortcuts.registrations[.repeatLast]?.status, .registered)
        XCTAssertEqual(h.settings.snapshot, saved)
        h.backend.fire(.togglePicker)
        h.backend.fire(.repeatLast)
        XCTAssertEqual(fires, [.repeatLast])

        h.shortcuts.configure([:]) { fires.append($0) }
        XCTAssertTrue(h.backend.registered.suffix(2).allSatisfy { $0.1 == nil })
        h.backend.fire(.repeatLast)
        XCTAssertEqual(fires, [.repeatLast])
    }

    func testCarbonConfigurationReportsUnhealthySettingsAndPreservesInstalledRecoveryBindings() throws {
        for contents in ["{\"version\":99}", "{", nil] as [String?] {
            let files = MemoryFileStore()
            if let contents { try files.put(contents, at: "settings.json") }
            else { files.onRead = { _ in throw FileStoreError.ioFailure } }
            let h = Harness(files: files)
            let error = try XCTUnwrap(h.settings.snapshot.readOnlyError)
            var completions = 0
            var failure: ShortcutRebindError?
            let completed: (Result<Void, ShortcutRebindError>) -> Void = {
                completions += 1
                if case .failure(let error) = $0 { failure = error }
            }

            h.shortcuts.configure(done: completed) { h.fires.append($0) }

            XCTAssertEqual(completions, 1)
            XCTAssertEqual(failure, .saveFailed(error))
            XCTAssertEqual(h.backend.registered.map(\.1), [Accelerator.defaultBinding(for: .togglePicker), nil])
            let previous = h.shortcuts.registrations
            failure = nil
            h.shortcuts.configure([.repeatLast: try Accelerator("Alt+R")], done: completed) { _ in
                XCTFail("Rejected configuration replaced the callback")
            }
            XCTAssertEqual(completions, 2)
            XCTAssertEqual(failure, .saveFailed(error))
            XCTAssertEqual(h.shortcuts.registrations, previous)
            XCTAssertEqual(h.backend.registered.count, 2)
            XCTAssertTrue(h.backend.unregistered.isEmpty)
            h.backend.fire()
            XCTAssertEqual(h.fires, [.togglePicker])
        }
    }

    func testInvalidExplicitCarbonCatalogueFailsBeforeNativeMutation() throws {
        let h = Harness()
        h.configure()
        let previous = h.shortcuts.registrations
        let invalid: [([HotkeyAction: Accelerator], ShortcutRebindError)] = [
            ([.repeatLast: try Accelerator("Insert")], .unsupportedCarbonKey),
            ([.repeatLast: try Accelerator("Cmd+Super+R")], .overlappingCommandModifiers),
            ([.togglePicker: try Accelerator("Cmd+Plus"), .repeatLast: try Accelerator("Super+Shift+Equal")],
             .collision(.togglePicker)),
        ]
        for (catalogue, expected) in invalid {
            var failure: ShortcutRebindError?
            var completions = 0
            h.shortcuts.configure(catalogue, done: {
                completions += 1
                if case .failure(let error) = $0 { failure = error }
            }) { _ in XCTFail("Invalid catalogue replaced the callback") }
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(h.shortcuts.registrations, previous)
        }
        XCTAssertEqual(h.backend.registered.count, 2)
        XCTAssertTrue(h.backend.unregistered.isEmpty)
        h.backend.fire()
        XCTAssertEqual(h.fires, [.togglePicker])
    }

    func testReentrantExplicitCarbonCataloguesCompleteOnceAndLastRequestOverridesSavedChoices() throws {
        let h = Harness()
        h.configure()
        let latest: [HotkeyAction: Accelerator] = [.repeatLast: try Accelerator("Alt+F9")]
        var supersededCompletions = 0
        var latestCompletions = 0
        var fires: [HotkeyAction] = []
        h.backend.onRegister = {
            h.backend.onRegister = nil
            h.shortcuts.configure([:], done: { result in
                supersededCompletions += 1
                if case .failure(let error) = result { XCTAssertEqual(error, .unavailable) }
                else { XCTFail("Superseded configuration reported success") }
            }) { _ in XCTFail("Superseded callback fired") }
            h.shortcuts.configure(latest, done: { result in
                latestCompletions += 1
                if case .failure = result { XCTFail("Latest configuration failed") }
            }) { fires.append($0) }
        }

        _ = try h.set("Alt+E", for: .togglePicker)?.get()

        XCTAssertEqual(supersededCompletions, 1)
        XCTAssertEqual(latestCompletions, 1)
        XCTAssertEqual(h.backend.registered.suffix(2).map(\.1), [nil, latest[.repeatLast]])
        XCTAssertEqual(h.settings.snapshot.document.carbonShortcuts.togglePicker, try Accelerator("Alt+E"))
        XCTAssertNil(h.settings.snapshot.document.carbonShortcuts.repeatLast)
        h.backend.fire(.togglePicker)
        h.backend.fire(.repeatLast)
        XCTAssertEqual(fires, [.repeatLast])
    }

    func testCarbonConfigurationReportsNativeRegistrationFailure() {
        let h = Harness()
        h.backend.status = .failed
        var completions = 0
        var failure: ShortcutRebindError?

        h.shortcuts.configure(done: {
            completions += 1
            if case .failure(let error) = $0 { failure = error }
        }) { _ in XCTFail("Failed registration fired") }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(failure, .registrationFailed)
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .failed)
        XCTAssertEqual(h.shortcuts.verification(for: .togglePicker), .notStarted)
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

        XCTAssertEqual(h.backend.registered.count, 4)
        XCTAssertEqual(h.backend.unregistered.count, 2)
        XCTAssertTrue(h.backend.registrationOutcomes.isEmpty)
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .failed)
        XCTAssertEqual(h.settings.snapshot, previous)
        _ = try h.set("Ctrl+Alt+P", for: .togglePicker)?.get()
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .registered)
    }

    func testSavedCollisionRetainsItsTypedActionAndRollsBackTheNativeReplacement() throws {
        let h = Harness()
        h.configure()
        _ = try h.set("Alt+R", for: .repeatLast)?.get()
        let picker = h.settings.snapshot.document.carbonShortcuts.togglePicker
        let repeatRegistration = h.shortcuts.registrations[.repeatLast]
        let otherSettings = SettingsService(store: SettingsStore(files: h.files))
        try otherSettings.setCarbonShortcut(.repeatLast, accelerator: Accelerator("Alt+F8"))

        XCTAssertEqual(h.set("Alt+F8", for: .togglePicker), .failure(.collision(.repeatLast)))

        XCTAssertEqual(h.shortcuts.registrations[.togglePicker]?.status, .registered)
        XCTAssertEqual(h.backend.registered.last?.1, picker)
        XCTAssertEqual(h.shortcuts.registrations[.repeatLast], repeatRegistration)
        let reopened = SettingsService(store: SettingsStore(files: h.files))
        XCTAssertEqual(reopened.snapshot.document.carbonShortcuts.repeatLast, try Accelerator("Alt+F8"))
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
