#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class KDEPortalHotkeyTests: XCTestCase {
    private var daemon: FakeKGlobalAccel!
    private var service: FakePortal!
    private var transport: LinuxPortalTransport!
    private var native: KGlobalAccelHotkeyBackend!
    private var portal: PortalHotkeyBackend!
    private var backend: KDEPortalHotkeyBackend!
    private var tools: FakeLinuxTools!
    private var store: KDEHotkeyChoiceStore!
    private var events: [String] = []
    private var fires = 0
    private var repeatFires = 0
    private var repeatTokens: [String?] = []
    private var tokens: [String?] = []
    private var parents: [(PortalParent) -> Void] = []
    private var holdParent = false
    private var parentCloses = 0
    private var address = ""

    override func setUpWithError() throws {
        address = try FakePortal.requirePrivateBus()
        daemon = try FakeKGlobalAccel(address: address)
        try daemon.ownName()
        daemon.events = { [weak self] in self?.events.append($0) }
        service = try FakePortal(address: address)
        service.behavior = .sessions
        service.kde = daemon
        try service.ownName()
        transport = LinuxPortalTransport(busAddress: address)
        tools = try PortalSessionTestSupport.tools()
        store = KDEHotkeyChoiceStore(paths: LinuxPaths(environment: tools.environment))
    }

    override func tearDown() {
        backend?.shutdown()
        backend = nil
        transport?.shutdown()
        service?.shutdown()
        native = nil
        portal = nil
        daemon?.shutdown()
        tools = nil
    }

    private func start(budget: Duration = Limits.portalConsentTimeout,
                       nativeBudget: Duration = Limits.kglobalaccelTimeout, bothActions: Bool = false) {
        native = KGlobalAccelHotkeyBackend(busAddress: address, callBudget: nativeBudget)
        portal = PortalHotkeyBackend(transport: transport, fallback: ManualHotkeyBackend(),
            runner: tools.runner, migration: .none, mainThread: GLibMainThread()) { [weak self] done in
                guard let self else { return }
                if self.holdParent { self.parents.append(done) }
                else { done(PortalParent("x11:1234") { [weak self] in self?.parentCloses += 1 }) }
            }
        backend = KDEPortalHotkeyBackend(native: native, portal: portal,
            transport: transport, choices: store, consentBudget: budget)
        _ = backend.register(.togglePicker, accelerator: Accelerator.defaultBinding(for: .togglePicker)!) { [weak self] in
            guard let self else { return }
            self.fires += 1
            self.tokens.append(self.backend.consumeActivationToken())
        }
        if bothActions { _ = declareRepeat() }
        XCTAssertTrue(GTKTestSupport.spin {
            (self.daemon.present && self.native.currentRegistration.status != .needsAction
                && (!bothActions || self.native.registration(for: .repeatLast).status != .needsAction))
                || (self.backend.mechanism == .globalShortcutsPortal
                    && self.backend.currentRegistration.configuration == .attachPortal)
        })
    }

    @discardableResult
    private func declareRepeat() -> HotkeyRegistration {
        backend.register(.repeatLast, accelerator: nil) { [weak self] in
            guard let self else { return }
            self.repeatFires += 1
            let live: LinuxHotkeyBackend = self.backend
            self.repeatTokens.append(live.consumeActivationToken(for: .repeatLast))
        }
    }

    private func activateRepeat(_ timestamp: UInt64 = 1, session oldSession: String? = nil) throws {
        let handle = try oldSession ?? session()
        service.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 \(timestamp), {'activation_token': <'repeat-token'>})")
        PortalSessionTestSupport.barrier(transport)
    }

    private func configure() {
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 }, events.joined(separator: ","))
        XCTAssertEqual(completions, 1)
    }

    private func fallback(timeout: Duration = .seconds(3)) {
        var completions = 0
        backend.useNative { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin(until: { completions == 1 }, timeout: timeout))
        XCTAssertEqual(completions, 1)
    }

    private func session() throws -> String {
        try XCTUnwrap(service.sessionOwners.keys.first)
    }

    func testBothActionsSurviveCreateFullBindAndAcknowledgedNativeRecovery() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108939, 67108931, 0, 0],), ([268435538],), ([],)]"
        let repeatKeys = daemon.keys(for: "repeat")
        start()
        var repeats = 0
        let repeatAction = backend.register(.repeatLast, accelerator: nil) { repeats += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.backend.registration(for: .repeatLast).status == .registered })
        let picker = backend.currentRegistration.id
        configure()
        XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
        XCTAssertTrue(daemon.presentActions.isEmpty)
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        service.emit(member: "Activated", body: "(objectpath '\(try session())', 'repeat', uint64 7, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeats, 1)
        fallback()
        XCTAssertEqual(daemon.presentActions, ["toggle", "repeat"])
        XCTAssertTrue(daemon.portalPresentActions.isEmpty)
        XCTAssertEqual(backend.currentRegistration.id, picker)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.presentActions.isEmpty })
        XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
        XCTAssertEqual(daemon.savedKeys, "@a(ai) [([201326672],)]")
    }

    func testBothActionKeyMatrixSurvivesPortalNativeAndRestart() throws {
        let choices = ["@a(ai) [([67108933],)]", "@a(ai) [(@ai [],), ([0, 0, 0, 0],)]",
                       "@a(ai) [(@ai [],), ([67108939, 67108931, 0, 0],), ([268435536],)]"]
        for (index, pickerKeys) in choices.enumerated() {
            let repeatKeys = choices[(index + 1) % choices.count]
            daemon.actionNames = ["toggle", "repeat"]
            daemon.savedKeys = pickerKeys
            daemon.additionalKeys["repeat"] = repeatKeys
            start(bothActions: true)
            let picker = backend.currentRegistration.id
            let repeatAction = backend.registration(for: .repeatLast).id
            configure()
            XCTAssertTrue(daemon.removedActions.isEmpty)
            XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
            let bind = try XCTUnwrap(service.calls.last { $0.method == "BindShortcuts" })
            XCTAssertFalse(bind.text(1).contains("preferred_trigger"))
            for action in HotkeyAction.allCases {
                let name = action == .togglePicker ? "toggle" : "repeat"
                XCTAssertEqual(backend.registration(for: action).status, daemon.hasBinding(for: name) ? .registered : .unbound)
            }
            fallback()
            XCTAssertEqual(backend.currentRegistration.id, picker)
            XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction)
            XCTAssertEqual(daemon.savedKeys, pickerKeys)
            XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { self.daemon.presentActions.isEmpty })
            backend = nil
            start(bothActions: true)
            XCTAssertEqual(daemon.presentActions, ["toggle", "repeat"])
            XCTAssertEqual(backend.registration(for: .repeatLast).mechanism, .kglobalaccel)
            XCTAssertEqual(store.load(), .loaded(.native))
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { self.daemon.presentActions.isEmpty })
            backend = nil
        }
    }

    func testSavedRepeatAloneSelectsNativeAndUndeclaredRepeatIsNeverOmittedFromBind() throws {
        daemon.actionNames = ["repeat"]
        daemon.savedKeys = "@a(ai) []"
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start()
        XCTAssertEqual(backend.mechanism, .kglobalaccel)
        XCTAssertTrue(service.calls.isEmpty)
        configure()
        let bind = try XCTUnwrap(service.calls.last { $0.method == "BindShortcuts" })
        XCTAssertTrue(bind.text(1).contains("'repeat'"))
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        _ = declareRepeat()
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        try activateRepeat()
        XCTAssertEqual(repeatFires, 1)
        XCTAssertEqual(repeatTokens.last!, "repeat-token")
    }

    func testMissingSavedUndeclaredRepeatFromListBlocksDestructiveBind() {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start()
        service.responses["ListShortcuts"] = "(uint32 0, {'shortcuts': <[('toggle', {'trigger_description': <'Saved'>})]>})"
        configure()
        XCTAssertFalse(service.calls.contains { $0.method == "BindShortcuts" })
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        XCTAssertFalse(daemon.present)
        XCTAssertFalse(daemon.portalPresent)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
    }

    func testLateRepeatDeclarationCannotAuthorizeABindThatOmittedItsSavedKeys() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start()
        service.responses["ListShortcuts"] = "(uint32 0, {'shortcuts': <[('toggle', {'trigger_description': <'Saved'>})]>})"
        holdParent = true
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.parents.count == 1 })
        _ = declareRepeat()
        let parent = try XCTUnwrap(parents.first)
        parent(PortalParent("x11:1234") {})
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertFalse(service.calls.contains { $0.method == "BindShortcuts" })
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        XCTAssertFalse(daemon.present)
        XCTAssertFalse(daemon.portalPresent)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
    }

    func testOldAttachedCatalogueExpandsOnlyThroughExplicitFullHandoff() throws {
        for version: UInt32 in [1, 2] {
            service.versions["org.freedesktop.portal.GlobalShortcuts"] = version
            start()
            configure()
            let previous = try session()
            let calls = service.calls.count
            let repeatAction = declareRepeat()
            XCTAssertEqual(service.calls.count, calls)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
            configure()
            XCTAssertTrue(service.closedPaths.contains(previous))
            XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.last?.text(1).contains("'repeat'"), true)
            XCTAssertTrue(daemon.removedActions.isEmpty)
            XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
            XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) []")
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
            backend = nil
            // Restore an old one-action daemon catalogue for the next version.
            daemon.actionNames = ["toggle"]
            daemon.additionalKeys.removeAll()
        }
    }

    func testBothAcknowledgementsPrecedeCreateAndRepeatRaceWhileSuspendingBlocksHandoff() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        daemon.heldMethods = ["setInactive"]
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.last?.method == "setInactive" && self.daemon.calls.last?.actionName == "toggle" })
        daemon.reply(try XCTUnwrap(daemon.calls.last))
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.last?.method == "setInactive" && self.daemon.calls.last?.actionName == "repeat" })
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(completions, 0)
        daemon.emit()
        daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
        daemon.change("@a(ai) [([67108934],)]", action: "repeat")
        daemon.reply(try XCTUnwrap(daemon.calls.last))
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertTrue(daemon.presentActions.isEmpty)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108934],)]")
    }

    func testSecondSuspensionTimeoutCannotCreateOrRouteEitherAction() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(nativeBudget: .milliseconds(150), bothActions: true)
        daemon.heldMethods = ["setInactive"]
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.last?.method == "setInactive" && self.daemon.calls.last?.actionName == "toggle" })
        daemon.reply(try XCTUnwrap(daemon.calls.last))
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.last?.method == "setInactive" && self.daemon.calls.last?.actionName == "repeat" })
        let late = try XCTUnwrap(daemon.calls.last)
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        daemon.reply(late)
        daemon.emit()
        daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
    }

    func testRepeatKeyChangesBeforeAndAfterBindFailClosedWithoutRewritingKeys() throws {
        for stage in ["ListShortcuts", "BindShortcuts"] {
            daemon.actionNames = ["toggle", "repeat"]
            daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
            start(bothActions: true)
            let edited = "@a(ai) [([67108939, 67108931, 0, 0],), ([268435538],)]"
            service.handleCall = { call in
                if call.method == stage { self.daemon.additionalKeys["repeat"] = edited }
                return false
            }
            configure()
            XCTAssertEqual(daemon.keys(for: "repeat"), edited)
            XCTAssertTrue(daemon.removedActions.isEmpty)
            XCTAssertFalse(daemon.present)
            XCTAssertFalse(daemon.portalPresent)
            XCTAssertEqual(backend.currentRegistration.status, .failed)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
            if stage == "ListShortcuts" {
                XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.count, 0)
            }
            daemon.emit()
            daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
            PortalSessionTestSupport.barrier(transport)
            XCTAssertEqual(fires, 0)
            XCTAssertEqual(repeatFires, 0)
            service.handleCall = nil
            backend.shutdown()
            backend = nil
        }
    }

    func testBothRoutesStayDisabledAfterCreateOrCloseTimeout() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(budget: .milliseconds(500), bothActions: true)
        service.handleCall = { call in
            guard call.method == "CreateSession" else { return false }
            self.daemon.portalCreate()
            self.service.reply(call)
            return true
        }
        configure()
        XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
        let registrations = daemon.calls.filter { $0.method == "doRegister" }.count
        fallback()
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, registrations)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        daemon.emit()
        daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertNil(backend.consumeActivationToken(for: .repeatLast))
        XCTAssertEqual(store.load(), .loaded(.portal))
        backend.shutdown()
        backend = nil
        service.handleCall = nil
        // The fixture's uncertain session has no handle; model owner cleanup.
        daemon.portalClose()
        start(bothActions: true)
        configure()
        let session = try session()
        service.holdSessionClose = true
        fallback(timeout: .seconds(6))
        XCTAssertTrue(service.closedPaths.contains(session))
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        try activateRepeat(session: session)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertNil(backend.consumeActivationToken(for: .repeatLast))
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        service.releaseSessionCloses()
    }

    func testBothPortalEventsTokensAndRestartRequireExplicitReconfigurationAfterRemoval() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        configure()
        let oldSession = try session()
        let picker = backend.currentRegistration
        let repeatAction = backend.registration(for: .repeatLast)
        try activate(7)
        try activateRepeat(7)
        try activate(7)
        try activateRepeat(7)
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(repeatFires, 1)
        XCTAssertEqual(tokens.last!, "fixture-token")
        XCTAssertEqual(repeatTokens.last!, "repeat-token")
        let calls = service.calls.count
        let revision = backend.activationRevision
        let nativeRegistrationsBeforeRemoval = daemon.calls.filter { $0.method == "doRegister" }.count
        service.holdSessionClose = true
        backend.unregister(repeatAction)
        XCTAssertFalse(portal.isAttached)
        XCTAssertNotEqual(backend.activationRevision, revision)
        XCTAssertEqual(backend.currentRegistration.id, picker.id)
        XCTAssertEqual(backend.currentRegistration.status, .needsAction)
        XCTAssertEqual(backend.currentRegistration.configuration, .attachPortal)
        let replacement = declareRepeat()
        XCTAssertEqual(replacement.id, repeatAction.id)
        XCTAssertEqual(replacement.status, .needsAction)
        XCTAssertEqual(replacement.configuration, .attachPortal)
        daemon.emit()
        daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
        var inspected = false
        native.inspect { _ in inspected = true }
        XCTAssertTrue(GTKTestSupport.spin { inspected })
        XCTAssertTrue(daemon.presentActions.isEmpty)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, nativeRegistrationsBeforeRemoval)
        try activateRepeat(7)
        XCTAssertEqual(repeatFires, 1)
        try activateRepeat(8)
        try activate(8)
        XCTAssertEqual(repeatFires, 1)
        XCTAssertEqual(fires, 1)
        XCTAssertNil(backend.consumeActivationToken())
        XCTAssertNil(backend.consumeActivationToken(for: .repeatLast))
        XCTAssertEqual(service.calls.count, calls)
        XCTAssertTrue(service.closedPaths.contains(oldSession))
        var completions = 0
        backend.configure { completions += 1 }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(service.calls.count, calls, "Fresh configuration must wait for acknowledged Close.")
        service.holdSessionClose = false
        service.releaseSessionCloses()
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(service.calls.suffix(3).map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(backend.registration(for: .repeatLast), repeatAction)
        XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
        XCTAssertTrue(daemon.presentActions.isEmpty)
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertEqual(daemon.savedKeys, "@a(ai) [([201326672],)]")
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        try activate(7)
        try activateRepeat(7)
        try activate(7)
        try activateRepeat(7)
        XCTAssertEqual(fires, 2)
        XCTAssertEqual(repeatFires, 2)
        XCTAssertEqual(tokens.last!, "fixture-token")
        XCTAssertEqual(repeatTokens.last!, "repeat-token")
        let callsAfterReconfiguration = service.calls.count
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
        backend = nil
        let nativeRegistrations = daemon.calls.filter { $0.method == "doRegister" }.count
        start(bothActions: true)
        XCTAssertEqual(backend.registration(for: .repeatLast).mechanism, .globalShortcutsPortal)
        XCTAssertEqual(backend.registration(for: .repeatLast).configuration, .attachPortal)
        XCTAssertEqual(service.calls.count, callsAfterReconfiguration)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, nativeRegistrations)
        try activateRepeat(9, session: oldSession)
        XCTAssertEqual(repeatFires, 2)
        XCTAssertNil(backend.consumeActivationToken(for: .repeatLast))
    }

    func testRemovingEitherPortalActionBlocksDestructiveSubsetBindUntilRedeclaration() throws {
        for version: UInt32 in [1, 2] {
            service.versions["org.freedesktop.portal.GlobalShortcuts"] = version
            for removed in HotkeyAction.allCases {
                daemon.actionNames = ["toggle", "repeat"]
                daemon.additionalKeys["repeat"] = "@a(ai) [([67108939, 67108931, 0, 0],), ([268435538],), ([],)]"
                let pickerKeys = daemon.savedKeys
                let repeatKeys = daemon.keys(for: "repeat")
                start(bothActions: true)
                configure()
                let oldSession = try session()
                let remaining: HotkeyAction = removed == .togglePicker ? .repeatLast : .togglePicker
                let remainingID = backend.registration(for: remaining).id
                let removedID = backend.registration(for: removed).id
                let binds = service.calls.filter { $0.method == "BindShortcuts" }.count
                let calls = service.calls.count
                let nativeRegistrations = daemon.calls.filter { $0.method == "doRegister" }.count
                backend.unregister(backend.registration(for: removed))
                XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
                XCTAssertTrue(service.closedPaths.contains(oldSession))
                XCTAssertFalse(portal.isAttached)
                XCTAssertEqual(service.calls.count, calls)
                XCTAssertEqual(backend.registration(for: removed).status, .unbound)
                XCTAssertEqual(backend.registration(for: removed).configuration, .unavailable)
                XCTAssertEqual(backend.registration(for: remaining).id, remainingID)
                XCTAssertEqual(backend.registration(for: remaining).status, .needsAction)
                XCTAssertEqual(backend.registration(for: remaining).configuration, .attachPortal)
                configure()
                XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.count, binds)
                XCTAssertEqual(backend.registration(for: remaining).status, .failed)
                XCTAssertTrue(daemon.presentActions.isEmpty)
                XCTAssertTrue(daemon.portalPresentActions.isEmpty)
                XCTAssertTrue(daemon.removedActions.isEmpty)
                XCTAssertEqual(daemon.savedKeys, pickerKeys)
                XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
                XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, nativeRegistrations)
                if removed == .repeatLast { _ = declareRepeat() }
                else {
                    _ = backend.register(.togglePicker, accelerator: nil) { [weak self] in
                        guard let self else { return }
                        self.fires += 1
                        self.tokens.append(self.backend.consumeActivationToken())
                    }
                }
                XCTAssertEqual(backend.registration(for: removed).id, removedID)
                configure()
                let bind = try XCTUnwrap(service.calls.last { $0.method == "BindShortcuts" })
                XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.count, binds + 1)
                XCTAssertTrue(bind.text(1).contains("'toggle'"))
                XCTAssertTrue(bind.text(1).contains("'repeat'"))
                XCTAssertFalse(bind.text(1).contains("preferred_trigger"))
                XCTAssertTrue(HotkeyAction.allCases.allSatisfy { backend.registration(for: $0).status == .registered })
                let pickerFires = fires
                let repeats = repeatFires
                try activate(17)
                try activateRepeat(17)
                XCTAssertEqual(fires, pickerFires + 1)
                XCTAssertEqual(repeatFires, repeats + 1)
                XCTAssertEqual(daemon.savedKeys, pickerKeys)
                XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
                backend.shutdown()
                XCTAssertTrue(GTKTestSupport.spin { self.daemon.portalPresentActions.isEmpty && self.daemon.presentActions.isEmpty })
                XCTAssertTrue(daemon.removedActions.isEmpty)
                XCTAssertFalse(daemon.calls.contains { $0.method == "doUnregister" || $0.method == "cleanUp" })
                XCTAssertEqual(daemon.savedKeys, pickerKeys)
                XCTAssertEqual(daemon.keys(for: "repeat"), repeatKeys)
                backend = nil
            }
        }
    }

    func testPortalIntentRestartStillObservesDaemonLossWithoutNativeRegistrations() throws {
        try store.save(.portal)
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        configure()
        let oldSession = try session()
        XCTAssertFalse(daemon.calls.contains { $0.method == "doRegister" })
        daemon.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
        try activateRepeat(session: oldSession)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertNil(backend.consumeActivationToken(for: .repeatLast))
    }

    func testReplacementPortalCanAttachButNativeStillWaitsForKnownSessionClose() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        configure()
        service.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        service = try FakePortal(address: address)
        service.behavior = .sessions
        service.kde = daemon
        try service.ownName()
        let registrations = daemon.calls.filter { $0.method == "doRegister" }.count
        fallback()
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, registrations)

        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
        XCTAssertTrue(daemon.removedActions.isEmpty)
        guard backend.currentRegistration.status == .registered else { return }
        let handle = try session()
        service.holdSessionClose = true
        var completions = 0
        backend.useNative { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.service.closedPaths.contains(handle) })
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(daemon.present)
        try activateRepeat()
        XCTAssertEqual(repeatFires, 0)
        service.releaseSessionCloses()
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertEqual(daemon.presentActions, ["toggle", "repeat"])
        XCTAssertFalse(daemon.portalPresent)
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
    }

    func testUnboundResponseSubsetDoesNotShrinkTheDeclaredPortalCatalogue() throws {
        for version: UInt32 in [1, 2] {
            service.versions["org.freedesktop.portal.GlobalShortcuts"] = version
            daemon.actionNames = ["toggle", "repeat"]
            daemon.additionalKeys["repeat"] = "@a(ai) []"
            service.responses["BindShortcuts"] = "(uint32 0, {'shortcuts': <[('toggle', {'trigger_description': <'Saved KDE choice'>})]>})"
            start(bothActions: true)
            configure()
            let handle = try session()
            let calls = service.calls.count
            let closes = service.closedPaths
            XCTAssertTrue(portal.hasCompleteCatalogue)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
            service.emit(member: "ShortcutsChanged", body: "(objectpath '\(handle)', [('toggle', {'trigger_description': <'Edited picker'>})])")
            PortalSessionTestSupport.barrier(transport)
            XCTAssertTrue(portal.hasCompleteCatalogue)
            configure()
            XCTAssertEqual(service.calls.count, calls)
            XCTAssertEqual(try session(), handle)
            XCTAssertEqual(service.closedPaths, closes)
            XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) []")
            if version == 2 { XCTAssertEqual(service.ordinaryCalls.last?.method, "ConfigureShortcuts") }
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
            backend = nil
        }
    }

    func testOwnerLossDuringCloseRetainsExplicitPortalRecovery() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        configure()
        let oldSession = try session()
        service.holdSessionClose = true
        var completions = 0
        backend.useNative { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.service.closedPaths.contains(oldSession) })
        service.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        service = try FakePortal(address: address)
        service.behavior = .sessions
        service.kde = daemon
        try service.ownName()
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(daemon.portalPresentActions, ["toggle", "repeat"])
        XCTAssertEqual(daemon.keys(for: "repeat"), "@a(ai) [([67108933],)]")
        XCTAssertEqual(completions, 1)
    }

    func testRetiringPickerKeepsRepeatMechanismCorrectAcrossNativeHandoff() throws {
        daemon.actionNames = ["toggle", "repeat"]
        daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
        start(bothActions: true)
        configure()
        backend.unregister(backend.currentRegistration)
        let repeatAction = backend.registration(for: .repeatLast)
        fallback()
        XCTAssertEqual(backend.mechanism, .kglobalaccel)
        XCTAssertEqual(backend.registration(for: .repeatLast).mechanism, .kglobalaccel)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(daemon.presentActions, ["repeat"])
        daemon.emit(body: "('ch.lkmc.monkeyspaw', 'repeat', int64 42)")
        XCTAssertTrue(GTKTestSupport.spin { self.repeatFires == 1 })
        XCTAssertEqual(daemon.savedKeys, "@a(ai) [([201326672],)]")
    }

    func testUnboundRepeatDeclarationPreservesNativePickerAndStartsNoPortalInteraction() throws {
        start()
        let picker = backend.currentRegistration
        let calls = daemon.calls.count
        let repeatAction = backend.register(.repeatLast, accelerator: nil) { XCTFail("Repeat adapter is unbound") }
        XCTAssertTrue(GTKTestSupport.spin { self.backend.registration(for: .repeatLast).status == .unbound })
        XCTAssertNotEqual(repeatAction.id, picker.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(backend.currentRegistration, picker)
        let revision = backend.activationRevision
        backend.unregister(repeatAction)
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(backend.activationRevision, revision)
        XCTAssertGreaterThan(daemon.calls.count, calls)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.map(\.actionName), ["toggle", "repeat"])
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(daemon.present)
        daemon.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
    }

    func testStoppedCompositeRejectsAllDeclarationsAndUnregisterCannotRestartIt() throws {
        start()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        PortalSessionTestSupport.barrier(transport)
        let stopped = backend.currentRegistration
        let revision = backend.activationRevision
        let nativeCalls = daemon.calls.count
        let portalCalls = service.calls.count
        let propertyCalls = service.propertyCalls.filter { $0.interface == "org.freedesktop.portal.GlobalShortcuts" }.count
        backend.unregister(stopped)
        for action in HotkeyAction.allCases {
            for accelerator in [nil, try Accelerator("Alt+R")] as [Accelerator?] {
                weak var callbackOwner: NSObject?
                do {
                    let owner = NSObject()
                    callbackOwner = owner
                    let rejected = backend.register(action, accelerator: accelerator) { _ = owner.description }
                    XCTAssertEqual(rejected.status, .unbound)
                    XCTAssertEqual(rejected.configuration, .unavailable)
                    XCTAssertEqual(rejected, backend.unboundActions.registration(for: action, mechanism: backend.mechanism))
                    if action == .repeatLast { XCTAssertNotEqual(rejected.id, stopped.id) }
                }
                XCTAssertNil(callbackOwner)
            }
        }
        var completions = 0
        backend.configure { completions += 1 }
        backend.useNative { completions += 1 }
        backend.shutdown()
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 2)
        XCTAssertEqual(backend.currentRegistration, stopped)
        XCTAssertEqual(backend.activationRevision, revision)
        XCTAssertEqual(daemon.calls.count, nativeCalls)
        XCTAssertEqual(service.calls.count, portalCalls)
        XCTAssertEqual(service.propertyCalls.filter { $0.interface == "org.freedesktop.portal.GlobalShortcuts" }.count, propertyCalls)
        XCTAssertEqual(fires, 0)
    }

    func testUnregisterCannotRestoreNativeOrPortalPickerThroughConfiguration() {
        start()
        backend.unregister(backend.currentRegistration)
        let cleared = backend.currentRegistration
        XCTAssertEqual(cleared.status, .unbound)
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        PortalSessionTestSupport.barrier(transport)
        let nativeCalls = daemon.calls.count
        let portalCalls = service.calls.count
        var completions = 0
        backend.configure { completions += 1 }
        backend.useNative { completions += 1 }
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 2)
        XCTAssertEqual(backend.currentRegistration, cleared)
        XCTAssertEqual(daemon.calls.count, nativeCalls)
        XCTAssertEqual(service.calls.count, portalCalls)
        XCTAssertEqual(fires, 0)
    }

    func testRepeatedUnregisterBeforeUnboundDeclarationDoesNotRepeatNativeOrPortalCalls() throws {
        start()
        configure()
        let handle = try session()
        let picker = backend.currentRegistration
        backend.unregister(picker)
        XCTAssertTrue(GTKTestSupport.spin { self.service.closedPaths.contains(handle) && !self.daemon.present })
        PortalSessionTestSupport.barrier(transport)
        let nativeMethods = daemon.calls.map(\.method)
        let portalMethods = service.calls.map(\.method)
        let closes = service.closedPaths

        backend.unregister(picker)
        let cleared = backend.currentRegistration
        var completions = 0
        backend.configure { completions += 1 }
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(cleared.status, .unbound)
        XCTAssertEqual(daemon.calls.map(\.method), nativeMethods)
        XCTAssertEqual(service.calls.map(\.method), portalMethods)
        XCTAssertEqual(service.closedPaths, closes)
        XCTAssertFalse(daemon.present)
    }

    func testShutdownFromPendingCompletionPreventsClearFromRetainingCompositeCallback() {
        start()
        var completions = 0
        backend.configure { self.backend.shutdown(); completions += 1 }
        weak var callbackOwner: NSObject?
        do {
            let owner = NSObject()
            callbackOwner = owner
            _ = backend.register(.togglePicker, accelerator: nil) { _ = owner.description }
        }

        XCTAssertEqual(completions, 1)
        XCTAssertNil(callbackOwner)
        let stopped = backend.currentRegistration
        backend.configure { completions += 1 }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(backend.currentRegistration, stopped)
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
    }

    func testLiveRegistrationAfterUnboundDeclarationStillTearsDownUsingInitialSnapshot() throws {
        start()
        backend.unregister(backend.currentRegistration)
        let unbound = backend.currentRegistration
        XCTAssertEqual(unbound.status, .unbound)
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        let pending = backend.register(.togglePicker,
            accelerator: Accelerator.defaultBinding(for: .togglePicker)) { [weak self] in self?.fires += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .registered })
        XCTAssertEqual(backend.currentRegistration.id, pending.id)
        XCTAssertTrue(daemon.present)

        // ShortcutService owns the initial result, before the driver's live
        // status changes. Its old unbound catalogue must not claim teardown.
        backend.unregister(pending)

        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        XCTAssertTrue(service.calls.isEmpty)
    }

    private func activate(_ timestamp: UInt64 = 1) throws {
        service.emit(member: "Activated", body: "(objectpath '\(try session())', 'toggle', uint64 \(timestamp), {'activation_token': <'fixture-token'>})")
        PortalSessionTestSupport.barrier(transport)
    }

    func testV1AndV2StartupPreserveNativeUntilExplicitHandoff() throws {
        for version: UInt32 in [1, 2] {
            service.versions["org.freedesktop.portal.GlobalShortcuts"] = version
            let callsBeforeStartup = service.calls.count
            start()
            XCTAssertEqual(backend.mechanism, .kglobalaccel)
            XCTAssertEqual(backend.currentRegistration.configuration, .attachPortal)
            XCTAssertEqual(backend.currentRegistration.alternativeConfiguration, .nativeFallback)
            XCTAssertEqual(service.calls.count, callsBeforeStartup)
            XCTAssertTrue(tools.arguments.isEmpty)
            let id = backend.currentRegistration.id
            let nativeFires = fires
            daemon.emit()
            XCTAssertTrue(GTKTestSupport.spin { self.fires == nativeFires + 1 })
            let before = fires
            configure()
            XCTAssertEqual(backend.currentRegistration.id, id)
            XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
            XCTAssertEqual(backend.currentRegistration.status, .registered)
            XCTAssertFalse(daemon.present)
            XCTAssertTrue(daemon.portalPresent)
            let inactive = try XCTUnwrap(events.firstIndex(of: "setInactive"))
            let create = try XCTUnwrap(events.firstIndex(of: "portal.CreateSession"))
            XCTAssertLessThan(inactive, create)
            daemon.emit()
            try activate(UInt64(version))
            XCTAssertEqual(fires, before + 1)
            XCTAssertEqual(tokens.last!, "fixture-token")
            try activate(UInt64(version))
            XCTAssertEqual(fires, before + 1)
            XCTAssertNil(backend.consumeActivationToken())
            XCTAssertEqual(service.calls.suffix(3).map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
            XCTAssertTrue(daemon.removedActions.isEmpty)
            fallback()
            XCTAssertTrue(daemon.present)
            XCTAssertFalse(daemon.portalPresent)
            XCTAssertEqual(store.load(), .loaded(.native))
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
            backend = nil
            events.removeAll()
        }
    }

    func testAbsentCapabilityRetainsNativeWithoutPortalInteraction() {
        service.versions["org.freedesktop.portal.GlobalShortcuts"] = 0
        start()
        configure()
        XCTAssertEqual(backend.mechanism, .kglobalaccel)
        XCTAssertEqual(backend.currentRegistration.configuration, .systemSettings)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(store.load(), .absent)
    }

    func testFreshSupportedPathOnlyOffersPortalAndSuggestsDefaultOnBind() throws {
        daemon.componentExists = false
        daemon.actionNames = []
        daemon.savedKeys = "@a(ai) []"
        daemon.foreignHolders = [.init(component: "foreign-app", action: "toggle", keys: [[201326672]])]
        start()
        XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
        XCTAssertFalse(daemon.registered)
        XCTAssertFalse(daemon.present)
        XCTAssertTrue(service.calls.isEmpty)
        configure()
        let bind = try XCTUnwrap(service.calls.last)
        let args = g_variant_get_child_value(bind.parameters, 1)!
        defer { g_variant_unref(args) }
        let printed = g_variant_print(args, 1)!
        defer { g_free(printed) }
        XCTAssertTrue(String(cString: printed).contains("preferred_trigger"))
        XCTAssertEqual(backend.currentRegistration.status, .unbound)
        XCTAssertEqual(daemon.foreignHolders.count, 1)
        service.emit(member: "ShortcutsChanged", body: "(objectpath '\(try session())', [('toggle', {'trigger_description': <'Super+E'>})])")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .registered })
        XCTAssertEqual(store.load(), .loaded(.portal))
    }

    func testCustomUnboundAndCompleteAlternativesSurviveSharedDaemonHandoff() throws {
        for keys in ["@a(ai) [([67108933],)]", "@a(ai) []", "@a(ai) [([67108931, 67108932, 0, 0],), ([268435536],), ([],)]"] {
            daemon.savedKeys = keys
            start()
            configure()
            XCTAssertEqual(daemon.savedKeys, keys)
            XCTAssertTrue(daemon.removedActions.isEmpty)
            XCTAssertEqual(backend.currentRegistration.status, keys == "@a(ai) []" ? .unbound : .registered)
            let bind = try XCTUnwrap(service.calls.last)
            let args = g_variant_get_child_value(bind.parameters, 1)!
            let printed = g_variant_print(args, 1)!
            XCTAssertFalse(String(cString: printed).contains("preferred_trigger"))
            g_free(printed)
            g_variant_unref(args)
            fallback()
            XCTAssertEqual(daemon.savedKeys, keys)
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
            backend = nil
        }
    }

    func testUnknownActionsAndContextsBlockWithoutComponentMutation() {
        for extraContext in [false, true] {
            daemon.actionNames = extraContext ? ["toggle"] : ["toggle", "foreign-action"]
            daemon.contexts = extraContext ? ["default", "foreign-context"] : ["default"]
            daemon.additionalKeys = ["foreign-action": "@a(ai) [([67108931, 67108932],)]"]
            daemon.additionalKeys["repeat"] = "@a(ai) [([67108933],)]"
            start(bothActions: true)
            let mutations = daemon.calls.filter { $0.method == "setShortcutKeys" }.count
            configure()
            XCTAssertTrue(daemon.present)
            XCTAssertTrue(service.calls.isEmpty)
            XCTAssertEqual(daemon.calls.filter { $0.method == "setShortcutKeys" }.count, mutations)
            XCTAssertTrue(daemon.removedActions.isEmpty)
            XCTAssertEqual(daemon.additionalKeys["foreign-action"], "@a(ai) [([67108931, 67108932],)]")
            XCTAssertEqual(store.load(), .absent)
            daemon.emit()
            XCTAssertTrue(GTKTestSupport.spin { self.fires > 0 })
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
            backend = nil
        }
    }

    func testUnknownActionAppearingAfterCreateBlocksBindAndPreservesForeignState() {
        start()
        service.handleCall = { call in
            if call.method == "ListShortcuts" { self.daemon.actionNames.append("foreign-action") }
            return false
        }
        configure()
        XCTAssertEqual(service.calls.map(\.method), ["CreateSession", "ListShortcuts"])
        XCTAssertEqual(daemon.actionNames, ["toggle", "foreign-action"])
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertFalse(daemon.present)
        XCTAssertFalse(daemon.portalPresent)
        fallback()
        XCTAssertTrue(daemon.present)
        XCTAssertEqual(daemon.actionNames, ["toggle", "foreign-action"])
    }

    func testUnknownActionAddedDuringParentExportBlocksBind() throws {
        start()
        holdParent = true
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.parents.count == 1 })
        daemon.actionNames.append("foreign-during-export")
        let parent = try XCTUnwrap(parents.first)
        parent(PortalParent("wayland:fixture") { self.parentCloses += 1 })
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertFalse(service.calls.contains { $0.method == "BindShortcuts" })
        XCTAssertTrue(daemon.actionNames.contains("foreign-during-export"))
        XCTAssertTrue(daemon.removedActions.isEmpty)
        XCTAssertFalse(daemon.portalPresent)
        XCTAssertEqual(parentCloses, 1)
    }

    func testDaemonOwnerLossWhilePortalSelectedQuiescesAndRejectsOldEvents() throws {
        start()
        configure()
        daemon.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        let fires = fires
        try activate()
        XCTAssertEqual(self.fires, fires)
        XCTAssertNil(backend.consumeActivationToken())
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
        let replacement = try FakeKGlobalAccel(address: address)
        defer { replacement.shutdown() }
        try replacement.ownName()
        fallback()
        daemon.emit()
        replacement.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == fires + 1 })
    }

    func testDeferredDaemonLossCannotCancelQueuedReregistration() throws {
        start()
        configure()
        try activate()
        let id = backend.currentRegistration.id
        let oldSession = try session()
        let registrations = daemon.calls.filter { $0.method == "doRegister" }.count
        let creates = service.calls.filter { $0.method == "CreateSession" }.count
        var failures: [String] = []
        backend.onChange = {
            if self.backend.currentRegistration.status == .failed {
                failures.append(self.backend.currentRegistration.detail)
            }
        }
        service.holdSessionClose = true

        // GDBus loss runs at default priority, ahead of Core's already queued
        // GLibMainThread idle. Hold idles until loss queues its later cleanup;
        // this deterministically models a ready bus event overtaking UI work.
        var idleBarrier = g_idle_add_full(G_PRIORITY_HIGH_IDLE, { _ in 1 }, nil, nil)
        defer { if idleBarrier != 0 { g_source_remove(idleBarrier) } }
        var reregistered = false
        let reconfiguration = GTK.onMainLoop {
            // ShortcutService.configure replaces registrations in this order.
            self.backend.unregister(self.backend.currentRegistration)
            _ = self.backend.register(.togglePicker,
                accelerator: Accelerator.defaultBinding(for: .togglePicker)!) {
                    self.fires += 1
                    self.tokens.append(self.backend.consumeActivationToken())
                }
            reregistered = true
        }
        defer { if !reregistered { g_source_remove(reconfiguration) } }
        daemon.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.native.currentRegistration.status == .failed })
        XCTAssertFalse(reregistered)
        g_source_remove(idleBarrier)
        idleBarrier = 0

        XCTAssertTrue(GTKTestSupport.spin {
            reregistered && self.service.closedPaths.contains(oldSession)
        })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        XCTAssertEqual(backend.currentRegistration.status, .needsAction)
        XCTAssertEqual(backend.currentRegistration.configuration, .attachPortal)
        XCTAssertEqual(backend.currentRegistration.id, id)
        XCTAssertEqual(store.load(), .loaded(.portal))
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, registrations)

        let replacement = try FakeKGlobalAccel(address: address)
        defer { replacement.shutdown() }
        replacement.events = { [weak self] in self?.events.append($0) }
        try replacement.ownName()
        var completions = 0
        backend.configure { completions += 1 }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(service.calls.filter { $0.method == "CreateSession" }.count, creates)
        XCTAssertFalse(daemon.present)
        XCTAssertFalse(replacement.registered)
        XCTAssertFalse(replacement.portalPresent)
        daemon.emit()
        replacement.emit()
        try activate(2)
        XCTAssertEqual(fires, 1)
        XCTAssertNil(backend.consumeActivationToken())

        service.releaseSessionCloses()
        XCTAssertFalse(daemon.portalPresent)
        service.kde = replacement
        service.holdSessionClose = false
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        guard backend.currentRegistration.status == .registered else { return }
        XCTAssertEqual(backend.currentRegistration.id, id)
        XCTAssertFalse(replacement.present)
        XCTAssertTrue(replacement.portalPresent)
        XCTAssertEqual(service.calls.filter { $0.method == "CreateSession" }.count, creates + 1)
        let close = try XCTUnwrap(events.firstIndex(of: "portal.Close"))
        let create = try XCTUnwrap(events.lastIndex(of: "portal.CreateSession"))
        XCTAssertLessThan(close, create)
        daemon.emit()
        replacement.emit()
        try activate() // The replacement session may reuse the old timestamp.
        XCTAssertEqual(fires, 2)
        XCTAssertEqual(tokens.last!, "fixture-token")
        try activate()
        XCTAssertEqual(fires, 2)
        XCTAssertNil(backend.consumeActivationToken())

        fallback()
        XCTAssertFalse(replacement.portalPresent)
        XCTAssertTrue(replacement.present)
        daemon.emit()
        try activate(3)
        XCTAssertEqual(fires, 2)
        replacement.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 3 })
        XCTAssertNil(tokens.last!)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        XCTAssertEqual(completions, 1)
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !replacement.present })
    }

    func testFullKeysChangedDuringCreateAreNotReconstructedOrBound() {
        start()
        service.handleCall = { call in
            if call.method == "ListShortcuts" {
                self.daemon.savedKeys = "@a(ai) [([67108931, 67108932, 0, 0],), ([268435536],)]"
            }
            return false
        }
        configure()
        XCTAssertFalse(service.calls.contains { $0.method == "BindShortcuts" })
        XCTAssertEqual(daemon.savedKeys, "@a(ai) [([67108931, 67108932, 0, 0],), ([268435536],)]")
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertFalse(daemon.portalPresent)
    }

    func testInspectionTimeoutLeavesNativeChoiceAndLateReplyCannotCreatePortal() throws {
        start(nativeBudget: .milliseconds(300))
        daemon.heldMethods = ["shortcutNames"]
        configure()
        XCTAssertTrue(daemon.present)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(store.load(), .absent)
        let late = try XCTUnwrap(daemon.calls.last { $0.method == "shortcutNames" })
        daemon.reply(late)
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(service.calls.isEmpty)
        daemon.emit()
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
    }

    func testSaveFailureRetainsNativeAndCorruptRecordNeedsExplicitRepair() throws {
        let file = LinuxPaths(environment: tools.environment).dataDirectory.appendingPathComponent("shortcut-mechanism.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        start()
        configure()
        XCTAssertTrue(daemon.present)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        try FileManager.default.removeItem(at: file)
        try Data("{\"mechanism\":\"unknown\"}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        backend = nil
        start()
        XCTAssertTrue(daemon.present)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertTrue(service.calls.isEmpty)
        fallback()
        XCTAssertEqual(store.load(), .loaded(.native))
        XCTAssertEqual(backend.currentRegistration.status, .registered)
    }

    func testCoupledFixtureExposesCreateReactivationAndOmittedActionDeletion() {
        daemon.actionNames = ["toggle", "foreign-action"]
        daemon.additionalKeys = ["foreign-action": "@a(ai) [([67108931, 67108932],)]"]
        start()
        portal.beforeBind = nil // Exercise the actual hazard without the guard.
        var done = false
        portal.configure { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
        XCTAssertTrue(daemon.portalPresent)
        XCTAssertEqual(daemon.removedActions, ["foreign-action"])
        XCTAssertNil(daemon.additionalKeys["foreign-action"])
        XCTAssertEqual(daemon.actionNames, ["toggle"])
        XCTAssertEqual(events.filter { $0.hasPrefix("portal.") }, ["portal.CreateSession", "portal.BindShortcuts"])
    }

    func testAcknowledgedSuspensionPrecedesCreateAndFailureKeepsPortalClosed() throws {
        start()
        daemon.heldMethods = ["setInactive"]
        var done = 0
        backend.configure { done += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.last?.method == "setInactive" })
        XCTAssertTrue(service.calls.isEmpty)
        daemon.emit()
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 0)
        let inactive = try XCTUnwrap(daemon.calls.last)
        daemon.reply(inactive)
        XCTAssertTrue(GTKTestSupport.spin { done == 1 })
        XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
        fallback()
        daemon.errors = ["setInactive"]
        daemon.heldMethods.removeAll()
        let count = service.calls.count
        configure()
        XCTAssertEqual(service.calls.count, count)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertFalse(daemon.portalPresent)
    }

    func testEarlierNativeFailureCleanupStillNeedsAcknowledgementBeforeCreate() throws {
        start()
        daemon.heldMethods = ["setInactive"]
        daemon.errors = ["globalShortcutsByKey"]
        daemon.change(daemon.savedKeys)
        XCTAssertTrue(GTKTestSupport.spin { self.native.currentRegistration.status == .failed })
        var done = 0
        backend.configure { done += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.daemon.calls.filter { $0.method == "setInactive" }.count == 2 })
        XCTAssertTrue(service.calls.isEmpty)
        let awaited = try XCTUnwrap(daemon.calls.last { $0.method == "setInactive" })
        daemon.reply(awaited)
        XCTAssertTrue(GTKTestSupport.spin { done == 1 })
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertFalse(daemon.present)
        XCTAssertTrue(daemon.portalPresent)
    }

    func testFallbackWaitsForCloseAndFailedCleanupCannotActivateNative() throws {
        start()
        configure()
        service.holdSessionClose = true
        let nativeActivations = daemon.calls.filter { $0.method == "doRegister" }.count
        var done = 0
        backend.useNative { done += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.service.closedPaths.contains(try! self.session()) })
        XCTAssertEqual(done, 0)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, nativeActivations)
        try activate()
        XCTAssertEqual(fires, 0)
        XCTAssertNil(backend.consumeActivationToken())
        service.releaseSessionCloses()
        XCTAssertTrue(GTKTestSupport.spin { done == 1 })
        XCTAssertTrue(daemon.present)
        let close = try XCTUnwrap(events.firstIndex(of: "portal.Close"))
        let register = try XCTUnwrap(events.lastIndex(of: "doRegister"))
        XCTAssertLessThan(close, register)
        configure()
        service.holdSessionClose = false
        service.closeError = true
        fallback()
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertEqual(store.load(), .loaded(.portal))
    }

    func testDenialAndCancellationNeverInstallFallbackAndRequireExplicitNativeIntent() {
        for response in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})"] {
            start()
            service.responses["BindShortcuts"] = response
            let count = daemon.calls.filter { $0.method == "doRegister" }.count
            configure()
            XCTAssertFalse(daemon.present)
            XCTAssertFalse(daemon.portalPresent)
            XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, count)
            XCTAssertEqual(backend.currentRegistration.status, .failed)
            XCTAssertEqual(store.load(), .loaded(.portal))
            fallback()
            XCTAssertTrue(daemon.present)
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
            backend = nil
        }
    }

    func testLostPortalDoesNotAutoActivateNativeAndIgnoresOldSignals() throws {
        start()
        configure()
        let oldSession = try session()
        service.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        daemon.emit()
        service.emit(member: "Activated", body: "(objectpath '\(oldSession)', 'toggle', uint64 4, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(fires, 0)
        XCTAssertNil(backend.consumeActivationToken())
        try service.ownName()
        fallback()
        XCTAssertTrue(daemon.present)
    }

    func testExplicitPortalRetryRechecksCapabilityAndAttachesWithoutNativeActivation() throws {
        try store.save(.portal)
        service.versions["org.freedesktop.portal.GlobalShortcuts"] = 0
        start()
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertFalse(daemon.registered)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        service.versions["org.freedesktop.portal.GlobalShortcuts"] = 1
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
        XCTAssertFalse(daemon.registered)
        XCTAssertEqual(service.calls.map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
        service.emit(member: "Closed", body: "(@a{sv} {},)", path: try session())
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.count, 2)
        XCTAssertFalse(daemon.registered)
    }

    func testConsentDeadlineAndLateParentCannotBindOrVerify() throws {
        start(budget: .milliseconds(500))
        holdParent = true
        var done = 0
        backend.configure { done += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.parents.count == 1 })
        XCTAssertTrue(GTKTestSupport.spin { done == 1 })
        let lateParent = try XCTUnwrap(parents.first)
        lateParent(PortalParent("x11:late") { self.parentCloses += 1 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertFalse(service.calls.contains { $0.method == "BindShortcuts" })
        XCTAssertEqual(done, 1)
        XCTAssertEqual(parentCloses, 1)
        XCTAssertFalse(daemon.present)
        fallback()
        XCTAssertTrue(daemon.present)
    }

    func testUncertainCreateTimeoutFailsClosedEvenOnExplicitFallback() {
        start(budget: .milliseconds(500))
        service.handleCall = { call in
            guard call.method == "CreateSession" else { return false }
            // Source semantics: actions can load before the public Response.
            self.daemon.portalCreate()
            self.service.reply(call)
            return true
        }
        configure()
        XCTAssertTrue(service.calls.contains { $0.method == "CreateSession" },
            "The uncertain-Create case requires CreateSession; methods: \(service.calls.map(\.method))")
        fallback()
        XCTAssertFalse(daemon.present)
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertTrue(backend.currentRegistration.detail.contains("Restart"))
        XCTAssertEqual(store.load(), .loaded(.portal))
    }

    func testRepeatedV1GuidanceAndV2ConfigurationBindOnce() {
        for version: UInt32 in [1, 2] {
            service.versions["org.freedesktop.portal.GlobalShortcuts"] = version
            start()
            configure()
            let binds = service.calls.filter { $0.method == "BindShortcuts" }.count
            configure()
            configure()
            XCTAssertEqual(service.calls.filter { $0.method == "BindShortcuts" }.count, binds)
            if version == 2 { XCTAssertEqual(service.ordinaryCalls.suffix(2).map(\.method), ["ConfigureShortcuts", "ConfigureShortcuts"]) }
            fallback()
            backend.shutdown()
            XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
            backend = nil
        }
    }

    func testRestartRestoresPortalIntentWithoutSessionsAndNativeFallbackPersists() throws {
        start()
        configure()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.portalPresent })
        backend = nil
        let calls = service.calls.count
        let registrations = daemon.calls.filter { $0.method == "doRegister" }.count
        start()
        XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
        XCTAssertEqual(service.calls.count, calls)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, registrations)
        XCTAssertFalse(daemon.present)
        fallback()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.daemon.present })
        backend = nil
        start()
        XCTAssertEqual(backend.mechanism, .kglobalaccel)
        XCTAssertTrue(daemon.present)
        XCTAssertEqual(service.calls.count, calls)
    }

    func testReregistrationWaitsForPendingCloseBeforeConservativeNativeRecovery() throws {
        start()
        configure()
        service.holdSessionClose = true
        let id = backend.currentRegistration.id
        backend.unregister(backend.currentRegistration)
        let file = LinuxPaths(environment: tools.environment).dataDirectory.appendingPathComponent("shortcut-mechanism.json")
        try Data("{\"mechanism\":\"invalid\"}".utf8).write(to: file)
        let registrations = daemon.calls.filter { $0.method == "doRegister" }.count
        var nativeRecovered = false
        backend.onChange = { nativeRecovered = self.backend.mechanism == .kglobalaccel }
        _ = backend.register(.togglePicker, accelerator: Accelerator.defaultBinding(for: .togglePicker)!) { self.fires += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.service.closedPaths.contains(try! self.session()) })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(daemon.calls.filter { $0.method == "doRegister" }.count, registrations)
        XCTAssertFalse(daemon.present)
        service.releaseSessionCloses()
        XCTAssertTrue(GTKTestSupport.spin {
            nativeRecovered && self.daemon.present && self.native.currentRegistration.status != .needsAction
        })
        XCTAssertFalse(daemon.portalPresent)
        XCTAssertEqual(backend.currentRegistration.id, id)
        fallback()
        XCTAssertEqual(store.load(), .loaded(.native))
    }
}
#endif
