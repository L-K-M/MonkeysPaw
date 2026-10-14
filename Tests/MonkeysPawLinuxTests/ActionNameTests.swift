#if os(Linux)
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class ActionNameTests: XCTestCase {
    private var packagingDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packaging/linux", isDirectory: true)
    }

    func testDesktopActionIdentifiersMatchTheActionEnum() throws {
        let desktop = try String(contentsOf: packagingDirectory
            .appendingPathComponent("\(AppIdentity.linuxAppID).desktop"), encoding: .utf8)
        let actionLine = try XCTUnwrap(desktop.split(separator: "\n")
            .first { $0.hasPrefix("Actions=") })
        let actions = actionLine.dropFirst("Actions=".count)
            .split(separator: ";").map(String.init)

        XCTAssertEqual(actions, [ActionName.toggle.rawValue, "repeat", ActionName.selftest.rawValue,
                                ActionName.settings.rawValue, ActionName.library.rawValue])
        for action in actions {
            XCTAssertNotNil(ActionName(rawValue: action))
            XCTAssertTrue(desktop.contains("[Desktop Action \(action)]"))
            XCTAssertTrue(desktop.contains("Exec=gapplication action \(AppIdentity.linuxAppID) \(action)\n"))
        }
    }

    func testPackagingUsesOneApplicationIdentity() throws {
        let desktop = try String(contentsOf: packagingDirectory
            .appendingPathComponent("\(AppIdentity.linuxAppID).desktop"), encoding: .utf8)
        let service = try String(contentsOf: packagingDirectory
            .appendingPathComponent("\(AppIdentity.linuxAppID).service"), encoding: .utf8)

        XCTAssertTrue(desktop.contains("StartupWMClass=\(AppIdentity.linuxAppID)\n"))
        XCTAssertTrue(desktop.contains("DBusActivatable=true\n"))
        XCTAssertTrue(service.contains("Name=\(AppIdentity.linuxAppID)\n"))
        XCTAssertTrue(service.contains("Exec=/usr/bin/\(AppIdentity.binaryName) --gapplication-service\n"))
    }

    func testPackagingRecommendsTheDocumentedX11FocusTools() throws {
        let root = packagingDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let builder = try String(contentsOf: root.appendingPathComponent("packaging/build-deb.sh"), encoding: .utf8)
        let ci = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let guidance = try String(contentsOf: root.appendingPathComponent("docs/platform/linux.md"), encoding: .utf8)
        let recommendations = "libsecret-tools, ydotool, xdotool, x11-utils"
        XCTAssertTrue(builder.contains("Recommends: \(recommendations)\n"))
        XCTAssertTrue(ci.contains("test \"$(dpkg-deb --field \"$deb\" Recommends)\" = '\(recommendations)'"))
        XCTAssertTrue(guidance.contains("`xdotool` and `xprop` (`x11-utils` on Debian/Ubuntu)"))
        XCTAssertTrue(builder.contains("DEPENDS=\"$DEPENDS, libglib2.0-bin\""), "gapplication must be available for both actions")
        XCTAssertFalse(builder.contains("gsettings set"))
        XCTAssertFalse(builder.contains("postinst"))
    }
}
#endif
