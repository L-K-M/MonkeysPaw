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
                       nativeBudget: Duration = Limits.kglobalaccelTimeout) {
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
        XCTAssertTrue(GTKTestSupport.spin {
            (self.daemon.present && self.native.currentRegistration.status != .needsAction)
                || (self.backend.mechanism == .globalShortcutsPortal
                    && self.backend.currentRegistration.configuration == .attachPortal)
        })
    }

    private func configure() {
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 }, events.joined(separator: ","))
        XCTAssertEqual(completions, 1)
    }

    private func fallback() {
        var completions = 0
        backend.useNative { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertEqual(completions, 1)
    }

    private func session() throws -> String {
        try XCTUnwrap(service.sessionOwners.keys.first)
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
            start()
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
