#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class PortalHotkeyTests: XCTestCase {
    private var portal: FakePortal!
    private var transport: LinuxPortalTransport!
    private var tools: FakeLinuxTools!
    private var backend: PortalHotkeyBackend!
    private var fires = 0
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
        var done = false
        backend.configure { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }

    private func session() throws -> String { try XCTUnwrap(portal.sessionOwners.keys.first) }

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

    func testVersionOneHasNoConfigureAndNewExplicitGestureCreatesNewSession() throws {
        portal.versions[PortalInterface.globalShortcuts.rawValue] = 1
        try register()
        configure()
        XCTAssertNil(backend.currentRegistration.configuration)
        configure()
        XCTAssertTrue(portal.ordinaryCalls.isEmpty)
        XCTAssertEqual(portal.calls.filter { $0.method == "CreateSession" }.count, 2)
        XCTAssertEqual(portal.calls.filter { $0.method == "BindShortcuts" }.count, 2)
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.closedPaths.isEmpty })
        let creates = portal.calls.filter { $0.method == "CreateSession" }
        XCTAssertTrue(try PortalSessionTestSupport.stringOption(creates[0], "session_handle_token")
            == PortalSessionTestSupport.stringOption(creates[1], "session_handle_token"))
        XCTAssertFalse(creates[0].token == creates[1].token)
    }

    func testDeniedCancelledAndEmptyBindingNeverInstallFallback() throws {
        for response in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})", "(uint32 0, {'shortcuts': <@a(sa{sv}) []>})"] {
            portal.responses["BindShortcuts"] = response
            try register()
            configure()
            XCTAssertEqual(backend.mechanism, .globalShortcutsPortal)
            XCTAssertNotEqual(backend.currentRegistration.status, .registered)
            XCTAssertTrue(tools.arguments.isEmpty)
            XCTAssertFalse(backend.fire(.togglePicker))
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
        try register()
        configure()
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: try session())
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        configure()
        portal.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.backend.currentRegistration.status == .failed })
        try portal.ownName()
        configure()
        let session = try session()
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(session) })
        XCTAssertFalse(backend.fire(.togglePicker))
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
