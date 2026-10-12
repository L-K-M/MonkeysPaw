import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacShortcutSettingsTests: XCTestCase {
    func testCaptureUsesPhysicalANSIKeysAndMasksIncidentalFlags() throws {
        for text in ["π", "з", "P", "p"] {
            let event = try key(kVK_ANSI_P, text: text,
                                flags: [.control, .option, .capsLock, .numericPad, .function])
            XCTAssertEqual(ShortcutRecorderButton.capture(event), .accelerator("Ctrl+Alt+P"))
        }
        let cases: [(Int, NSEvent.ModifierFlags, String)] = [
            (kVK_ANSI_Equal, [.command, .shift], "Shift+Cmd+Equal"),
            (kVK_ANSI_Quote, .option, "Alt+Quote"),
            (kVK_PageUp, .control, "Ctrl+PageUp"),
            (kVK_PageDown, .command, "Cmd+PageDown"),
            (kVK_F20, [.control, .command], "Ctrl+Cmd+F20"),
        ]
        for (code, flags, expected) in cases {
            let event = try key(code, flags: flags)
            XCTAssertEqual(ShortcutRecorderButton.capture(event), .accelerator(expected))
            let translated = try CarbonHotkeyBackend.translate(Accelerator(expected))
            XCTAssertEqual(translated.keyCode, UInt32(code))
        }
    }

    func testEverySupportedRecorderKeyRoundTripsToItsCarbonPhysicalCode() throws {
        // The sparse Carbon table includes letters, digits, named keys and F1–F20.
        var count = 0
        for code: UInt16 in 0...127 {
            guard let name = CarbonHotkeyBackend.keyName(for: code) else { continue }
            let accelerator = try Accelerator("Ctrl+Alt+" + name)
            XCTAssertEqual(try CarbonHotkeyBackend.translate(accelerator).keyCode, UInt32(code), name)
            count += 1
        }
        XCTAssertEqual(count, 81)
    }

    func testNamedBindingDisplayUsesTheSameParseableNamesAsCapture() throws {
        for name in ["PageUp", "PageDown", "Quote", "Backspace", "BracketLeft", "BracketRight",
                     "Space", "Tab", "Return", "Escape", "Comma", "Equal", "PrintScreen"] {
            let text = "Cmd+" + name
            let accelerator = try Accelerator(text)
            let display = Strings.shortcutBinding(.accelerator(accelerator))
            XCTAssertEqual(display, text)
            XCTAssertEqual(try Accelerator(display), accelerator)
        }
    }

    func testCommandOrControlBindingDisplaysCommandOnMacOS() throws {
        for (binding, display) in [("CmdOrCtrl+P", "Cmd+P"), ("Shift+CmdOrCtrl+Comma", "Shift+Cmd+Comma")] {
            let accelerator = try Accelerator(binding)
            XCTAssertEqual(Strings.shortcutBinding(.accelerator(accelerator)), display)
            XCTAssertEqual(try CarbonHotkeyBackend.translate(accelerator),
                           try CarbonHotkeyBackend.translate(Accelerator(display)))
        }
        XCTAssertFalse(Strings.carbonOverlappingModifiers.contains("CmdOrCtrl"))
    }

    func testCaptureRejectsUnmodifiedModifierOnlyAutorepeatAndUnsupportedKeys() throws {
        for flags: NSEvent.ModifierFlags in [[], .capsLock, .function, .numericPad] {
            XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_ANSI_P, flags: flags)), .ignored)
        }
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_ANSI_P, flags: .command, repeatKey: true)), .ignored)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_Command, flags: .command)), .ignored)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_Shift, flags: .shift, type: .flagsChanged)), .ignored)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(0xFFFF, flags: .control)), .unsupportedKey)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_Help, flags: .command)), .unsupportedKey)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_ANSI_KeypadEnter, flags: .command)), .unsupportedKey)
        XCTAssertEqual(ShortcutRecorderButton.capture(try key(kVK_Escape, flags: .command)), .cancelled)
    }

    func testRecorderForwardsOneChordToModelAndVerificationNeedsRealCallback() throws {
        let harness = ShortcutSettingsHarness()
        let window = recorderWindow()
        defer { window.close() }
        let recorder = try XCTUnwrap(window.contentView as? ShortcutRecorderButton)
        recorder.onCapture = harness.presentation.setAccelerator
        recorder.onError = harness.presentation.captureFailed
        recorder.beginCapture()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.accessibilityLabel(), Strings.recordingShortcut)
        recorder.keyDown(with: try key(kVK_ANSI_K, text: "˚", flags: [.control, .option], window: window))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.accessibilityLabel(), Strings.recordShortcut)
        let binding = try Accelerator("Ctrl+Alt+K")
        XCTAssertEqual(harness.backend.requested.last, binding)
        XCTAssertEqual(harness.presentation.togglePicker.binding, .accelerator(binding))
        XCTAssertEqual(Strings.shortcutBinding(harness.presentation.togglePicker.binding), "Ctrl+Alt+K")
        XCTAssertEqual(harness.presentation.togglePicker.registrationStatus, .registered)
        XCTAssertEqual(harness.presentation.togglePicker.changePath, .inApp)
        XCTAssertEqual(harness.presentation.togglePicker.verification, .notStarted)
        XCTAssertEqual(harness.presentation.repeatLast.binding, .unbound)
        XCTAssertEqual(harness.presentation.repeatLast.changePath, .unavailable)
        XCTAssertEqual(harness.presentation.repeatLast.registrationStatus, .unbound)
        XCTAssertNil(harness.backend.current[.repeatLast])
        harness.presentation.beginVerification()
        XCTAssertEqual(harness.presentation.togglePicker.verification, .waiting)
        harness.presentation.refresh()
        XCTAssertEqual(harness.presentation.togglePicker.verification, .waiting)
        harness.backend.fire?()
        XCTAssertEqual(harness.presentation.togglePicker.verification, .verified)
    }

    func testEscapeAndCommandEquivalentStayLocalAndCaptureStopsOnCloseOrDetach() throws {
        let window = recorderWindow()
        defer { window.close() }
        let recorder = try XCTUnwrap(window.contentView as? ShortcutRecorderButton)
        var captures: [String] = []
        recorder.onCapture = { captures.append($0) }
        window.orderFrontRegardless()
        recorder.beginCapture()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key(kVK_Escape, window: window)))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(window.isVisible, "Escape cancels capture without closing its window")
        XCTAssertTrue(captures.isEmpty)
        recorder.beginCapture()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key(kVK_ANSI_Comma, flags: .command, window: window)))
        XCTAssertEqual(captures, ["Cmd+Comma"])
        recorder.beginCapture()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(recorder.isRecording)
        recorder.beginCapture()
        recorder.removeFromSuperview()
        XCTAssertFalse(recorder.isRecording)
        window.contentView = recorder
        recorder.beginCapture()
        window.close()
        XCTAssertFalse(recorder.isRecording, "Closing a reused window must remove capture even if it is not key")
    }

    func testNativeMonitorConsumesEscapeAndCommandChordBeforeTheMainMenu() throws {
        let oldMenu = NSApp.mainMenu
        let menuTarget = RecorderMenuTarget()
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: Strings.settings, action: #selector(RecorderMenuTarget.openSettings),
                                      keyEquivalent: ",")
        settings.target = menuTarget
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        let window = recorderWindow()
        defer { window.close(); NSApp.mainMenu = oldMenu }
        let recorder = try XCTUnwrap(window.contentView as? ShortcutRecorderButton)
        var captures: [String] = []
        recorder.onCapture = { captures.append($0) }
        try makeRecorderKey(window)
        recorder.beginCapture()
        postAndDispatch(try key(kVK_Escape, text: "\u{1b}", window: window))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(captures.isEmpty)
        recorder.beginCapture()
        postAndDispatch(try key(kVK_ANSI_Comma, text: ",", flags: .command, window: window))
        XCTAssertEqual(captures, ["Cmd+Comma"])
        XCTAssertEqual(menuTarget.opens, 0, "Capture must intercept Command before menu dispatch")
        XCTAssertFalse(recorder.isRecording)
        postAndDispatch(try key(kVK_ANSI_Comma, text: ",", flags: .command, window: window))
        XCTAssertEqual(menuTarget.opens, 1, "After capture, the normal menu equivalent works again")
    }

    func testMonitorPassesTabRepeatsAndFlagChangesAndConsumesCaptureEvents() throws {
        let window = recorderWindow()
        defer { window.close() }
        let recorder = try XCTUnwrap(window.contentView as? ShortcutRecorderButton)
        try makeRecorderKey(window)
        recorder.beginCapture()
        let ignored = [try key(kVK_Tab, text: "\t", window: window),
                       try key(kVK_ANSI_P, flags: .command, repeatKey: true, window: window),
                       try key(kVK_Shift, flags: .shift, type: .flagsChanged, window: window)]
        for event in ignored {
            XCTAssertTrue(recorder.monitoredEvent(event) === event)
            XCTAssertTrue(recorder.isRecording)
        }
        XCTAssertFalse(recorder.performKeyEquivalent(with: ignored[0]), "Tab keeps its native responder path")
        var errors: [ShortcutRebindError] = []
        var captures: [String] = []
        recorder.onError = { errors.append($0) }
        recorder.onCapture = { captures.append($0) }
        XCTAssertNil(recorder.monitoredEvent(try key(kVK_Help, flags: .command, window: window)))
        XCTAssertEqual(errors, [.unsupportedCarbonKey])
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNil(recorder.monitoredEvent(try key(kVK_Escape, window: window)))
        XCTAssertFalse(recorder.isRecording)
        recorder.beginCapture()
        XCTAssertNil(recorder.monitoredEvent(try key(kVK_ANSI_Comma, flags: .command, window: window)))
        XCTAssertEqual(captures, ["Cmd+Comma"])
        XCTAssertFalse(recorder.isRecording)
        let normal = try key(kVK_ANSI_Comma, flags: .command, window: window)
        XCTAssertTrue(recorder.monitoredEvent(normal) === normal)
    }

    func testUnsupportedCarbonKeysAndOverlappingCommandAliasesShowTypedErrorsWithoutLosingOldKey() throws {
        let harness = ShortcutSettingsHarness()
        let original = try XCTUnwrap(harness.backend.current[.togglePicker])
        let requests = harness.backend.requested.count
        for text in ["Ctrl+F21", "Ctrl+F22", "Ctrl+F23", "Ctrl+F24", "Ctrl+Insert", "Cmd+PrintScreen"] {
            harness.presentation.setAccelerator(text)
            XCTAssertEqual(harness.presentation.shortcutError, .unsupportedCarbonKey, text)
            XCTAssertEqual(harness.presentation.displayedShortcutError, Strings.carbonUnsupportedKey)
            XCTAssertEqual(harness.backend.current[.togglePicker], original)
        }
        for text in ["Cmd+Super+P", "Cmd+CmdOrCtrl+P", "Super+CmdOrCtrl+P"] {
            harness.presentation.setAccelerator(text)
            XCTAssertEqual(harness.presentation.shortcutError, .overlappingCommandModifiers)
            XCTAssertEqual(harness.presentation.displayedShortcutError, Strings.carbonOverlappingModifiers)
            XCTAssertEqual(harness.backend.current[.togglePicker], original)
        }
        harness.presentation.setAccelerator("Ctrl+")
        XCTAssertEqual(harness.presentation.shortcutError, .invalidAccelerator(.malformed))
        XCTAssertEqual(harness.presentation.displayedShortcutError, Strings.invalidShortcut)
        XCTAssertEqual(harness.backend.requested.count, requests)
        XCTAssertEqual(harness.presentation.togglePicker.registrationStatus, .registered)
    }

    func testBackendFailureDropsPreviousBindingAndDisplaysFailedStatusAndDetail() throws {
        let harness = ShortcutSettingsHarness()
        let original = try XCTUnwrap(harness.backend.current[.togglePicker])
        let staleFire = harness.backend.fire
        harness.backend.status = .failed
        harness.backend.detail = Strings.carbonRegistrationFailure(status: -9878)
        harness.presentation.setAccelerator("Ctrl+Alt+K")
        XCTAssertEqual(harness.backend.unregistered, [original])
        XCTAssertNotEqual(harness.backend.current[.togglePicker]?.id, original.id)
        XCTAssertEqual(harness.presentation.togglePicker.binding, .unknown)
        XCTAssertEqual(harness.presentation.togglePicker.registrationStatus, .failed)
        XCTAssertEqual(Strings.registrationStatus(try XCTUnwrap(harness.presentation.togglePicker.registrationStatus)), "Failed")
        XCTAssertEqual(harness.presentation.togglePicker.registration?.detail, harness.backend.detail)
        XCTAssertEqual(harness.presentation.togglePicker.verification, .notStarted)
        XCTAssertNil(harness.presentation.shortcutError, "Native failure is a backend status, not a parse error")
        XCTAssertFalse(harness.presentation.canVerifyShortcut)
        staleFire?()
        XCTAssertEqual(harness.activations, 0, "The removed registration cannot fire after the failed rebind")
        harness.presentation.beginVerification()
        XCTAssertEqual(harness.presentation.togglePicker.verification, .notStarted)
        harness.backend.status = .registered
        harness.backend.detail = Strings.carbonRegistered
        harness.presentation.setAccelerator("Ctrl+Alt+P")
        XCTAssertEqual(harness.presentation.togglePicker.binding, .accelerator(try Accelerator("Ctrl+Alt+P")))
        XCTAssertEqual(harness.presentation.togglePicker.registrationStatus, .registered)
        XCTAssertEqual(harness.presentation.togglePicker.verification, .notStarted)
    }

    private func recorderWindow() -> NSWindow {
        // Like the picker host, this panel can become key while its app is
        // inactive. Regular NSWindow activation is unreliable in hosted CI.
        let window = RecorderTestPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = ShortcutRecorderButton(frame: .zero)
        return window
    }

    private func makeRecorderKey(_ window: NSWindow) throws {
        window.orderFrontRegardless()
        window.makeKey()
        let deadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        _ = try XCTUnwrap(window.isKeyWindow ? window : nil, "Non-activating recorder panel could not become key")
    }

    private func postAndDispatch(_ event: NSEvent) {
        // Exercise the application event queue so the installed local monitor
        // participates before normal key-equivalent/responder dispatch.
        NSApp.postEvent(event, atStart: true)
        while let next = NSApp.nextEvent(matching: [.keyDown, .flagsChanged], until: .distantPast,
                                        inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
    }

    private func key(_ code: Int, text: String = "", flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
                     type: NSEvent.EventType = .keyDown, window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: UInt16(code)))
    }
}

private final class RecorderTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RecorderMenuTarget: NSObject {
    private(set) var opens = 0
    @objc func openSettings() { opens += 1 }
}

/// The real Core graph with a deterministic Carbon-shaped backend. No native
/// registration, clipboard, permission prompt or external application is used.
private final class ShortcutSettingsHarness {
    let backend = SettingsHotkeyBackend()
    let presentation: SettingsViewState
    private(set) var activations = 0

    init() {
        let main = DispatchMainThread()
        let scheduler = SettingsShortcutScheduler()
        let ports = SettingsShortcutPorts(backend: backend)
        let shortcuts = ShortcutService(backend: backend, scheduler: scheduler, mainThread: main)
        let delivery = DeliveryService(panel: ports, focus: ports, clipboard: ports, injectors: [], notifier: ports,
            session: ports, scheduler: scheduler, mainThread: main, failureCache: SessionPasteFailureCache())
        let selfTest = SelfTest(target: ports, delivery: delivery, session: ports, scheduler: scheduler, mainThread: main)
        let setup = SetupService(probe: ports, session: ports, shortcuts: shortcuts, selfTest: selfTest, mainThread: main)
        let model = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
        let settings = SettingsModel(settings: SettingsService(store: SettingsStore(files: UnavailableFileStore())))
        let general = GeneralSettingsModel(settings: settings, library: ports, mainThread: main)
        presentation = SettingsViewState(general: general, shortcuts: model, mainThread: main, openSetup: {})
        shortcuts.configure([.togglePicker: Accelerator.defaultBinding(for: .togglePicker)!]) { [weak self] _ in
            self?.activations += 1
        }
    }
}

private final class SettingsHotkeyBackend: HotkeyBackend {
    let mechanism = HotkeyMechanism.carbon
    var status = RegistrationStatus.registered
    var detail = Strings.carbonRegistered
    private(set) var requested: [Accelerator] = []
    private(set) var current: [HotkeyAction: HotkeyRegistration] = [:]
    private(set) var unregistered: [HotkeyRegistration] = []
    private(set) var fire: (() -> Void)?
    let unbound = HotkeyRegistration(mechanism: .carbon, status: .unbound, detail: SetupStrings.unboundShortcut)

    func register(_ action: HotkeyAction, accelerator: Accelerator, onFire: @escaping () -> Void) -> HotkeyRegistration {
        requested.append(accelerator)
        let registration = HotkeyRegistration(mechanism: .carbon, status: status, detail: detail)
        current[action] = registration
        fire = status == .registered ? onFire : nil
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
        unregistered.append(registration)
        current = current.filter { $0.value != registration }
        fire = nil
    }
}

private struct SettingsShortcutScheduler: MonkeysPawCore.Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {}
}

private final class SettingsShortcutPorts: PanelWindow, FocusTracker, Clipboard, Notifier, SessionProbe,
                                           SetupProbe, SelfTestTarget, LibraryLocationControl {
    private let backend: SettingsHotkeyBackend
    init(backend: SettingsHotkeyBackend) { self.backend = backend }
    func show() {}
    func hideForDelivery() {}
    func hide() {}
    func captureTarget() -> DeliveryTarget? { nil }
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) { completion(.unconfirmed) }
    func writeText(_ text: String) {}
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
    func copied() {}
    func pressPaste(chord: PasteChord, reason: CopyReason) {}
    func currentSession() -> DesktopSession { .macOS }
    func accessibilityStatus() -> SetupStatus { .ok }
    func portalStatus() -> SetupStatus { .notApplicable }
    func ydotoolStatus() -> SetupStatus { .notApplicable }
    func hotkeyRegistration() -> HotkeyRegistration { backend.current[.togglePicker] ?? backend.unbound }
    func kdeStatus() -> SetupStatus { .notApplicable }
    func performFix(for kind: SetupRow.Kind, done: @escaping () -> Void) { done() }
    func present(fieldExpecting text: String) {}
    func readBack() -> String? { nil }
    func close() {}
    var activeLibraryPath: String { "/default" }
    var defaultLibraryPath: String { "/default" }
    func switchLibrary(to path: String?) -> LibrarySwitchOutcome { .switched }
    func revealLibrary() {}
}
