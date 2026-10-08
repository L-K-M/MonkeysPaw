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

    func testFixIntentRoutesEveryActionableKindToProbe() {
        let table: [(DesktopSession, SetupRow.Kind)] = [
            (.macOS, .accessibility),
            (.gnomeWayland, .portal),
            (.wlroots, .ydotool),
            (.kdeWayland, .hotkey),
            (.kdeWayland, .kde),
        ]
        for (session, kind) in table {
            let h = Harness(session: session)
            h.probe.accessibility = .needsAction(fix: "Allow Accessibility")
            h.probe.portal = .needsAction(fix: "Allow portal access")
            h.probe.ydotool = .needsAction(fix: "Enable ydotoold")
            h.model.refresh()

            h.model.fix(kind)

            XCTAssertEqual(h.probe.fixes, [kind], "\(session): \(kind)")
        }
    }

    func testFixCompletionRefreshesRowsThroughMainThread() {
        let h = Harness(session: .macOS, mainMode: .deferred)
        h.probe.accessibility = .needsAction(fix: "Allow Accessibility")
        h.probe.fixMode = .deferred
        h.delivery.main.drain()
        var changes = 0
        h.model.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }

        h.model.fix(.accessibility)
        XCTAssertTrue(h.probe.fixes.isEmpty)
        h.delivery.main.drain()
        XCTAssertEqual(h.probe.fixes, [.accessibility])
        guard !h.probe.fixes.isEmpty else { return }
        XCTAssertEqual(changes, 0)

        h.probe.accessibility = .ok
        let hops = h.delivery.main.hops
        h.probe.completeFix()
        XCTAssertEqual(h.delivery.main.hops, hops + 1)
        XCTAssertEqual(h.status(.accessibility), .needsAction(fix: "Allow Accessibility"))
        XCTAssertEqual(changes, 0)

        h.delivery.main.drain()
        XCTAssertEqual(h.status(.accessibility), .ok)
        XCTAssertEqual(changes, 1)
    }

    func testFixIgnoresOKAndNotApplicableRows() throws {
        let h = Harness(session: .kdeWayland)
        h.probe.portal = .ok
        h.probe.ydotool = .ok
        h.probe.kde = .ok
        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        h.model.beginHotkeyVerification()
        h.backend.fire()
        XCTAssertEqual(h.status(.accessibility), .notApplicable)
        XCTAssertEqual(h.status(.hotkey), .ok)

        for kind in SetupRow.Kind.allCases { h.model.fix(kind) }

        XCTAssertTrue(h.probe.fixes.isEmpty)
    }

    func testFixChecksCurrentSnapshotAndAllowsUnknownRows() {
        let statuses: [SetupStatus] = [.ok, .notApplicable, .unknown]
        for status in statuses {
            let h = Harness(session: .macOS)
            h.probe.accessibility = .needsAction(fix: "Allow Accessibility")
            h.model.refresh()
            h.probe.accessibility = status

            h.model.fix(.accessibility)

            XCTAssertEqual(h.probe.fixes, status == .unknown ? [.accessibility] : [], "\(status)")
        }
    }

    func testDuplicateFixCompletionRefreshesOnce() {
        let h = Harness(session: .macOS, mainMode: .deferred)
        h.probe.fixMode = .deferred
        h.delivery.main.drain()
        var changes = 0
        h.model.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        h.model.fix(.accessibility)
        h.delivery.main.drain()
        XCTAssertEqual(h.probe.fixes, [.accessibility])
        guard !h.probe.fixes.isEmpty else { return }
        let queries = h.probe.queried.count

        h.probe.accessibility = .ok
        h.probe.completeFix(times: 2)
        XCTAssertEqual(changes, 0)
        h.delivery.main.drain()

        XCTAssertEqual(h.status(.accessibility), .ok)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(h.probe.queried.count, queries + 2)
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

    func testCurrentRegistrationFailureOverridesEarlierVerification() throws {
        let h = Harness(session: .gnomeWayland)
        h.shortcuts.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        let registered = try XCTUnwrap(h.shortcuts.registrations[.togglePicker])
        h.probe.hotkey = registered
        h.model.beginHotkeyVerification()
        h.backend.fire()
        XCTAssertEqual(h.status(.hotkey), .ok)

        let fix = "Reconnect the shortcuts portal"
        h.probe.hotkey = HotkeyRegistration(
            id: registered.id, mechanism: registered.mechanism, status: .failed, detail: fix
        )
        h.model.refresh()
        XCTAssertEqual(h.status(.hotkey), .needsAction(fix: fix))
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
        XCTAssertEqual(states, [.testing, .tested(report), .tested(report)])
        XCTAssertEqual(h.delivery.injectors[.ydotool]?.chords.count, 1)
    }

    func testSelfTestNotifiesTestedStateBeforeDeferredRefresh() {
        let h = Harness(session: .wlroots, mainMode: .deferred)
        h.delivery.target.received = [DeliveryStrings.testPrompt]
        h.delivery.main.drain()
        var states: [SetupModel.State] = []
        var statuses: [SetupStatus?] = []
        h.model.onChange = {
            XCTAssertTrue(h.delivery.main.isRunning)
            states.append(h.model.state)
            statuses.append(h.status(.ydotool))
        }

        h.delivery.main.run { h.model.runSelfTest() }
        h.delivery.main.drain()
        XCTAssertEqual(states, [.testing])
        h.delivery.scheduler.advance(by: Limits.settleDelayLinux)
        h.delivery.main.drain()
        h.probe.ydotool = .ok
        h.delivery.scheduler.advance(by: Limits.selfTestReadBackDelay)
        XCTAssertEqual(h.model.state, .testing)
        XCTAssertEqual(states, [.testing])

        h.delivery.main.drain()

        let report = SelfTestReport(session: .wlroots, results: [
            SelfTestResult(backend: .ydotool, status: .pasted),
        ])
        XCTAssertEqual(states, [.testing, .tested(report), .tested(report)])
        XCTAssertEqual(statuses, [.unknown, .unknown, .ok])
        XCTAssertEqual(h.model.state, .tested(report))
        XCTAssertEqual(h.status(.ydotool), .ok)
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
