import MonkeysPawCore
import XCTest

final class PanelModelTests: XCTestCase {
    func testConfirmDeliversCannedPromptAndTransitionsThroughDelivering() {
        let h = DeliveryHarness()
        h.arm()
        let model = PanelModel(delivery: h.service)
        var states: [PanelModel.State] = []
        model.onChange = { states.append(model.state) }
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.prompt, "Monkey's Paw test: if you can read this, delivery works.")
        model.confirm(mode: .paste(.terminal))
        XCTAssertEqual(model.state, .delivering)
        XCTAssertEqual(h.clipboard.readText(), model.prompt)
        model.confirm(mode: .paste(.standard))
        model.cancel()
        XCTAssertEqual(h.scheduler.delays.count, 1)
        XCTAssertFalse(h.recorder.events.contains(.hide))
        h.settle()
        XCTAssertEqual(model.state, .done(.pasted(.cgEvent)))
        XCTAssertEqual(states, [.delivering, .done(.pasted(.cgEvent))])
        XCTAssertEqual(h.injectors[.cgEvent]?.chords, [.terminal])
    }

    func testCopyIntentAndReopeningResetTheModel() {
        let h = DeliveryHarness()
        let model = PanelModel(delivery: h.service)
        model.show()
        model.confirm(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(model.state, .done(.copiedOnly(.requested)))
        model.show()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(h.injectors.values.allSatisfy { $0.chords.isEmpty })
    }

    func testCancelHidesAndRestoresWithoutWritingClipboard() throws {
        let h = DeliveryHarness()
        let model = PanelModel(delivery: h.service)
        model.show()
        h.recorder.events.removeAll()
        model.cancel()
        XCTAssertEqual(h.recorder.events, [.hide, .restore(try XCTUnwrap(h.focus.target))])
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(h.clipboard.readText())
    }

    func testFallbackOutcomeAndOnChangeReturnThroughMainThread() {
        let h = DeliveryHarness(session: .wlroots)
        h.injectors[.ydotool]?.result = .failed(.toolMissing)
        let model = PanelModel(delivery: h.service)
        var state: PanelModel.State?
        model.onChange = { XCTAssertTrue(h.main.isRunning); state = model.state }
        h.main.run { model.confirm(mode: .paste(.standard)) }
        h.settle()
        XCTAssertEqual(state, .done(.copiedOnly(.backendsFailed([
            BackendFailure(backend: .ydotool, reason: .toolMissing),
        ]))))
    }
}

final class SetupModelTests: XCTestCase {
    private struct Harness {
        let delivery: DeliveryHarness
        let probe: FakeSetupProbe
        let backend: FakeHotkeyBackend
        let shortcuts: ShortcutService
        let model: SetupModel

        init(session: DesktopSession, mainMode: FakeCompletionMode = .immediate) {
            delivery = DeliveryHarness(session: session)
            delivery.main.mode = mainMode
            probe = FakeSetupProbe()
            backend = FakeHotkeyBackend()
            shortcuts = ShortcutService(backend: backend, scheduler: delivery.scheduler, mainThread: delivery.main)
            let test = SelfTest(target: delivery.target, delivery: delivery.service,
                                session: delivery.session, scheduler: delivery.scheduler, mainThread: delivery.main)
            let setup = SetupService(probe: probe, session: delivery.session,
                                     shortcuts: shortcuts, selfTest: test, mainThread: delivery.main)
            model = SetupModel(setup: setup)
        }

        func status(_ kind: SetupRow.Kind) -> SetupStatus? {
            model.rows.first(where: { $0.kind == kind })?.status
        }
    }

    func testPermissionRowsComeFromProbeAndUnknownIsRetained() {
        let h = Harness(session: .macOS)
        XCTAssertEqual(h.status(.accessibility), .unknown)
        h.probe.accessibility = .needsAction(fix: "Grant Accessibility in System Settings")
        h.model.refresh()
        XCTAssertEqual(h.model.session, .macOS)
        XCTAssertEqual(h.model.rows.map(\.kind), SetupRow.Kind.allCases)
        XCTAssertEqual(h.status(.accessibility), h.probe.accessibility)
        XCTAssertEqual(h.status(.portal), .notApplicable)
        XCTAssertEqual(h.status(.ydotool), .notApplicable)
        XCTAssertEqual(h.status(.kde), .notApplicable)
        XCTAssertEqual(Set(h.probe.queried), [.accessibility, .hotkey])
    }

    func testApplicabilityMatchesAllLinuxSessionLaddersIncludingFlatpakHost() {
        let table: [(DesktopSession, SetupStatus, SetupStatus, SetupStatus)] = [
            (.gnomeWayland, .ok, .ok, .notApplicable),
            (.gnomeX11, .ok, .ok, .notApplicable),
            (.kdeWayland, .ok, .ok, .needsAction(fix: SetupStrings.kdeShortcut)),
            (.kdeX11, .ok, .ok, .needsAction(fix: SetupStrings.kdeShortcut)),
            (.otherX11, .notApplicable, .ok, .notApplicable),
            (.wlroots, .notApplicable, .ok, .notApplicable),
            (.flatpak(host: .gnomeWayland), .ok, .notApplicable, .notApplicable),
            (.flatpak(host: .kdeWayland), .ok, .notApplicable, .needsAction(fix: SetupStrings.kdeShortcut)),
        ]
        for (session, portal, ydotool, kde) in table {
            let h = Harness(session: session)
            h.probe.portal = .ok
            h.probe.ydotool = .ok
            h.model.refresh()
            XCTAssertEqual(h.status(.accessibility), .notApplicable)
            XCTAssertEqual(h.status(.portal), portal, "\(session)")
            XCTAssertEqual(h.status(.ydotool), ydotool, "\(session)")
            XCTAssertEqual(h.status(.kde), kde, "\(session)")
        }
    }

    func testHotkeyRowOnlyTurnsGreenAfterRequestedVerificationFires() throws {
        let h = Harness(session: .gnomeWayland)
        h.probe.hotkey = HotkeyRegistration(mechanism: .globalShortcutsPortal, status: .registered, detail: "Bound")
        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: SetupStrings.pressShortcut))
        XCTAssertEqual(h.model.rows.first(where: { $0.kind == .hotkey })?.registration, h.probe.hotkey)
        h.backend.fire()
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: SetupStrings.pressShortcut))
        h.model.beginHotkeyVerification()
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: SetupStrings.pressShortcut))
        h.backend.fire()
        XCTAssertEqual(h.status(.hotkey), .ok)

        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+E")]) { _ in }
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: SetupStrings.pressShortcut))
    }

    func testManualRegistrationExposesTheFixAndCanStillBeVerified() throws {
        let h = Harness(session: .wlroots)
        h.backend.mechanism = .manual
        h.backend.status = .needsAction
        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: h.probe.hotkey.detail))
        h.model.beginHotkeyVerification()
        h.backend.fire()
        XCTAssertEqual(h.status(.hotkey), .ok)
        h.probe.hotkey = HotkeyRegistration(mechanism: .manual, status: .unbound, detail: "Unbound")
        h.model.refresh()
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: SetupStrings.assignShortcut))
    }

    func testSelfTestStateTransitionsAndDuplicateIntentsDoNotRerunIt() {
        let h = Harness(session: .wlroots)
        h.delivery.target.received = [DeliveryStrings.testPrompt]
        var states: [SetupModel.State] = []
        h.model.onChange = { states.append(h.model.state); XCTAssertTrue(h.delivery.main.isRunning) }
        XCTAssertEqual(h.model.state, .idle)
        h.delivery.main.run { h.model.runSelfTest() }
        h.model.runSelfTest()
        XCTAssertEqual(h.model.state, .testing)
        h.delivery.scheduler.advance(by: .milliseconds(640))
        let report = SelfTestReport(session: .wlroots, results: [
            SelfTestResult(backend: .ydotool, status: .pasted),
        ])
        XCTAssertEqual(h.model.state, .tested(report))
        XCTAssertEqual(states, [.testing, .tested(report)])
        XCTAssertEqual(h.delivery.injectors[.ydotool]?.chords.count, 1)
    }

    func testQueuedProbingStartsUnknownThenPublishesOnMainThread() {
        let h = Harness(session: .kdeWayland, mainMode: .deferred)
        XCTAssertNil(h.model.session)
        XCTAssertTrue(h.model.rows.allSatisfy { $0.status == .unknown })
        var changes = 0
        h.model.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.delivery.main.drain()
        XCTAssertEqual(h.model.session, .kdeWayland)
        XCTAssertEqual(changes, 1)
    }
}
