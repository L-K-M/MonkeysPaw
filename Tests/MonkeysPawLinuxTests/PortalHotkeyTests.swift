#if os(Linux)
import CGtk
import Foundation
@testable import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class PortalHotkeyTests: XCTestCase {
    private var portal: FakePortal!
    private var transport: LinuxPortalTransport!
    private var tools: FakeLinuxTools!
    private var backend: PortalHotkeyBackend!
    private var fires = 0
    private var repeatFires = 0
    private var registration: HotkeyRegistration!
    private var parentCloses = 0

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        try portal.ownName()
        transport = LinuxPortalTransport(busAddress: address)
        tools = try PortalSessionTestSupport.tools()
        backend = makeBackend()
    }

    private func makeBackend(migration: PortalHotkeyBackend.Migration = .none,
                             fallback: LinuxHotkeyBackend = ManualHotkeyBackend()) -> PortalHotkeyBackend {
        PortalHotkeyBackend(transport: transport, fallback: fallback, runner: tools.runner,
            migration: migration, mainThread: GLibMainThread()) { completion in
                completion(PortalParent("x11:1234") { [weak self] in self?.parentCloses += 1 })
            }
    }

    override func tearDown() {
        backend?.shutdown()
        backend = nil
        transport?.shutdown()
        transport = nil
        portal?.shutdown()
        portal = nil
        tools = nil
    }

    private func register() throws {
        registration = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { [weak self] in
            self?.fires += 1
        }
        PortalSessionTestSupport.barrier(transport)
    }

    private func configure() {
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions > 0 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 1)
    }

    private func session() throws -> String { try XCTUnwrap(portal.sessionOwners.keys.first) }

    private func registerBoth(repeatAccelerator: Accelerator? = nil) throws {
        try register()
        _ = backend.register(.repeatLast, accelerator: repeatAccelerator) { [weak self] in self?.repeatFires += 1 }
        PortalSessionTestSupport.barrier(transport)
    }

    func testTwoActionBindUsesCompleteCatalogueWithoutInventingRepeatPreference() throws {
        try registerBoth()
        let picker = backend.registration(for: .togglePicker)
        let repeatAction = backend.registration(for: .repeatLast)
        XCTAssertNotEqual(picker.id, repeatAction.id)
        XCTAssertTrue(portal.calls.isEmpty)
        configure()
        let bind = try XCTUnwrap(portal.calls.last)
        XCTAssertEqual(portal.shortcuts(bind), [
            PortalShortcut(id: "toggle", properties: ["description": "Open Monkey's Paw", "preferred_trigger": "CTRL+ALT+p"]),
            PortalShortcut(id: "repeat", properties: ["description": "Repeat last prompt"]),
        ])
        XCTAssertEqual(backend.registration(for: .togglePicker).id, picker.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        XCTAssertEqual(backend.registration(for: .repeatLast).configuration, .systemSettings)
        let handle = try session()
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 1, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeatFires, 0)
        configure()
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 1)
        XCTAssertEqual(Set(portal.calls.map(\.sender) + portal.ordinaryCalls.map(\.sender)).count, 1)
    }

    func testExplicitRepeatAcceleratorIsProposedOnlyWhenNoPortalChoiceExists() throws {
        try registerBoth(repeatAccelerator: Accelerator("Alt+R"))
        configure()
        let bind = try XCTUnwrap(portal.calls.last { $0.method == "BindShortcuts" })
        let repeatShortcut = try XCTUnwrap(portal.shortcuts(bind).first { $0.id == "repeat" })
        XCTAssertEqual(repeatShortcut.properties["preferred_trigger"], "ALT+r")
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound,
                       "A proposed key does not confirm a portal binding.")
    }

    func testSavedTwoActionChoicesAreAuthoritativeAndNeverGetPreferredTriggers() throws {
        for saved in ["[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]",
                      "[('toggle', {'trigger_description': <''>}), ('repeat', @a{sv} {})]"] {
            backend.shutdown()
            backend = makeBackend()
            portal.restoredShortcuts = saved
            portal.boundShortcuts = saved
            try registerBoth(repeatAccelerator: Accelerator("Alt+R"))
            configure()
            let requested = portal.shortcuts(try XCTUnwrap(portal.calls.last))
            XCTAssertEqual(requested.map(\.id), ["toggle", "repeat"])
            XCTAssertTrue(requested.allSatisfy { $0.properties["preferred_trigger"] == nil })
            let bound = saved.contains("Super+K")
            XCTAssertEqual(backend.registration(for: .togglePicker).status, bound ? .registered : .unbound)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, bound ? .registered : .unbound)
            if bound {
                XCTAssertEqual(backend.registration(for: .togglePicker).detail, "Super+K")
                XCTAssertEqual(backend.registration(for: .repeatLast).detail, "Alt+R")
                let handle = try session()
                for action in ["toggle", "repeat"] {
                    portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(action)', uint64 17, @a{sv} {})")
                    portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(action)', uint64 17, @a{sv} {})")
                }
                PortalSessionTestSupport.barrier(transport)
                XCTAssertEqual(fires, 1)
                XCTAssertEqual(repeatFires, 1)
            }
        }
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testOldAttachedCatalogueAddsRepeatOnlyOnExplicitFreshSession() throws {
        try register()
        configure()
        let picker = backend.currentRegistration
        let revision = backend.activationRevision
        let methods = portal.calls.map(\.method)
        let repeatAction = backend.register(.repeatLast, accelerator: nil) { [weak self] in self?.repeatFires += 1 }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(backend.activationRevision, revision)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        let old = try session()
        portal.holdSessionClose = true
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(old) })
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(portal.calls.map(\.method), methods, "Fresh creation must await old Close.")
        portal.emit(member: "Activated", body: "(objectpath '\(old)', 'toggle', uint64 1, @a{sv} {})")
        portal.emit(member: "Activated", body: "(objectpath '\(old)', 'repeat', uint64 1, @a{sv} {})")
        portal.releaseSessionCloses()
        XCTAssertTrue(GTKTestSupport.spin { completions > 0 })
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
        XCTAssertNotEqual(backend.activationRevision, revision)
        let binds = portal.calls.filter { $0.method == "BindShortcuts" }
        XCTAssertEqual(binds.count, 2)
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(binds.first)).map(\.id), ["toggle"])
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(binds.last)).map(\.id), ["toggle", "repeat"])
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertTrue(portal.ordinaryCalls.isEmpty)
    }

    func testBothNilDeclarationsCanRestoreSavedChoicesWithoutSuggestions() throws {
        portal.restoredShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        portal.boundShortcuts = portal.restoredShortcuts
        var events: [HotkeyAction] = []
        for action in HotkeyAction.allCases {
            _ = backend.register(action, accelerator: nil) { events.append(action) }
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
        configure()
        let requested = portal.shortcuts(try XCTUnwrap(portal.calls.last))
        XCTAssertEqual(requested.map(\.id), ["toggle", "repeat"])
        XCTAssertEqual(Set(requested.map(\.id)).count, HotkeyAction.allCases.count)
        XCTAssertTrue(requested.allSatisfy { $0.properties["preferred_trigger"] == nil })
        XCTAssertEqual(backend.registration(for: .togglePicker).detail, "Super+K")
        XCTAssertEqual(backend.registration(for: .repeatLast).detail, "Alt+R")
        for shortcut in requested {
            portal.emit(member: "Activated", body: "(objectpath '\(try session())', '\(shortcut.id)', uint64 17, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(events, HotkeyAction.allCases)
    }

    func testSavedRepeatSurvivesBindingBeforeItsCallbackIsDeclared() throws {
        portal.restoredShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        portal.boundShortcuts = portal.restoredShortcuts
        try register()
        configure()
        let requested = portal.shortcuts(try XCTUnwrap(portal.calls.last))
        XCTAssertEqual(requested.map(\.id), ["toggle", "repeat"])
        XCTAssertTrue(requested.allSatisfy { $0.properties["preferred_trigger"] == nil })
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        XCTAssertEqual(backend.registration(for: .repeatLast).configuration, .unavailable)
        let methods = portal.calls.map(\.method)
        let revision = backend.activationRevision
        let repeatAction = backend.register(.repeatLast, accelerator: nil) { [weak self] in self?.repeatFires += 1 }
        XCTAssertEqual(repeatAction.status, .registered)
        XCTAssertEqual(repeatAction.detail, "Alt+R")
        configure()
        XCTAssertEqual(portal.calls.map(\.method), methods)
        XCTAssertEqual(backend.activationRevision, revision)
        portal.emit(member: "Activated", body: "(objectpath '\(try session())', 'repeat', uint64 1, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeatFires, 1)
    }

    func testBothActionTokensSurviveMainLoopHopAndChangesUpdateEachBinding() throws {
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        let service = ShortcutService(backend: backend, scheduler: GLibScheduler(), mainThread: GLibMainThread())
        var events: [HotkeyAction] = []
        var correctTokens = 0
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { action in
            events.append(action)
            let expected = action == .togglePicker ? "picker-fixture" : "repeat-fixture"
            if self.backend.consumeActivationToken(for: action) == expected { correctTokens += 1 }
        }
        PortalSessionTestSupport.barrier(transport)
        configure()
        service.refreshRegistrations(Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map {
            ($0, backend.registration(for: $0))
        }))
        let handle = try session()
        let picker = backend.registration(for: .togglePicker)
        let repeatAction = backend.registration(for: .repeatLast)
        for (action, token) in [("toggle", "picker-fixture"), ("repeat", "repeat-fixture")] {
            portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(action)', uint64 17, {'activation_token': <'\(token)'>})")
            portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(action)', uint64 17, {'activation_token': <'obsolete-fixture'>})")
        }
        XCTAssertTrue(GTKTestSupport.spin { events.count >= 2 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(events, [.togglePicker, .repeatLast])
        XCTAssertEqual(correctTokens, 2)
        XCTAssertTrue(backend.consumeActivationToken(for: .togglePicker) == nil)
        XCTAssertTrue(backend.consumeActivationToken(for: .repeatLast) == nil)
        portal.emit(member: "ShortcutsChanged", body: "(objectpath '\(handle)', [('toggle', {'trigger_description': <'Alt+P'>}), ('repeat', {'trigger_description': <'Super+R'>})])")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(backend.registration(for: .togglePicker).detail, "Alt+P")
        XCTAssertEqual(backend.registration(for: .repeatLast).detail, "Super+R")
        XCTAssertEqual(backend.registration(for: .togglePicker).id, picker.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        portal.emit(member: "ShortcutsChanged", body: "(objectpath '\(handle)', [('toggle', {'trigger_description': <'Alt+P'>}), ('repeat', {'trigger_description': <''>})])")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(backend.registration(for: .togglePicker).status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 18, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(events.count, 2)
    }

    func testUnregisterBoundActionRetiresSessionAndReleasesCallback() throws {
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        try register()
        weak var callbackOwner: NSObject?
        var repeatAction: HotkeyRegistration!
        do {
            let owner = NSObject()
            callbackOwner = owner
            repeatAction = backend.register(.repeatLast, accelerator: nil) { _ = owner.description }
        }
        configure()
        XCTAssertNotNil(callbackOwner)
        let picker = backend.currentRegistration
        let methods = portal.calls.map(\.method)
        backend.unregister(repeatAction)
        XCTAssertNil(callbackOwner)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        XCTAssertEqual(backend.currentRegistration.id, picker.id)
        XCTAssertEqual(backend.currentRegistration.status, .needsAction)
        XCTAssertFalse(backend.isAttached)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.closedPaths.isEmpty })
        let handle = try session()
        for action in ["repeat", "toggle"] {
            portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(action)', uint64 17, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
    }

    func testUnregisterSavedActionClosesBeforeFreshBindAndDoesNotResurrectIt() throws {
        for removed in HotkeyAction.allCases {
            backend.shutdown()
            backend = makeBackend()
            portal.restoredShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
            portal.boundShortcuts = portal.restoredShortcuts
            try registerBoth()
            configure()
            let remainingID = removed == .togglePicker ? "repeat" : "toggle"
            let handle = try session()
            let closes = portal.closedPaths.count
            let binds = portal.calls.filter { $0.method == "BindShortcuts" }.count
            let methods = portal.calls.map(\.method)
            portal.holdSessionClose = true
            backend.unregister(backend.registration(for: removed))
            XCTAssertFalse(backend.isAttached)
            XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.count > closes })
            XCTAssertEqual(portal.calls.map(\.method), methods, "Removal must not start consent.")
            portal.boundShortcuts = "[('\(remainingID)', {'trigger_description': <'Saved key'>})]"
            var completions = 0
            backend.configure { completions += 1 }
            PortalSessionTestSupport.barrier(transport)
            XCTAssertEqual(completions, 0, "Replacement must wait for acknowledged Close.")
            XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, binds)
            portal.holdSessionClose = false
            portal.releaseSessionCloses()
            XCTAssertTrue(GTKTestSupport.spin { completions > 0 })
            PortalSessionTestSupport.barrier(transport)
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, binds + 1)
            let bind = try XCTUnwrap(portal.calls.last { $0.method == "BindShortcuts" })
            let shortcuts = portal.shortcuts(bind)
            XCTAssertEqual(shortcuts.map(\.id), [remainingID])
            XCTAssertNil(shortcuts.first?.properties["preferred_trigger"])
            XCTAssertEqual(backend.registration(for: removed).status, .unbound)
            for id in ["toggle", "repeat"] {
                portal.emit(member: "Activated", body: "(objectpath '\(handle)', '\(id)', uint64 17, @a{sv} {})")
            }
            PortalSessionTestSupport.barrier(transport)
            XCTAssertEqual(fires, removed == .togglePicker ? 0 : 1)
            XCTAssertEqual(repeatFires, removed == .repeatLast ? 0 : 1)
            fires = 0
            repeatFires = 0
        }
    }

    func testRedeclarationAfterRemovalRequiresExplicitFreshSession() throws {
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        try registerBoth()
        configure()
        let handle = try session()
        let picker = backend.currentRegistration
        let repeatAction = backend.registration(for: .repeatLast)
        let revision = backend.activationRevision
        let methods = portal.calls.map(\.method)
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 17, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeatFires, 1)
        backend.unregister(repeatAction)
        let replacement = backend.register(.repeatLast, accelerator: nil) { [weak self] in self?.repeatFires += 1 }
        XCTAssertNotEqual(replacement.id, repeatAction.id)
        XCTAssertEqual(replacement.status, .unbound)
        XCTAssertEqual(backend.currentRegistration.id, picker.id)
        XCTAssertNotEqual(backend.activationRevision, revision)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 17, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeatFires, 1, "An old duplicate must not reach the replacement callback.")
        configure()
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 18, @a{sv} {})")
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'repeat', uint64 18, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(repeatFires, 2)
        XCTAssertEqual(fires, 0)
    }

    func testUnregisterDuringBindParentWaitCompletesOnceAndRejectsLateBind() throws {
        var parents: [(PortalParent) -> Void] = []
        backend.shutdown()
        backend = PortalHotkeyBackend(transport: transport, fallback: ManualHotkeyBackend(),
            runner: tools.runner, migration: .none, mainThread: GLibMainThread()) { parents.append($0) }
        try registerBoth()
        var completions = 0
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 1 })
        backend.unregister(backend.registration(for: .repeatLast))
        XCTAssertEqual(completions, 1)
        parents[0](PortalParent("x11:1111"))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertFalse(portal.calls.contains { $0.method == "BindShortcuts" })
        backend.configure { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 2 })
        parents[1](PortalParent("x11:2222"))
        XCTAssertTrue(GTKTestSupport.spin { completions > 1 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 2)
        let binds = portal.calls.filter { $0.method == "BindShortcuts" }
        XCTAssertEqual(binds.count, 1)
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(binds.last)).map(\.id), ["toggle"])
    }

    func testDuplicateBeforeBindAcknowledgementStillSendsOnlyOneBind() throws {
        try registerBoth()
        backend.beforeBind = { _, done in done(true); done(true) }
        configure()
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(portal.calls.last)).map(\.id), ["toggle", "repeat"])
    }

    func testFailedCloseBlocksFreshCatalogueUntilExplicitRetry() throws {
        try register()
        configure()
        let methods = portal.calls.map(\.method)
        _ = backend.register(.repeatLast, accelerator: nil) { [weak self] in self?.repeatFires += 1 }
        portal.closeError = true
        configure()
        XCTAssertEqual(portal.calls.map(\.method), methods)
        XCTAssertEqual(backend.registration(for: .togglePicker).status, .failed)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        XCTAssertTrue(tools.arguments.isEmpty)
        portal.closeError = false
        configure()
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(portal.calls.last)).map(\.id), ["toggle", "repeat"])
    }

    func testDeniedOrCancelledCreateCanRetryOnlyThroughExplicitConfiguration() throws {
        for response in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})"] {
            backend.shutdown()
            backend = makeBackend()
            portal.responses["CreateSession"] = response
            try registerBoth()
            configure()
            XCTAssertEqual(backend.registration(for: .togglePicker).status, .failed)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
            var quiescence: [Bool] = []
            backend.quiesce { quiescence.append($0) }
            XCTAssertEqual(quiescence, [true], "A first refusal leaves no uncertain creation.")
            let binds = portal.calls.filter { $0.method == "BindShortcuts" }.count
            portal.responses["CreateSession"] = nil
            PortalSessionTestSupport.barrier(transport)
            XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, binds)
            configure()
            XCTAssertEqual(backend.registration(for: .togglePicker).status, .registered)
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
            XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, binds + 1)
            XCTAssertTrue(tools.arguments.isEmpty)
        }
    }

    func testTimedOutCreateKeepsNativeGatedButExplicitRetryCanRecover() throws {
        try registerBoth()
        portal.handleCall = { $0.method == "CreateSession" }
        var completions = 0
        backend.configure(until: ContinuousClock.now.advanced(by: .milliseconds(100))) { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions > 0 })
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(backend.registration(for: .togglePicker).status, .failed)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession"])
        var quiescence: [Bool] = []
        backend.quiesce { quiescence.append($0) }
        XCTAssertEqual(quiescence, [false], "An unanswered Create cannot authorize native activation.")
        portal.handleCall = nil
        for response in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})"] {
            portal.responses["CreateSession"] = response
            configure()
            var refused: [Bool] = []
            backend.quiesce { refused.append($0) }
            XCTAssertEqual(refused, [false], "Refusing a retry cannot resolve the earlier unanswered Create.")
        }
        portal.responses["CreateSession"] = nil
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(portal.calls.map(\.method), Array(repeating: "CreateSession", count: 3),
                       "Recovery must require an explicit gesture.")
        configure()
        XCTAssertEqual(portal.calls.map(\.method), Array(repeating: "CreateSession", count: 4) + ["ListShortcuts", "BindShortcuts"])
        XCTAssertEqual(backend.registration(for: .togglePicker).status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        let bind = try XCTUnwrap(portal.calls.last { $0.method == "BindShortcuts" })
        XCTAssertEqual(portal.shortcuts(bind).map(\.id), ["toggle", "repeat"])
        var recovered: [Bool] = []
        backend.quiesce { recovered.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { !recovered.isEmpty })
        XCTAssertEqual(recovered, [true], "A definite new session must close successfully before native recovery.")
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testShutdownFromProbePublicationCompletesConfigurationOnce() throws {
        _ = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { XCTFail("Stopped probe fired") }
        backend.onChange = { self.backend.shutdown() }
        var completions = 0
        backend.configure { completions += 1 }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testShutdownFromRegistrationPublicationRejectsReplacementCallback() throws {
        try register()
        configure()
        var stopped: HotkeyRegistration?
        backend.onChange = { self.backend.shutdown(); stopped = self.backend.currentRegistration }
        weak var callbackOwner: NSObject?
        do {
            let owner = NSObject()
            callbackOwner = owner
            let rejected = backend.register(.togglePicker, accelerator: try Accelerator("Alt+R")) { _ = owner.description }
            XCTAssertEqual(rejected.status, .unbound)
            XCTAssertEqual(rejected.configuration, .unavailable)
        }
        XCTAssertNil(callbackOwner)
        XCTAssertNotNil(stopped)
        XCTAssertEqual(backend.currentRegistration, stopped)
    }

    func testActivationRevisionTracksSessionRetirementRatherThanIndividualEvents() throws {
        try register()
        let port: HotkeyBackend = backend
        XCTAssertNotNil(port.activationRevision)
        configure()
        let attachedRevision = port.activationRevision
        let handle = try session()
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'toggle', uint64 1, @a{sv} {})")
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        XCTAssertEqual(port.activationRevision, attachedRevision)
        var closed = false
        backend.quiesce { closed = $0 }
        XCTAssertTrue(GTKTestSupport.spin { closed })
        XCTAssertNotEqual(port.activationRevision, attachedRevision)
    }

    func testUnboundRepeatDeclarationPreservesAttachedPickerAndStartsNoInteraction() throws {
        try register()
        configure()
        let picker = backend.currentRegistration
        let methods = portal.calls.map(\.method)
        let repeatAction = backend.register(.repeatLast, accelerator: nil) { XCTFail("Unbound repeat fired") }
        XCTAssertEqual(repeatAction.status, .unbound)
        XCTAssertNil(repeatAction.configuration)
        XCTAssertEqual(backend.registration(for: .repeatLast), repeatAction)
        XCTAssertNotEqual(repeatAction.id, picker.id)
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        backend.unregister(repeatAction)
        let handle = try session()
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'toggle', uint64 1, @a{sv} {})")
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        XCTAssertEqual(backend.currentRegistration, picker)
    }

    func testStoppedPortalRejectsAllDeclarationsWithoutCallsOrRetainedCallbacks() throws {
        try register()
        configure()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.closedPaths.isEmpty })
        PortalSessionTestSupport.barrier(transport)
        let stopped = backend.currentRegistration
        let revision = backend.activationRevision
        let methods = portal.calls.map(\.method)
        let closes = portal.closedPaths
        let properties = portal.propertyCalls.filter { $0.interface == "org.freedesktop.portal.GlobalShortcuts" }.count
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
        backend.prepareAttachment { XCTAssertNil($0); completions += 1 }
        backend.quiesce { XCTAssertFalse($0); completions += 1 }
        backend.shutdown()
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 3)
        XCTAssertEqual(backend.currentRegistration, stopped)
        XCTAssertEqual(backend.activationRevision, revision)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        XCTAssertEqual(portal.closedPaths, closes)
        XCTAssertEqual(portal.propertyCalls.filter { $0.interface == "org.freedesktop.portal.GlobalShortcuts" }.count, properties)
        XCTAssertEqual(fires, 0)
    }

    func testStoppedQuiesceDoesNotRetryFailedSessionClose() throws {
        try register()
        configure()
        portal.closeError = true
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.closedPaths.isEmpty })
        PortalSessionTestSupport.barrier(transport)
        let closes = portal.closedPaths
        var completions = 0

        backend.quiesce { XCTAssertFalse($0); completions += 1 }
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(portal.closedPaths, closes)
    }

    func testUnregisterLastActionClosesSessionAndPreventsReconfiguration() throws {
        try register()
        configure()
        let revision = backend.activationRevision
        let handle = try session()
        backend.unregister(registration)
        let cleared = backend.currentRegistration
        XCTAssertEqual(cleared.status, .unbound)
        XCTAssertNotEqual(backend.activationRevision, revision)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(handle) })
        PortalSessionTestSupport.barrier(transport)
        let methods = portal.calls.map(\.method)
        var completions = 0
        backend.configure { completions += 1 }
        portal.emit(member: "Activated", body: "(objectpath '\(handle)', 'toggle', uint64 1, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(backend.currentRegistration, cleared)
        XCTAssertEqual(portal.calls.map(\.method), methods)
        XCTAssertEqual(fires, 0)
    }

    func testShutdownFromPendingCompletionPreventsClearFromRetainingPortalCallback() throws {
        try register()
        var completions = 0
        backend.configure { self.backend.shutdown(); completions += 1 }
        weak var callbackOwner: NSObject?
        do {
            let owner = NSObject()
            callbackOwner = owner
            let rejected = backend.register(.togglePicker, accelerator: nil) { _ = owner.description }
            XCTAssertEqual(rejected.status, .unbound)
            XCTAssertEqual(rejected.configuration, .unavailable)
        }

        XCTAssertEqual(completions, 1)
        XCTAssertNil(callbackOwner)
        let stopped = backend.currentRegistration
        backend.configure { completions += 1 }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(backend.currentRegistration, stopped)
    }

    func testShutdownFromPendingCompletionReturnsUnboundForBoundReplacement() throws {
        try register()
        var completions = 0
        backend.configure { self.backend.shutdown(); completions += 1 }

        let rejected = backend.register(.togglePicker, accelerator: try Accelerator("Alt+R")) {
            XCTFail("Stopped replacement fired")
        }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(rejected.status, .unbound)
        XCTAssertEqual(rejected.configuration, .unavailable)
        XCTAssertEqual(rejected, backend.unboundActions.registration(for: .togglePicker, mechanism: backend.mechanism))
    }

    func testQuietProbeThenBindingUsesStableTokenSameConnectionAndActualTrigger() throws {
        try register()
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
        XCTAssertEqual(backend.currentRegistration.id, registration.id)
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Super+E'>})]"
        configure()
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
        XCTAssertEqual(portal.calls.map(\.signature), ["(a{sv})", "(oa{sv})", "(oa(sa{sv})sa{sv})"])
        XCTAssertEqual(Set(portal.calls.map(\.sender)).count, 1)
        XCTAssertEqual(portal.propertyCalls.first?.sender, portal.calls.first?.sender)
        let create = try XCTUnwrap(portal.calls.first)
        XCTAssertTrue(try PortalSessionTestSupport.stringOption(create, "session_handle_token") == PortalHotkeyBackend.sessionToken)
        XCTAssertFalse(create.token == PortalHotkeyBackend.sessionToken)
        let bind = try XCTUnwrap(portal.calls.last)
        let shortcuts = g_variant_get_child_value(bind.parameters, 1)!
        defer { g_variant_unref(shortcuts) }
        let text = g_variant_print(shortcuts, 1)!
        defer { g_free(text) }
        XCTAssertTrue(String(cString: text).contains("CTRL+ALT+p"))
        XCTAssertFalse(String(cString: text).contains("<Control>"))
        XCTAssertEqual(portal.text(bind, index: 2), "x11:1234")
        XCTAssertEqual(backend.currentRegistration.id, registration.id)
        XCTAssertEqual(backend.currentRegistration.detail, "Super+E")
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.currentRegistration.configuration, .systemSettings)
        XCTAssertEqual(parentCloses, 1)
        XCTAssertFalse(backend.fire(.togglePicker))
        XCTAssertEqual(fires, 0)
    }

    func testListPublishesSavedChoiceAndBindOmitsDefaultPreference() throws {
        portal.restoredShortcuts = "[('toggle', {'trigger_description': <'Super+K'>})]"
        portal.boundShortcuts = portal.restoredShortcuts
        var showedSaved = false
        backend.onChange = {
            if self.backend.currentRegistration.status == .needsAction,
               self.backend.currentRegistration.detail.contains("Super+K") { showedSaved = true }
        }
        try register()
        configure()
        XCTAssertTrue(showedSaved)
        XCTAssertEqual(backend.currentRegistration.detail, "Super+K")
        let bind = try XCTUnwrap(portal.calls.last)
        let value = g_variant_get_child_value(bind.parameters, 1)!
        defer { g_variant_unref(value) }
        let printed = g_variant_print(value, 1)!
        defer { g_free(printed) }
        XCTAssertFalse(String(cString: printed).contains("preferred_trigger"))
    }

    func testConfigureIsOrdinaryCallAndBindIsAttemptedOncePerSession() throws {
        try register()
        configure()
        configure()
        configure()
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 1)
        XCTAssertEqual(portal.ordinaryCalls.map(\.method), ["ConfigureShortcuts", "ConfigureShortcuts"])
        XCTAssertTrue(portal.ordinaryCalls.allSatisfy { $0.signature == "(osa{sv})" && $0.sender == portal.calls[0].sender })
        XCTAssertTrue(portal.ordinaryCalls.allSatisfy { $0.option("handle_token") == nil })
        XCTAssertEqual(parentCloses, 3)
        portal.methodError = "org.freedesktop.portal.Error.NotAllowed"
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .failed)
        XCTAssertEqual(parentCloses, 4)
    }

    func testConfigurationWithoutDeclarationsAndDuringProbeCompletesOnce() throws {
        configure()
        XCTAssertTrue(portal.calls.isEmpty)
        _ = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { }
        configure()
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
    }

    func testAttachedConfigurationBusyAndTimeoutCompleteEachCallerOnce() throws {
        try registerBoth()
        configure()
        portal.handleCall = { $0.method == "ConfigureShortcuts" }
        var first = 0
        var busy = 0
        backend.configure(until: ContinuousClock.now.advanced(by: .milliseconds(100))) { first += 1 }
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.ordinaryCalls.isEmpty })
        backend.configure { busy += 1 }
        XCTAssertEqual(busy, 1)
        XCTAssertTrue(GTKTestSupport.spin { first > 0 })
        portal.reply(try XCTUnwrap(portal.ordinaryCalls.last))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(busy, 1)
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 1)
    }

    func testSignalsFilterSenderSessionAndActionAndPublishChangedBinding() throws {
        try register()
        configure()
        let session = try session()
        let other = try FakePortal(address: FakePortal.requirePrivateBus())
        defer { other.shutdown() }
        other.emit(member: "Activated", body: "(objectpath '\(session)', 'toggle', uint64 1, @a{sv} {})")
        portal.emit(member: "Activated", body: "(objectpath '/wrong/session', 'toggle', uint64 2, @a{sv} {})")
        portal.emit(member: "Activated", body: "(objectpath '\(session)', 'other', uint64 3, @a{sv} {})")
        portal.emit(member: "Activated", body: "(objectpath '\(session)', 'toggle', uint64 4, {'activation_token': <uint32 1>})")
        portal.emit(member: "Deactivated", body: "(objectpath '\(session)', 'toggle', uint64 5, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 0)
        var token: String?
        _ = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { [weak self] in
            token = self?.backend.consumeActivationToken()
            self?.fires += 1
        }
        PortalSessionTestSupport.barrier(transport)
        configure()
        let activeSession = try self.session()
        portal.emit(member: "Activated", body: "(objectpath '\(activeSession)', 'toggle', uint64 6, {'activation_token': <'fixture-activation'>})")
        XCTAssertTrue(GTKTestSupport.spin { self.fires == 1 })
        XCTAssertTrue(token == "fixture-activation")
        portal.emit(member: "ShortcutsChanged", body: "(objectpath '/wrong/session', [('toggle', {'trigger_description': <'Wrong'>})])")
        portal.emit(member: "ShortcutsChanged", body: "(objectpath '\(activeSession)', [('toggle', {'trigger_description': <'Alt+E'>})])")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.detail == "Alt+E" })
        portal.emit(member: "ShortcutsChanged", body: "(objectpath '\(activeSession)', @a(sa{sv}) [])")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .unbound })
        portal.emit(member: "Activated", body: "(objectpath '\(activeSession)', 'toggle', uint64 7, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 1)
    }

    func testVersionOneGivesGuidanceUntilAnExplicitGestureAddsMissingRepeat() throws {
        portal.versions[PortalInterface.globalShortcuts.rawValue] = 1
        try register()
        configure()
        XCTAssertNil(backend.currentRegistration.configuration)
        configure()
        XCTAssertTrue(portal.ordinaryCalls.isEmpty)
        XCTAssertEqual(portal.calls.filter { $0.method == "CreateSession" }.count, 1)
        _ = backend.register(.repeatLast, accelerator: nil) { [weak self] in self?.repeatFires += 1 }
        configure()
        XCTAssertEqual(portal.calls.filter { $0.method == "CreateSession" }.count, 2)
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.closedPaths.isEmpty })
        let creates = portal.calls.filter { $0.method == "CreateSession" }
        let first = try XCTUnwrap(creates.first)
        let last = try XCTUnwrap(creates.last)
        XCTAssertTrue(try PortalSessionTestSupport.stringOption(first, "session_handle_token")
            == PortalSessionTestSupport.stringOption(last, "session_handle_token"))
        XCTAssertFalse(first.token == last.token)
        configure()
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
        XCTAssertEqual(portal.shortcuts(try XCTUnwrap(portal.calls.last)).map(\.id), ["toggle", "repeat"])
    }

    func testActivationDedupResetsAfterAcknowledgedSessionRetirement() throws {
        try register()
        configure()
        let oldSession = try session()
        portal.emit(member: "Activated", body: "(objectpath '\(oldSession)', 'toggle', uint64 17, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 1)

        var retired = false
        backend.quiesce { retired = $0 }
        XCTAssertTrue(GTKTestSupport.spin { retired })
        XCTAssertTrue(portal.closedPaths.contains(oldSession))
        portal.emit(member: "Activated", body: "(objectpath '\(oldSession)', 'toggle', uint64 18, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 1)

        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        let newSession = try session()
        portal.emit(member: "Activated", body: "(objectpath '\(newSession)', 'toggle', uint64 17, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 2, "A new session must accept a reused timestamp.")
        portal.emit(member: "Activated", body: "(objectpath '\(newSession)', 'toggle', uint64 17, @a{sv} {})")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 2, "Duplicates within the new session must remain ignored.")
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
    }

    func testActivationDedupResetsAfterOwnerLossAndIgnoresObsoleteOwner() throws {
        let bindings = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        portal.boundShortcuts = bindings
        try registerBoth()
        configure()
        let picker = backend.currentRegistration
        let repeatAction = backend.registration(for: .repeatLast)
        let oldSession = try session()
        for action in ["toggle", "repeat"] {
            portal.emit(member: "Activated", body: "(objectpath '\(oldSession)', '\(action)', uint64 17, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(repeatFires, 1)

        let oldOwner = portal!
        defer { oldOwner.shutdown() }
        oldOwner.dropName()
        XCTAssertTrue(GTKTestSupport.spin {
            HotkeyAction.allCases.allSatisfy { self.backend.registration(for: $0).status == .failed }
        })
        XCTAssertTrue(backend.consumeActivationToken(for: .togglePicker) == nil)
        XCTAssertTrue(backend.consumeActivationToken(for: .repeatLast) == nil)
        portal = try FakePortal(address: FakePortal.requirePrivateBus())
        portal.behavior = .sessions
        portal.boundShortcuts = bindings
        try portal.ownName()
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        XCTAssertEqual(backend.currentRegistration.id, picker.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        let newSession = try session()
        // The stable token can reuse the same path under a different owner.
        XCTAssertEqual(newSession, oldSession)
        for action in ["toggle", "repeat"] {
            oldOwner.emit(member: "Activated", body: "(objectpath '\(newSession)', '\(action)', uint64 18, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(repeatFires, 1)

        for action in ["toggle", "repeat"] {
            portal.emit(member: "Activated", body: "(objectpath '\(newSession)', '\(action)', uint64 17, @a{sv} {})")
            portal.emit(member: "Activated", body: "(objectpath '\(newSession)', '\(action)', uint64 17, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 2, "A new owner must accept a reused timestamp.")
        XCTAssertEqual(repeatFires, 2, "Both actions deduplicate independently in the new session.")
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "ListShortcuts", "BindShortcuts"])
    }

    func testDeniedCancelledAndEmptyBindingNeverInstallFallback() throws {
        for response in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})", "(uint32 0, {'shortcuts': <@a(sa{sv}) []>})"] {
            portal.responses["BindShortcuts"] = response
            try registerBoth()
            configure()
            XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
            XCTAssertNotEqual(backend.currentRegistration.status, .registered)
            XCTAssertNotEqual(backend.registration(for: .repeatLast).status, .registered)
            XCTAssertTrue(tools.arguments.isEmpty)
            XCTAssertFalse(backend.fire(.togglePicker))
            XCTAssertFalse(backend.fire(.repeatLast))
        }
    }

    func testUnsupportedPortalSelectsQuietGnomeFallbackUntilSetup() throws {
        portal.versions[PortalInterface.globalShortcuts.rawValue] = 0
        backend.shutdown()
        backend = makeBackend(fallback: GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread()))
        try register()
        XCTAssertEqual(backend.mechanism, .gnomeCustomKeybinding)
        XCTAssertTrue(tools.arguments.isEmpty)
        XCTAssertTrue(portal.calls.isEmpty)
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(backend.currentRegistration.id, registration.id)
        XCTAssertTrue(tools.arguments.contains { $0.first == "set" })
        XCTAssertTrue(backend.fire(.togglePicker))
        XCTAssertEqual(fires, 1)
    }

    func testMissingInterfaceFallsBackToManualCommand() throws {
        portal.shutdown()
        portal = try FakePortal(address: FakePortal.requirePrivateBus(), globalShortcuts: nil)
        try portal.ownName()
        try register()
        XCTAssertEqual(backend.mechanism, .manual)
        XCTAssertEqual(backend.currentRegistration.detail, GnomeKeybindingInstaller.command)
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testUnavailableSessionSetupOffersGnomeFallbackWithoutInstalling() throws {
        backend.shutdown()
        backend = makeBackend(fallback: GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread()))
        try register()
        portal.methodError = "org.freedesktop.DBus.Error.ServiceUnknown"
        configure()
        XCTAssertEqual(backend.mechanism, .gnomeCustomKeybinding)
        XCTAssertEqual(backend.currentRegistration.id, registration.id)
        XCTAssertTrue(tools.arguments.isEmpty)
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession"])
    }

    func testActivationTokenSurvivesShortcutServiceMainLoopHop() throws {
        let service = ShortcutService(backend: backend, scheduler: GLibScheduler(), mainThread: GLibMainThread())
        var received: String?
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in
            received = self.backend.consumeActivationToken()
        }
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.propertyCalls.isEmpty })
        configure()
        portal.emit(member: "Activated", body: "(objectpath '\(try session())', 'toggle', uint64 9, {'activation_token': <'hop-fixture'>})")
        XCTAssertTrue(GTKTestSupport.spin { received != nil })
        XCTAssertTrue(received == "hop-fixture")
    }

    func testUntouchedFallbackIsRetiredBeforeBindAndForeignRowsSurvive() throws {
        tools.environment["FAKE_BINDINGS"] = "['\(GnomeKeybindingInstaller.basePath)custom0/', '\(GnomeKeybindingInstaller.basePath)custom2/']"
        tools.environment["FAKE_NAME"] = "'Monkey\\'s Paw: toggle'"
        backend.shutdown()
        backend = makeBackend(migration: .gnomeHost)
        try register()
        configure()
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertEqual(tools.arguments.filter { $0.first == "set" }, [["set", GnomeKeybindingInstaller.listSchema,
            "custom-keybindings", "['\(GnomeKeybindingInstaller.basePath)custom2/']"]])
    }

    func testEditedOrUnreadableFallbackBlocksPortalWithoutWrites() throws {
        for edited in ["'<Control><Alt>e'", "FAIL"] {
            tools.environment["FAKE_BINDINGS"] = edited == "FAIL" ? "FAIL" : "['\(GnomeKeybindingInstaller.basePath)custom0/']"
            tools.environment["FAKE_NAME"] = "'Monkey\\'s Paw: toggle'"
            tools.environment["FAKE_ACCELERATOR"] = edited
            backend.shutdown()
            backend = makeBackend(migration: .gnomeHost)
            try register()
            configure()
            XCTAssertNotEqual(backend.currentRegistration.status, .registered)
            XCTAssertTrue(portal.calls.isEmpty)
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testFallbackEditedAfterInspectionBlocksPortalAndPreservesRows() throws {
        let row = GnomeKeybindingInstaller.itemSchema + ":" + GnomeKeybindingInstaller.basePath + "custom1/"
        let originalFields = [
            "name": "'Monkey\\'s Paw: toggle'",
            "command": "'gapplication action ch.lkmc.monkeyspaw toggle'",
            "binding": "'<Control><Alt>p'",
        ]
        for (field, edited) in [("name", "'User shortcut'"), ("command", "'user-command'"),
                                ("binding", "'<Control><Alt>e'"), ("binding", "''")] {
            try editFallbackOnSecondListRead(field: field, value: edited)
            try register()
            configure()
            XCTAssertEqual(backend.currentRegistration.status, .needsAction, field)
            XCTAssertEqual(backend.currentRegistration.detail, LinuxStrings.shortcutMigrationBlocked, field)
            XCTAssertTrue(portal.calls.isEmpty, field)
            XCTAssertEqual(tools.arguments.filter { $0.prefix(3) == ["get", GnomeKeybindingInstaller.listSchema,
                "custom-keybindings"] }.count, 2, field)
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" }, field)
            XCTAssertEqual(try settingsValue(schema: GnomeKeybindingInstaller.listSchema, key: "custom-keybindings"),
                           tools.environment["FAKE_BINDINGS"], field)
            for (key, original) in originalFields {
                XCTAssertEqual(try settingsValue(schema: row, key: key), key == field ? edited : original, field)
            }
        }
    }

    func testFailedOrMalformedFallbackRecheckBlocksPortalWithoutWrites() throws {
        for field in ["name", "command", "binding"] {
            for value in ["FAIL", "malformed"] {
                try editFallbackOnSecondListRead(field: field, value: value)
                try register()
                configure()
                XCTAssertEqual(backend.currentRegistration.status, .failed, field)
                XCTAssertEqual(backend.currentRegistration.detail, LinuxStrings.shortcutMigrationFailed, field)
                XCTAssertTrue(portal.calls.isEmpty, field)
                XCTAssertFalse(tools.arguments.contains { $0.first == "set" }, field)
                XCTAssertEqual(try settingsValue(schema: GnomeKeybindingInstaller.listSchema, key: "custom-keybindings"),
                               tools.environment["FAKE_BINDINGS"], field)
            }
        }
    }

    private func editFallbackOnSecondListRead(field: String, value: String) throws {
        backend.shutdown()
        tools = try PortalSessionTestSupport.tools(settingsHook: #"""
            if [ "$1:$3" = get:custom-keybindings ]; then
                if [ -f "$FAKE_LOG.list-read" ]; then
                    printf '%s\n' "$FAKE_EDIT_VALUE" > "$FAKE_LOG.$FAKE_EDIT_FIELD"
                fi
                : > "$FAKE_LOG.list-read"
            fi
            if [ "$1" = get ] && [ -f "$FAKE_LOG.$3" ] &&
               { [ "$3" = custom-keybindings ] || [ "$2" = "$FAKE_EDIT_SCHEMA" ]; }; then
                IFS= read -r value < "$FAKE_LOG.$3"
                [ "$value" = FAIL ] && exit 2
                printf '%s\n' "$value"
                exit 0
            fi
            if [ "$1:$3" = set:custom-keybindings ]; then
                printf '%s\n' "$4" > "$FAKE_LOG.custom-keybindings"
            fi
            """#)
        tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode(["custom0/", "custom1/", "custom2/"]
            .map { GnomeKeybindingInstaller.basePath + $0 })
        tools.environment["FAKE_NAME"] = "'Monkey\\'s Paw: toggle'"
        tools.environment["FAKE_EDIT_SCHEMA"] = GnomeKeybindingInstaller.itemSchema + ":"
            + GnomeKeybindingInstaller.basePath + "custom1/"
        tools.environment["FAKE_EDIT_FIELD"] = field
        tools.environment["FAKE_EDIT_VALUE"] = value
        backend = makeBackend(migration: .gnomeHost)
    }

    private func settingsValue(schema: String, key: String) throws -> String {
        try tools.runner.run("gsettings", arguments: ["get", schema, key]).get().text
    }

    func testClosedAndOwnerLossInvalidateRegistrationAndShutdownClosesSession() throws {
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Super+K'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        try registerBoth()
        configure()
        let ids = HotkeyAction.allCases.map { backend.registration(for: $0).id }
        let old = try session()
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: old)
        XCTAssertTrue(GTKTestSupport.spin {
            HotkeyAction.allCases.allSatisfy { self.backend.registration(for: $0).status == .failed }
        })
        for action in ["toggle", "repeat"] {
            portal.emit(member: "Activated", body: "(objectpath '\(old)', '\(action)', uint64 17, @a{sv} {})")
        }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(repeatFires, 0)
        configure()
        XCTAssertEqual(HotkeyAction.allCases.map { backend.registration(for: $0).id }, ids)
        portal.dropName()
        XCTAssertTrue(GTKTestSupport.spin {
            HotkeyAction.allCases.allSatisfy { self.backend.registration(for: $0).status == .failed }
        })
        try portal.ownName()
        configure()
        let session = try session()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(session) })
        XCTAssertFalse(backend.fire(.togglePicker))
        XCTAssertFalse(backend.fire(.repeatLast))
    }

    func testLateBindParentCannotContinueIntoRetryAfterSessionLoss() throws {
        var parents: [(PortalParent) -> Void] = []
        backend.shutdown()
        backend = PortalHotkeyBackend(transport: transport, fallback: ManualHotkeyBackend(),
            runner: tools.runner, migration: .none, mainThread: GLibMainThread()) { parents.append($0) }
        try register()
        var firstDone = false
        backend.configure { firstDone = true }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 1 })
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: try session())
        XCTAssertTrue(GTKTestSupport.spin { firstDone })

        var retryDone = false
        backend.configure { retryDone = true }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 2 })
        parents[0](PortalParent("x11:1111"))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertFalse(retryDone)
        XCTAssertFalse(portal.calls.contains { $0.method == "BindShortcuts" })
        parents[1](PortalParent("x11:2222"))
        XCTAssertTrue(GTKTestSupport.spin { retryDone })
        let binds = portal.calls.filter { $0.method == "BindShortcuts" }
        XCTAssertEqual(binds.count, 1)
        XCTAssertEqual(portal.text(try XCTUnwrap(binds.last), index: 2), "x11:2222")
    }

    func testLateConfigureParentCannotConfigureLostSessionDuringRetry() throws {
        var parents: [(PortalParent) -> Void] = []
        backend.shutdown()
        backend = PortalHotkeyBackend(transport: transport, fallback: ManualHotkeyBackend(),
            runner: tools.runner, migration: .none, mainThread: GLibMainThread()) { parents.append($0) }
        try register()
        var bound = false
        backend.configure { bound = true }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 1 })
        parents[0](PortalParent("x11:1111"))
        XCTAssertTrue(GTKTestSupport.spin { bound })
        var configureDone = false
        backend.configure { configureDone = true }
        XCTAssertEqual(parents.count, 2)
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: try session())
        XCTAssertTrue(GTKTestSupport.spin { configureDone })

        var retryDone = false
        backend.configure { retryDone = true }
        XCTAssertTrue(GTKTestSupport.spin { parents.count == 3 })
        parents[1](PortalParent("x11:2222"))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertFalse(retryDone)
        XCTAssertTrue(portal.ordinaryCalls.isEmpty)
        parents[2](PortalParent("x11:3333"))
        XCTAssertTrue(GTKTestSupport.spin { retryDone })
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
    }
}
#endif
