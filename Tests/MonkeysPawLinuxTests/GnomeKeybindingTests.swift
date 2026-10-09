#if os(Linux)
import MonkeysPawCore
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GnomeKeybindingTests: XCTestCase {
    private let schema = GnomeKeybindingInstaller.listSchema
    private let itemSchema = GnomeKeybindingInstaller.itemSchema
    private let base = GnomeKeybindingInstaller.basePath

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

    private func fakeSettings() throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        try tools.install("gsettings", script: """
            \(FakeLinuxTools.recordArguments)
            case "$1:$3" in
                list-schemas:) printf '%s\\n' '\(schema)' ;;
                get:custom-keybindings)
                    [ "$FAKE_BINDINGS" = FAIL ] && exit 2
                    printf '%s\\n' "${FAKE_BINDINGS:-@as []}" ;;
                get:name)
                    [ "$FAKE_NAME" = FAIL ] && exit 2
                    printf '%s\\n' "${FAKE_NAME:-'Other app'}" ;;
                get:binding) printf '%s\\n' "$FAKE_ACCELERATOR" ;;
                get:command) printf '%s\\n' "${FAKE_COMMAND:-'gapplication action ch.lkmc.monkeyspaw toggle'}" ;;
                set:*) [ "$3" = "$FAKE_FAIL_KEY" ] && exit 2; exit 0 ;;
                *) exit 2 ;;
            esac
            """)
        return tools
    }
}
#endif
