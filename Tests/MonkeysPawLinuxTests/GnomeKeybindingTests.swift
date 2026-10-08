#if os(Linux)
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class GnomeKeybindingTests: XCTestCase {
    private let schema = GnomeKeybindingInstaller.listSchema
    private let itemSchema = GnomeKeybindingInstaller.itemSchema
    private let base = GnomeKeybindingInstaller.basePath

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
            XCTAssertEqual(tools.arguments.filter { $0.first == "set" }.count, 1)
            XCTAssertEqual(tools.arguments.last?[2], "command")
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
                set:*) [ "$3" = "$FAKE_FAIL_KEY" ] && exit 2; exit 0 ;;
                *) exit 2 ;;
            esac
            """)
        return tools
    }
}
#endif
