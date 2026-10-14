#if os(Linux)
import MonkeysPawCore
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GnomeKeybindingTests: XCTestCase {
    private let schema = GnomeKeybindingInstaller.listSchema
    private let itemSchema = GnomeKeybindingInstaller.itemSchema
    private let base = GnomeKeybindingInstaller.basePath

    func testBothDriversDeclareRepeatWithoutChoosingAKeyAndRouteAssignedActionsIndependently() throws {
        let tools = try fakeSettings()
        let backends: [LinuxHotkeyBackend] = [ManualHotkeyBackend(),
            GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())]
        for backend in backends {
            let unbound = backend.register(.repeatLast, accelerator: nil) { XCTFail("Unbound repeat fired") }
            XCTAssertEqual(unbound.status, .unbound)
            XCTAssertTrue(unbound.detail.contains("gapplication action ch.lkmc.monkeyspaw repeat"))
            XCTAssertFalse(backend.fire(.repeatLast))
            var pickerFires = 0
            var repeatFires = 0
            let picker = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { pickerFires += 1 }
            let repeatAction = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { repeatFires += 1 }
            XCTAssertNotEqual(picker.id, repeatAction.id)
            XCTAssertEqual(backend.registration(for: .repeatLast), repeatAction)
            XCTAssertEqual(backend.currentRegistration, picker)
            XCTAssertTrue(backend.fire(.togglePicker))
            XCTAssertTrue(backend.fire(.repeatLast))
            backend.unregister(repeatAction)
            XCTAssertFalse(backend.fire(.repeatLast))
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
            XCTAssertEqual(backend.currentRegistration, picker)
            XCTAssertTrue(backend.fire(.togglePicker))
            XCTAssertEqual(pickerFires, 2)
            XCTAssertEqual(repeatFires, 1)
            let rebound = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { repeatFires += 1 }
            let cleared = backend.register(.togglePicker, accelerator: nil) { XCTFail("Cleared picker fired") }
            XCTAssertEqual(backend.currentRegistration, cleared)
            XCTAssertEqual(backend.registration(for: .repeatLast), rebound)
            XCTAssertFalse(backend.fire(.togglePicker))
            XCTAssertTrue(backend.fire(.repeatLast))
            XCTAssertEqual(repeatFires, 2)
            backend.shutdown()
            XCTAssertFalse(backend.fire(.togglePicker))
            XCTAssertFalse(backend.fire(.repeatLast))
            weak var callbackOwner: NSObject?
            do {
                let owner = NSObject()
                callbackOwner = owner
                let stopped = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { _ = owner.description }
                XCTAssertEqual(stopped.status, .unbound)
            }
            XCTAssertNil(callbackOwner)
            XCTAssertFalse(backend.fire(.repeatLast))
        }
        XCTAssertTrue(tools.arguments.isEmpty, "Declaration, unbind and shutdown never write dconf")
    }

    func testActiveRepeatRowBlocksPortalMigrationWithoutRetiringPickerOrEditingFields() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([base + "custom0/", base + "custom1/"])
        try row(tools, path: base + "custom0/", name: "Monkey's Paw: toggle",
                command: GnomeKeybindingInstaller.command, binding: "<Control><Alt>p")
        try row(tools, path: base + "custom1/", name: "Monkey's Paw: repeat",
                command: "gapplication action ch.lkmc.monkeyspaw repeat", binding: "<Control><Alt>e")
        XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner).prepareForPortal(), .editedBinding)
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
    }

    func testRenamedRowInvokingOurActionIsPreservedWithoutInstallingADuplicate() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([base + "custom0/"])
        tools.environment["FAKE_NAME"] = "'My picker'"
        tools.environment["FAKE_COMMAND"] = "'gapplication action ch.lkmc.monkeyspaw toggle'"
        tools.environment["FAKE_ACCELERATOR"] = "'<Super>p'"
        XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner).install(accelerator: try Accelerator("Ctrl+Alt+P")))
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
    }

    func testUnusedListSlotWithDormantForeignFieldsIsNeverOverwritten() throws {
        let tools = try fakeSettings()
        let dormant = base + "custom0/"
        try row(tools, path: dormant, name: "Other app", command: "other-app", binding: "<Super>x")
        XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner).install(accelerator: try Accelerator("Ctrl+Alt+P")),
                       "<Control><Alt>p")
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" && $0[1] == itemSchema + ":" + dormant })
        XCTAssertEqual(tools.arguments.last, ["set", schema, "custom-keybindings", GnomeKeybindingInstaller.encode([base + "custom1/"])])
    }

    func testRepeatSetupRequiresAnExplicitKeyAndConfiguresOnlyThatAction() throws {
        let tools = try fakeSettings()
        let backend: LinuxHotkeyBackend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        let picker = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {}
        _ = backend.register(.repeatLast, accelerator: nil) { XCTFail("Unbound repeat fired") }
        var completions = 0
        backend.configure(for: .repeatLast) { completions += 1 }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(tools.arguments.isEmpty)
        let repeatAction = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) {}
        var changes = 0
        backend.onChange = { XCTAssertTrue(Thread.isMainThread); changes += 1 }
        backend.configure(for: .repeatLast) { XCTAssertTrue(Thread.isMainThread); completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 2 })
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(backend.registration(for: .repeatLast).id, repeatAction.id)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .registered)
        XCTAssertEqual(backend.registration(for: .repeatLast).detail, "<Control><Alt>e")
        XCTAssertTrue(tools.arguments.contains(["set", itemSchema + ":" + base + "custom0/", "command",
                                               "'gapplication action ch.lkmc.monkeyspaw repeat'"]))
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" && $0.last == "'gapplication action ch.lkmc.monkeyspaw toggle'" })
        let calls = tools.arguments
        backend.unregister(picker)
        XCTAssertTrue(backend.fire(.repeatLast))
        backend.shutdown()
        XCTAssertEqual(tools.arguments, calls)
        XCTAssertFalse(backend.fire(.repeatLast))
    }

    func testRepeatRowUsesExactActionArgumentsAndPreservesPickerAndForeignRows() throws {
        let tools = try fakeSettings()
        let picker = base + "custom0/", foreign = base + "custom2/", repeatPath = base + "custom1/"
        tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([picker, foreign])
        try row(tools, path: picker, name: "Monkey's Paw: toggle", command: GnomeKeybindingInstaller.command, binding: "<Super>p")
        try row(tools, path: foreign, name: "Other app", command: "other-app", binding: "<Super>x")
        XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner).install(action: .repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")),
                       "<Control><Alt>e")
        let target = itemSchema + ":" + repeatPath
        XCTAssertEqual(tools.arguments.filter { $0.first == "set" }, [
            ["set", target, "command", "'gapplication action ch.lkmc.monkeyspaw repeat'"],
            ["set", target, "binding", "'<Control><Alt>e'"],
            ["set", target, "name", "'Monkey\\'s Paw: repeat'"],
            ["set", schema, "custom-keybindings", GnomeKeybindingInstaller.encode([picker, foreign, repeatPath])],
        ])
        XCTAssertEqual(try tools.runner.run("gsettings", arguments: ["get", itemSchema + ":" + picker, "binding"]).get().text, "'<Super>p'")
        XCTAssertEqual(try tools.runner.run("gsettings", arguments: ["get", itemSchema + ":" + foreign, "command"]).get().text, "'other-app'")
    }

    func testExistingRepeatAssignmentsIncludingUnboundRemainAuthoritative() throws {
        for binding in ["<Super>r", ""] {
            let tools = try fakeSettings()
            let path = base + "custom0/"
            tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([path])
            try row(tools, path: path, name: "Monkey's Paw: repeat", command: "gapplication action ch.lkmc.monkeyspaw repeat", binding: binding)
            XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner).install(action: .repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")), binding)
            let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
            var fires = 0
            _ = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { fires += 1 }
            var finished = false
            backend.configure(for: .repeatLast) { finished = true }
            XCTAssertTrue(GTKTestSupport.spin { finished })
            XCTAssertEqual(backend.registration(for: .repeatLast).status, binding.isEmpty ? .unbound : .registered)
            XCTAssertEqual(backend.fire(.repeatLast), !binding.isEmpty)
            XCTAssertEqual(fires, binding.isEmpty ? 0 : 1)
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testAmbiguousEditedAndForeignRepeatRowsAbortWithoutWrites() throws {
        for (name, command) in [("Monkey's Paw: repeat", "foreign-command"),
                                ("My repeat", "gapplication action ch.lkmc.monkeyspaw repeat"),
                                ("Monkey's Paw: repeat", "gapplication action ch.lkmc.monkeyspaw repeat")] {
            let tools = try fakeSettings()
            tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([base + "custom0/", base + "custom1/"])
            try row(tools, path: base + "custom0/", name: "Monkey's Paw: repeat",
                    command: "gapplication action ch.lkmc.monkeyspaw repeat", binding: "<Super>r")
            try row(tools, path: base + "custom1/", name: name, command: command, binding: "<Super>e")
            XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner).install(action: .repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")))
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testRepeatReadFailureOffersItsOwnManualCommand() throws {
        for raw in ["FAIL", "malformed", "['/bad']"] {
            let tools = try fakeSettings()
            tools.environment["FAKE_BINDINGS"] = raw
            let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
            _ = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { XCTFail("Failed binding fired") }
            var finished = false
            backend.configure(for: .repeatLast) { finished = true }
            XCTAssertTrue(GTKTestSupport.spin { finished })
            XCTAssertEqual(backend.registration(for: .repeatLast).status, .failed)
            XCTAssertTrue(backend.registration(for: .repeatLast).detail.contains("gapplication action ch.lkmc.monkeyspaw repeat"))
            XCTAssertFalse(backend.fire(.repeatLast), "Return false so cold/manual callers can use their direct action path")
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testListChangesBeforeFieldWritesOrPublicationAbortWithoutClobberingTheNewList() throws {
        for readNumber in [2, 3] {
            for changed in [GnomeKeybindingInstaller.encode([base + "custom7/"]), "FAIL", "malformed"] {
                let tools = try fakeSettings(hook: #"""
                    if [ "$1:$3" = get:custom-keybindings ]; then
                        count=0
                        if [ -f "$FAKE_LOG.reads" ]; then IFS= read -r count < "$FAKE_LOG.reads"; fi
                        count=$((count + 1))
                        printf '%s\n' "$count" > "$FAKE_LOG.reads"
                        if [ "$count" = "$FAKE_CHANGE_AT" ]; then
                            printf '%s\n' "$FAKE_CHANGED_LIST" > "$FAKE_LOG.bindings"
                        fi
                    fi
                    """#)
                tools.environment["FAKE_CHANGE_AT"] = String(readNumber)
                tools.environment["FAKE_CHANGED_LIST"] = changed
                XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner).install(action: .repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")))
                let sets = tools.arguments.filter { $0.first == "set" }
                XCTAssertEqual(sets.count, readNumber == 2 ? 0 : 3)
                XCTAssertFalse(sets.contains { $0[1] == schema })
                XCTAssertEqual(try String(contentsOf: tools.directory.appendingPathComponent("argv.bindings"), encoding: .utf8), changed + "\n")
            }
        }
    }

    func testRepeatUnboundDuringConfigurationRejectsTheLateResultAndPreservesPicker() throws {
        let tools = try fakeSettings()
        let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        let picker = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {}
        let repeatAction = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) {}
        var changes = 0
        var completions = 0
        backend.onChange = { changes += 1 }
        backend.configure(for: .repeatLast) { completions += 1 }
        backend.unregister(repeatAction)
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(backend.currentRegistration, picker)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        XCTAssertFalse(backend.fire(.repeatLast))
        XCTAssertTrue(backend.fire(.togglePicker))
    }

    func testShutdownDuringRepeatConfigurationCompletesWithoutRevivingCallbacks() throws {
        let tools = try fakeSettings()
        let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        _ = backend.register(.repeatLast, accelerator: try Accelerator("Ctrl+Alt+E")) { XCTFail("Stopped repeat fired") }
        var changes = 0
        var completions = 0
        backend.onChange = { changes += 1 }
        backend.configure(for: .repeatLast) { completions += 1 }
        backend.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(backend.registration(for: .repeatLast).status, .unbound)
        XCTAssertFalse(backend.fire(.repeatLast))
        let calls = tools.arguments
        backend.configure(for: .repeatLast) { completions += 1 }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(tools.arguments, calls)
    }

    func testMigrationPreservesUnboundRepeatFieldsAndRejectsARepeatAssignedDuringRecheck() throws {
        for edited in [false, true] {
            let tools = try fakeSettings(hook: #"""
                if [ "$FAKE_EDIT_REPEAT" = 1 ] && [ "$1:$3" = get:custom-keybindings ]; then
                    if [ -f "$FAKE_LOG.reads" ]; then
                        printf '%s\n' "'<Super>r'" > "$FAKE_REPEAT_BINDING_FILE"
                    fi
                    : > "$FAKE_LOG.reads"
                fi
                """#)
            let picker = base + "custom0/", repeatPath = base + "custom1/", foreign = base + "custom2/"
            tools.environment["FAKE_BINDINGS"] = GnomeKeybindingInstaller.encode([picker, repeatPath, foreign])
            tools.environment["FAKE_EDIT_REPEAT"] = edited ? "1" : "0"
            tools.environment["FAKE_REPEAT_BINDING_FILE"] = tools.directory.appendingPathComponent("settings" + repeatPath + "binding").path
            try row(tools, path: picker, name: "Monkey's Paw: toggle", command: GnomeKeybindingInstaller.command, binding: "<Control><Alt>p")
            try row(tools, path: repeatPath, name: "Monkey's Paw: repeat", command: "gapplication action ch.lkmc.monkeyspaw repeat", binding: "")
            try row(tools, path: foreign, name: "Other app", command: "other-app", binding: "<Super>x")
            XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner).prepareForPortal(), edited ? .editedBinding : .ready)
            XCTAssertEqual(tools.arguments.filter { $0.first == "set" }, edited ? [] : [
                ["set", schema, "custom-keybindings", GnomeKeybindingInstaller.encode([repeatPath, foreign])],
            ])
            XCTAssertEqual(try tools.runner.run("gsettings", arguments: ["get", itemSchema + ":" + picker, "binding"]).get().text, "'<Control><Alt>p'")
            XCTAssertEqual(try tools.runner.run("gsettings", arguments: ["get", itemSchema + ":" + repeatPath, "binding"]).get().text, edited ? "'<Super>r'" : "''")
        }
    }

    func testInstallerAndMigrationRespectOneTotalDeadline() throws {
        let tools = try fakeSettings()
        let installer = GnomeKeybindingInstaller(runner: tools.runner)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(-1))
        XCTAssertNil(installer.install(action: .repeatLast, accelerator: try Accelerator("Ctrl+Alt+E"), deadline: deadline))
        XCTAssertEqual(installer.prepareForPortal(deadline: deadline), .unavailable)
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testUnboundCatalogueKeepsStableActionIdentitiesWithoutRetainingUnusableCallbacks() throws {
        let tools = try fakeSettings()
        let backends: [LinuxHotkeyBackend] = [ManualHotkeyBackend(),
            GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())]
        for backend in backends {
            var registrations: [HotkeyAction: HotkeyRegistration] = [:]
            for action in HotkeyAction.allCases {
                weak var callbackOwner: NSObject?
                do {
                    let owner = NSObject()
                    callbackOwner = owner
                    registrations[action] = backend.register(action, accelerator: nil) { _ = owner.description }
                }
                XCTAssertNil(callbackOwner, "Unsupported actions cannot invoke a parked callback")
                XCTAssertEqual(backend.registration(for: action), registrations[action])
                XCTAssertFalse(backend.fire(action))
            }
            XCTAssertNotEqual(registrations[.togglePicker]?.id, registrations[.repeatLast]?.id)
            for action in HotkeyAction.allCases {
                backend.unregister(try XCTUnwrap(registrations[action]))
                XCTAssertEqual(backend.registration(for: action), registrations[action])
            }
            backend.shutdown()
        }
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testUnboundRepeatAdaptersPreserveManualAndGnomeToggleCallbacksWithoutWriting() throws {
        let tools = try fakeSettings()
        let backends: [LinuxHotkeyBackend] = [ManualHotkeyBackend(),
            GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())]
        for backend in backends {
            var fires = 0
            let picker = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) { fires += 1 }
            let repeatAction = backend.register(.repeatLast, accelerator: nil) { XCTFail("Repeat adapter is unbound") }
            XCTAssertNotEqual(repeatAction.id, picker.id)
            XCTAssertEqual(repeatAction.status, .unbound)
            XCTAssertEqual(backend.registration(for: .repeatLast), repeatAction)
            XCTAssertEqual(backend.currentRegistration, picker)
            XCTAssertFalse(backend.fire(.repeatLast))
            backend.unregister(repeatAction)
            XCTAssertEqual(backend.currentRegistration, picker)
            XCTAssertTrue(backend.fire(.togglePicker))
            XCTAssertEqual(fires, 1)
            let cleared = backend.register(.togglePicker, accelerator: nil) { XCTFail("Cleared picker fired") }
            XCTAssertEqual(cleared.status, .unbound)
            XCTAssertEqual(backend.currentRegistration, cleared)
            XCTAssertFalse(backend.fire(.togglePicker))
            var completions = 0
            backend.configure { completions += 1 }
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(fires, 1)
            backend.shutdown()
        }
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testRegistrationIsQuietUntilExplicitSetupAction() throws {
        let tools = try fakeSettings()
        let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        _ = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {}
        XCTAssertTrue(tools.arguments.isEmpty)
        var finished = false
        backend.configure { finished = true }
        XCTAssertTrue(GTKTestSupport.spin { finished })
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertTrue(tools.arguments.contains { $0.first == "set" })
    }

    func testOwnedNameWithForeignCommandIsNeverOverwritten() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_BINDINGS"] = "['\(base)custom0/']"
        tools.environment["FAKE_NAME"] = "'Monkey\\'s Paw: toggle'"
        tools.environment["FAKE_COMMAND"] = "'foreign-command'"
        tools.environment["FAKE_ACCELERATOR"] = "'<Control><Alt>p'"
        XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner)
            .install(accelerator: try Accelerator("Ctrl+Alt+P")))
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
    }

    func testBackendReportsLiveStateAndForwardsTheAction() throws {
        let tools = try fakeSettings()
        let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        var changes = 0
        var fires = 0
        backend.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            changes += 1
        }
        let registration = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {
            fires += 1
        }
        XCTAssertEqual(registration.mechanism, .gnomeCustomKeybinding)
        XCTAssertEqual(registration.status, .needsAction)
        backend.configure {}
        XCTAssertTrue(GTKTestSupport.spin { changes == 1 })
        XCTAssertEqual(backend.currentRegistration.id, registration.id)
        XCTAssertEqual(backend.currentRegistration.status, .registered)
        XCTAssertTrue(backend.fire(.togglePicker))
        XCTAssertEqual(fires, 1)
        let calls = tools.arguments.count
        backend.unregister(registration)
        XCTAssertFalse(backend.fire(.togglePicker))
        // App exit/unregister must not remove the user's compositor binding.
        XCTAssertEqual(tools.arguments.count, calls)
    }

    func testBackendFailureOffersTheManualCommand() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_FAIL_KEY"] = "binding"
        let backend = GnomeKeybindingBackend(runner: tools.runner, mainThread: GLibMainThread())
        _ = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {}
        backend.configure {}
        XCTAssertTrue(GTKTestSupport.spin { backend.currentRegistration.status == .failed })
        XCTAssertTrue(backend.currentRegistration.detail.contains(GnomeKeybindingInstaller.command))
    }

    func testManualBackendExposesTheCommandAndUnregisters() throws {
        let backend = ManualHotkeyBackend()
        var fires = 0
        let registration = backend.register(.togglePicker, accelerator: try Accelerator("Ctrl+Alt+P")) {
            fires += 1
        }
        XCTAssertEqual(registration.mechanism, .manual)
        XCTAssertEqual(registration.status, .needsAction)
        XCTAssertEqual(registration.detail, GnomeKeybindingInstaller.command)
        XCTAssertTrue(backend.fire(.togglePicker))
        XCTAssertEqual(fires, 1)
        backend.unregister(registration)
        XCTAssertFalse(backend.fire(.togglePicker))
    }

    func testPublishesCompleteRowAndPreservesOtherBindings() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_BINDINGS"] = "['\(base)custom0/', '\(base)custom2/']"
        let result = GnomeKeybindingInstaller(runner: tools.runner).install(accelerator: try Accelerator("Ctrl+Alt+P"))
        XCTAssertEqual(result, "<Control><Alt>p")
        let sets = tools.arguments.filter { $0.first == "set" }
        let target = itemSchema + ":" + base + "custom1/"
        XCTAssertEqual(sets, [
            ["set", target, "command", "'gapplication action ch.lkmc.monkeyspaw toggle'"],
            ["set", target, "binding", "'<Control><Alt>p'"],
            ["set", target, "name", "'Monkey\\'s Paw: toggle'"],
            ["set", schema, "custom-keybindings", "['\(base)custom0/', '\(base)custom2/', '\(base)custom1/']"],
        ])
    }

    func testEmptyListAndVariantParser() throws {
        for empty in ["@as []", "[]"] {
            let tools = try fakeSettings()
            tools.environment["FAKE_BINDINGS"] = empty
            XCTAssertNotNil(GnomeKeybindingInstaller(runner: tools.runner)
                .install(accelerator: try Accelerator("Ctrl+Alt+P")))
            XCTAssertEqual(tools.arguments.last, ["set", schema, "custom-keybindings", "['\(base)custom0/']"])
        }
        XCTAssertEqual(GnomeKeybindingInstaller.paths(in: "@as []"), [])
        XCTAssertEqual(GnomeKeybindingInstaller.paths(in: GnomeKeybindingInstaller.encode(["/a/", "/b/"])), ["/a/", "/b/"])
        for malformed in ["garbage", "['/a/',", "['relative/']", "['/double//slash/']"] {
            XCTAssertNil(GnomeKeybindingInstaller.paths(in: malformed))
        }
    }

    func testFailedOrMalformedListNeverWrites() throws {
        for value in ["FAIL", "malformed", "['/bad']"] {
            let tools = try fakeSettings()
            tools.environment["FAKE_BINDINGS"] = value
            XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner)
                .install(accelerator: try Accelerator("Ctrl+Alt+P")))
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testFailedFieldWriteNeverPublishesTheList() throws {
        for key in ["command", "binding", "name", "custom-keybindings"] {
            let tools = try fakeSettings()
            tools.environment["FAKE_FAIL_KEY"] = key
            XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner)
                .install(accelerator: try Accelerator("Ctrl+Alt+P")))
            if key != "custom-keybindings" {
                XCTAssertFalse(tools.arguments.contains { $0.prefix(3) == ["set", schema, "custom-keybindings"] })
            }
        }
    }

    func testExistingOwnedRowPreservesUserBindingIncludingUnbound() throws {
        for binding in ["<Control><Alt>e", ""] {
            let tools = try fakeSettings()
            tools.environment["FAKE_BINDINGS"] = "['\(base)custom0/']"
            tools.environment["FAKE_NAME"] = "'Monkey\\'s Paw: toggle'"
            tools.environment["FAKE_COMMAND"] = "'gapplication action ch.lkmc.monkeyspaw toggle'"
            tools.environment["FAKE_ACCELERATOR"] = "'\(binding)'"
            XCTAssertEqual(GnomeKeybindingInstaller(runner: tools.runner)
                .install(accelerator: try Accelerator("Ctrl+Alt+P")), binding)
            XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
        }
    }

    func testFailedNameReadDoesNotClaimAnUnknownRow() throws {
        let tools = try fakeSettings()
        tools.environment["FAKE_BINDINGS"] = "['\(base)custom0/']"
        tools.environment["FAKE_NAME"] = "FAIL"
        XCTAssertNil(GnomeKeybindingInstaller(runner: tools.runner)
            .install(accelerator: try Accelerator("Ctrl+Alt+P")))
        XCTAssertFalse(tools.arguments.contains { $0.first == "set" })
    }

    private func row(_ tools: FakeLinuxTools, path: String, name: String, command: String, binding: String) throws {
        let directory = tools.directory.appendingPathComponent("settings" + path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, value) in ["name": name, "command": command, "binding": binding] {
            let quoted = "'" + value.replacingOccurrences(of: "'", with: "\\'") + "'"
            try Data(quoted.utf8).write(to: directory.appendingPathComponent(key))
        }
    }

    private func fakeSettings(hook: String = "") throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        tools.environment["FAKE_SETTINGS"] = tools.directory.appendingPathComponent("settings").path
        try tools.install("gsettings", script: """
            \(FakeLinuxTools.recordArguments)
            \(hook)
            bindings="${FAKE_BINDINGS:-@as []}"
            if [ -f "$FAKE_LOG.bindings" ]; then IFS= read -r bindings < "$FAKE_LOG.bindings"; fi
            case "$1:$3" in
                list-schemas:) printf '%s\\n' '\(schema)' ;;
                get:custom-keybindings)
                    [ "$bindings" = FAIL ] && exit 2
                    printf '%s\\n' "$bindings" ;;
                get:*)
                    path="${2#*:}"
                    value="''"
                    case "$bindings" in
                        *"$path"*)
                            case "$3" in
                                name) value="${FAKE_NAME:-'Other app'}" ;;
                                command) value="${FAKE_COMMAND:-'foreign-command'}" ;;
                                binding) value="${FAKE_ACCELERATOR:-''}" ;;
                            esac ;;
                    esac
                    if [ -f "$FAKE_SETTINGS$path/$3" ]; then
                        IFS= read -r value < "$FAKE_SETTINGS$path/$3"
                    fi
                    [ "$value" = FAIL ] && exit 2
                    printf '%s\\n' "$value" ;;
                set:*)
                    [ "$3" = "$FAKE_FAIL_KEY" ] && exit 2
                    if [ "$3" = custom-keybindings ]; then
                        printf '%s\\n' "$4" > "$FAKE_LOG.bindings"
                    else
                        path="${2#*:}"
                        /bin/mkdir -p "$FAKE_SETTINGS$path"
                        printf '%s\\n' "$4" > "$FAKE_SETTINGS$path/$3"
                    fi ;;
                *) exit 2 ;;
            esac
            """)
        return tools
    }
}
#endif
