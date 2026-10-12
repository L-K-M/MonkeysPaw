import MonkeysPawCore
import XCTest

final class ShortcutsSettingsModelTests: XCTestCase {
    private final class Harness {
        let delivery: DeliveryHarness
        let backend = FakeHotkeyBackend()
        let probe = FakeSetupProbe()
        let shortcuts: ShortcutService
        let setup: SetupService
        var setupModel: SetupModel?
        var settings: ShortcutsSettingsModel?
        private(set) var fires: [HotkeyAction] = []

        init(session: DesktopSession = .gnomeWayland, mainMode: FakeCompletionMode = .immediate) {
            delivery = DeliveryHarness(session: session)
            delivery.main.mode = mainMode
            shortcuts = ShortcutService(backend: backend, scheduler: delivery.scheduler, mainThread: delivery.main)
            let selfTest = SelfTest(target: delivery.target, delivery: delivery.service, session: delivery.session,
                scheduler: delivery.scheduler, mainThread: delivery.main)
            setup = SetupService(probe: probe, session: delivery.session, shortcuts: shortcuts,
                selfTest: selfTest, mainThread: delivery.main)
            setupModel = SetupModel(setup: setup)
            settings = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
        }

        func configureCarbon(_ text: String = "Ctrl+Alt+P") throws {
            backend.mechanism = .carbon
            probe.liveHotkey = { [weak backend] in backend?.currentRegistrations[.togglePicker] }
            shortcuts.configure([.togglePicker: try Accelerator(text)]) { [weak self] in self?.fires.append($0) }
            delivery.main.drain()
        }

        func refreshRegistration(
            _ mechanism: HotkeyMechanism = .globalShortcutsPortal,
            status: RegistrationStatus = .registered, detail: String = "User-selected key",
            configuration: HotkeyConfiguration? = nil,
            alternativeConfiguration: HotkeyConfiguration? = nil
        ) {
            probe.hotkey = HotkeyRegistration(mechanism: mechanism, status: status, detail: detail,
                configuration: configuration, alternativeConfiguration: alternativeConfiguration)
            setupModel?.refresh()
            delivery.main.drain()
        }

        var setupHotkey: SetupRow? { setupModel?.rows.first(where: { $0.kind == .hotkey }) }
    }

    func testSetupAndSettingsShareOneLiveProbeOnCompositionRefresh() {
        let h = Harness(mainMode: .deferred)
        XCTAssertNil(h.settings?.togglePicker.registration)
        XCTAssertEqual(h.settings?.togglePicker.binding, .unknown)
        h.delivery.main.drain()
        var setupChanges = 0
        var settingsChanges = 0
        var shortcutChanges = 0
        h.setupModel?.onChange = { setupChanges += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.settings?.onChange = { settingsChanges += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.shortcuts.addObserver { shortcutChanges += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.delivery.main.drain()
        let queries = h.probe.queried.filter { $0 == .hotkey }.count
        let registrations = h.backend.registered.count

        h.refreshRegistration(detail: "Super+F8", configuration: .systemSettings)

        XCTAssertEqual(h.settings?.togglePicker.binding, .reported("Super+F8"))
        XCTAssertEqual(h.settings?.togglePicker.registration, h.setupHotkey?.registration)
        XCTAssertEqual(h.shortcuts.registrations[.togglePicker], h.probe.hotkey)
        XCTAssertEqual(h.probe.queried.filter { $0 == .hotkey }.count, queries + 1)
        XCTAssertEqual(h.backend.registered.count, registrations)
        XCTAssertEqual(setupChanges, 1)
        XCTAssertEqual(settingsChanges, 1)
        XCTAssertEqual(shortcutChanges, 1)
    }

    func testActualBoundUnboundAndConflictFactsSurviveRepeatedRefreshes() {
        let h = Harness(session: .kdeWayland)
        let cases: [(RegistrationStatus, String, ShortcutsSettingsModel.Binding)] = [
            (.registered, "Ctrl+K, Ctrl+P; Alt+F9", .reported("Ctrl+K, Ctrl+P; Alt+F9")),
            (.unbound, "No key assigned; default is used by another action", .unbound),
            (.failed, "Alt+F9. This shortcut conflicts with another action", .unknown),
        ]
        for (status, detail, binding) in cases {
            h.refreshRegistration(.kglobalaccel, status: status, detail: detail, configuration: .systemSettings)
            h.settings?.refresh()
            XCTAssertEqual(h.settings?.togglePicker.registrationStatus, status)
            XCTAssertEqual(h.settings?.togglePicker.registration?.detail, detail)
            XCTAssertEqual(h.settings?.togglePicker.binding, binding)
            XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
        }
        XCTAssertTrue(h.backend.registered.isEmpty)
        XCTAssertTrue(h.probe.fixes.isEmpty)
    }

    func testUnknownCarbonBindingDoesNotBecomeTheDefault() {
        let h = Harness(session: .macOS)
        h.refreshRegistration(.carbon, detail: "Carbon shortcut registered")
        XCTAssertEqual(h.settings?.togglePicker.binding, .unknown)
        XCTAssertEqual(h.settings?.togglePicker.changePath, .inApp)
    }

    func testSetupObserverRemovalStopsItsCallbackWithoutRemovingTheOtherObserver() {
        let h = Harness(mainMode: .deferred)
        h.delivery.main.drain()
        var firstChanges = 0
        var secondChanges = 0
        let first = h.setup.addObserver { _ in firstChanges += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        let second = h.setup.addObserver { _ in secondChanges += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.setup.refresh { _ in }
        h.delivery.main.drain()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)

        h.setup.removeObserver(first)
        h.setup.refresh { _ in }
        h.delivery.main.drain()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 2)
        h.setup.removeObserver(second)
        h.setup.refresh { _ in }
        h.delivery.main.drain()
        XCTAssertEqual(secondChanges, 2)
    }

    func testLiveMechanismChangesClearObsoleteErrorAndInstructions() throws {
        let h = Harness(session: .macOS)
        try h.configureCarbon()
        h.settings?.setAccelerator("Ctrl++P")
        XCTAssertEqual(h.settings?.error, .invalidAccelerator(.malformed))

        h.probe.liveHotkey = nil
        h.refreshRegistration(.manual, status: .needsAction,
            detail: "gapplication action ch.lkmc.monkeyspaw toggle")
        XCTAssertNil(h.settings?.error)
        h.settings?.performPlatformChange()
        XCTAssertNotNil(h.settings?.instructions)

        h.refreshRegistration(detail: "User key", configuration: .systemSettings)
        XCTAssertNil(h.settings?.instructions)
    }

    func testDroppingEitherModelLeavesTheOtherSubscribed() throws {
        for removeSettings in [true, false] {
            let h = Harness(session: .macOS, mainMode: .deferred)
            try h.configureCarbon()
            weak var removedSettings = h.settings
            weak var removedSetup = h.setupModel
            if removeSettings { h.settings = nil } else { h.setupModel = nil }
            h.delivery.main.drain()
            if removeSettings { XCTAssertNil(removedSettings) } else { XCTAssertNil(removedSetup) }
            var changes = 0
            h.settings?.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }
            h.setupModel?.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }

            h.shortcuts.beginVerification()
            h.delivery.main.drain()
            h.backend.fire()
            h.delivery.main.drain()

            XCTAssertEqual(changes, 2)
            if removeSettings {
                XCTAssertEqual(h.setupHotkey?.status, .ok)
            } else {
                XCTAssertEqual(h.settings?.togglePicker.verification, .verified)
            }
        }
    }

    func testCarbonRejectsMalformedUnsupportedKeysAndOverlappingCommandAliasesWithoutTearingDown() throws {
        let h = Harness(session: .macOS)
        try h.configureCarbon()
        let original = h.settings?.togglePicker
        let cases: [(String, ShortcutRebindError)] = [
            ("", .invalidAccelerator(.empty)),
            ("Ctrl++P", .invalidAccelerator(.malformed)),
            ("Ctrl+Ctrl+P", .invalidAccelerator(.duplicateModifier(.control))),
            ("Insert", .unsupportedCarbonKey), ("PrintScreen", .unsupportedCarbonKey),
            ("F21", .unsupportedCarbonKey), ("F22", .unsupportedCarbonKey),
            ("F23", .unsupportedCarbonKey), ("F24", .unsupportedCarbonKey),
            ("Cmd+Super+P", .overlappingCommandModifiers),
            ("Cmd+CmdOrCtrl+P", .overlappingCommandModifiers),
            ("Super+CmdOrCtrl+P", .overlappingCommandModifiers),
        ]
        for (text, error) in cases {
            h.settings?.setAccelerator(text)
            XCTAssertEqual(h.settings?.error, error, text)
            XCTAssertEqual(h.settings?.togglePicker, original, text)
        }
        XCTAssertEqual(h.backend.registered.count, 1)
        XCTAssertTrue(h.backend.unregistered.isEmpty)
    }

    func testValidCarbonRebindPreservesFireHandlerAndInvalidatesOldProof() throws {
        let h = Harness(session: .macOS)
        try h.configureCarbon()
        h.settings?.beginVerification()
        h.backend.fire()
        XCTAssertEqual(h.settings?.togglePicker.verification, .verified)
        XCTAssertEqual(h.setupHotkey?.status, .ok)
        let original = try XCTUnwrap(h.settings?.togglePicker.registration)
        let staleFire = try XCTUnwrap(h.backend.callbacks[.togglePicker])
        h.settings?.setAccelerator("Ctrl++P")

        h.settings?.setAccelerator("Ctrl+CmdOrCtrl+F20")

        let expected = try Accelerator("Ctrl+CmdOrCtrl+F20")
        XCTAssertNil(h.settings?.error)
        XCTAssertEqual(h.settings?.togglePicker.binding, .accelerator(expected))
        XCTAssertEqual(h.backend.registered.last?.1, expected)
        XCTAssertEqual(h.backend.unregistered, [original])
        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
        XCTAssertEqual(h.setupHotkey?.status, .needsAction(fix: SetupStrings.pressShortcut))
        h.settings?.beginVerification()
        staleFire()
        XCTAssertEqual(h.settings?.togglePicker.verification, .waiting)
        h.backend.fire()
        XCTAssertEqual(h.settings?.togglePicker.verification, .verified)
        XCTAssertEqual(h.fires, [.togglePicker, .togglePicker])
    }

    func testNativeCarbonRegistrationFailureIsReportedWithoutConfirmingRequestedKey() throws {
        let h = Harness(session: .macOS)
        try h.configureCarbon()
        h.backend.status = .failed
        h.backend.detail = "Shortcut is already in use"

        h.settings?.setAccelerator("Alt+F8")

        XCTAssertEqual(h.settings?.togglePicker.registrationStatus, .failed)
        XCTAssertEqual(h.settings?.togglePicker.binding, .unknown)
        XCTAssertEqual(h.settings?.togglePicker.registration?.detail, h.backend.detail)
        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
    }

    func testSystemAndManualMechanismsRejectInAppRebinding() {
        for mechanism in [HotkeyMechanism.globalShortcutsPortal, .gnomeCustomKeybinding, .kglobalaccel, .manual] {
            let h = Harness()
            h.backend.mechanism = mechanism
            h.refreshRegistration(mechanism)
            h.settings?.setAccelerator("Ctrl+Alt+E")
            XCTAssertEqual(h.settings?.error, .unavailable, "\(mechanism)")
            XCTAssertTrue(h.backend.registered.isEmpty)
            XCTAssertTrue(h.probe.fixes.isEmpty)
        }
    }

    func testSystemSettingsCompletionNeverInventsBindingOrVerification() {
        let h = Harness(mainMode: .deferred)
        h.delivery.main.drain()
        h.probe.fixMode = .deferred
        h.refreshRegistration(status: .unbound, detail: "No key chosen", configuration: .systemSettings)
        XCTAssertEqual(h.settings?.togglePicker.changePath, .systemSettings(action: .hotkey))

        h.settings?.performPlatformChange()
        h.delivery.main.drain()
        XCTAssertEqual(h.probe.fixes, [.hotkey])
        XCTAssertEqual(h.settings?.togglePicker.binding, .unbound)
        h.probe.completeFix(times: 2)
        h.delivery.main.drain()
        XCTAssertEqual(h.settings?.togglePicker.registrationStatus, .unbound)
        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)

        h.refreshRegistration(detail: "Shift+F12", configuration: .systemSettings)
        XCTAssertEqual(h.settings?.togglePicker.binding, .reported("Shift+F12"))
        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
        XCTAssertTrue(h.backend.registered.isEmpty)
    }

    func testPlatformActionsUseExistingSetupRoutes() {
        let cases: [(DesktopSession, HotkeyMechanism, HotkeyConfiguration?, SetupRow.Kind)] = [
            (.gnomeWayland, .globalShortcutsPortal, .systemSettings, .hotkey),
            (.kdeWayland, .kglobalaccel, .systemSettings, .hotkey),
            (.kdeX11, .kglobalaccel, .attachPortal, .kde),
            (.kdeWayland, .globalShortcutsPortal, .attachPortal, .hotkey),
            (.gnomeX11, .gnomeCustomKeybinding, nil, .hotkey),
        ]
        for (session, mechanism, configuration, kind) in cases {
            let h = Harness(session: session)
            h.refreshRegistration(mechanism, status: .needsAction, detail: "Explicit setup needed",
                configuration: configuration, alternativeConfiguration: .nativeFallback)
            XCTAssertTrue(h.probe.fixes.isEmpty)
            h.settings?.performPlatformChange()
            XCTAssertEqual(h.probe.fixes, [kind], "\(mechanism): \(configuration as Any)")
            XCTAssertEqual(h.settings?.togglePicker.registrationStatus, .needsAction)
        }
    }

    func testRegisteredGNOMEFallbackAndPortalV1GiveGuidanceWithoutReinstallingOrRebinding() {
        let cases: [(DesktopSession, HotkeyMechanism, String)] = [
            (.gnomeX11, .gnomeCustomKeybinding, "GNOME Settings"),
            (.gnomeWayland, .globalShortcutsPortal, "GNOME Settings"),
            (.flatpak(host: .kdeWayland), .globalShortcutsPortal, SetupStrings.kdeShortcut),
        ]
        for (session, mechanism, expected) in cases {
            let h = Harness(session: session)
            h.refreshRegistration(mechanism, detail: "User key")
            h.settings?.performPlatformChange()
            XCTAssertTrue(h.settings?.instructions?.contains(expected) == true)
            XCTAssertEqual(h.settings?.togglePicker.binding, .reported("User key"))
            XCTAssertTrue(h.probe.fixes.isEmpty)
            XCTAssertTrue(h.backend.registered.isEmpty)
        }
    }

    func testManualInstructionsRemainBackendOwnedAndRepeatIsUnboundAndUnavailable() {
        let h = Harness(session: .wlroots)
        let command = "gapplication action ch.lkmc.monkeyspaw toggle"
        h.refreshRegistration(.manual, status: .needsAction, detail: command)
        h.settings?.performPlatformChange()
        XCTAssertEqual(h.settings?.togglePicker.changePath, .manualInstructions(command))
        XCTAssertEqual(h.settings?.instructions, command)
        XCTAssertEqual(h.settings?.togglePicker.binding, .unknown)
        XCTAssertTrue(h.probe.fixes.isEmpty)

        h.settings?.beginVerification()
        h.settings?.refresh()
        XCTAssertEqual(h.settings?.repeatLast.action, .repeatLast)
        XCTAssertEqual(h.settings?.repeatLast.binding, .unbound)
        XCTAssertEqual(h.settings?.repeatLast.registrationStatus, .unbound)
        XCTAssertEqual(h.settings?.repeatLast.verification, .notStarted)
        XCTAssertEqual(h.settings?.repeatLast.changePath, .unavailable)
        XCTAssertNil(h.backend.callbacks[.repeatLast])
    }

    func testLiveUnbindingClearsVerificationAndPreventsStartingItAgain() throws {
        let h = Harness()
        h.backend.mechanism = .globalShortcutsPortal
        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        h.refreshRegistration(detail: "User key", configuration: .systemSettings)
        h.settings?.beginVerification()
        h.backend.fire()
        XCTAssertEqual(h.settings?.togglePicker.verification, .verified)

        h.refreshRegistration(status: .unbound, detail: "No key", configuration: .systemSettings)
        h.settings?.beginVerification()

        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
        XCTAssertEqual(h.shortcuts.verification(for: .togglePicker), .notStarted)
        h.refreshRegistration(detail: "New user key", configuration: .systemSettings)
        XCTAssertEqual(h.settings?.togglePicker.verification, .notStarted)
    }

    func testVerificationIntentArmsBeforeAnImmediatelyQueuedActivation() throws {
        let h = Harness(session: .macOS, mainMode: .deferred)
        try h.configureCarbon()

        h.settings?.beginVerification()
        h.backend.fire()
        h.delivery.main.drain()

        XCTAssertEqual(h.settings?.togglePicker.verification, .verified)
        XCTAssertEqual(h.setupHotkey?.status, .ok)
    }
}
