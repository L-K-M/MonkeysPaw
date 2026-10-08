#if os(Linux)
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class LinuxPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/test-user", isDirectory: true)

    func testAbsoluteXDGDirectoriesAreHonored() {
        let paths = LinuxPaths(environment: [
            "XDG_CONFIG_HOME": "/relocated/config",
            "XDG_DATA_HOME": "/relocated/data",
            "XDG_RUNTIME_DIR": "/run/user/1000",
        ], home: home)

        XCTAssertEqual(paths.configDirectory.path, "/relocated/config/monkeyspaw")
        XCTAssertEqual(paths.dataDirectory.path, "/relocated/data/monkeyspaw")
        XCTAssertEqual(paths.runtimeDirectory?.path, "/run/user/1000/monkeyspaw")
    }

    func testUnsetDirectoriesUseHomeFallbacks() {
        assertFallbacks(environment: [:])
    }

    func testEmptyDirectoriesUseHomeFallbacks() {
        assertFallbacks(environment: [
            "XDG_CONFIG_HOME": "",
            "XDG_DATA_HOME": "",
            "XDG_RUNTIME_DIR": "",
        ])
    }

    func testRelativeDirectoriesUseHomeFallbacks() {
        assertFallbacks(environment: [
            "XDG_CONFIG_HOME": "config",
            "XDG_DATA_HOME": "../data",
            "XDG_RUNTIME_DIR": "~/run",
        ])
    }

    func testTrailingSlashesDoNotChangeAppDirectories() {
        let paths = LinuxPaths(environment: [
            "XDG_CONFIG_HOME": "/config/",
            "XDG_DATA_HOME": "/data/",
            "XDG_RUNTIME_DIR": "/run/",
        ], home: home)

        XCTAssertEqual(paths.configDirectory.path, "/config/monkeyspaw")
        XCTAssertEqual(paths.dataDirectory.path, "/data/monkeyspaw")
        XCTAssertEqual(paths.runtimeDirectory?.path, "/run/monkeyspaw")
    }

    func testDefaultInitializerReadsTheProcessEnvironment() {
        let expected = LinuxPaths(environment: ProcessInfo.processInfo.environment,
                                  home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        let actual = LinuxPaths()

        XCTAssertEqual(actual.configDirectory, expected.configDirectory)
        XCTAssertEqual(actual.dataDirectory, expected.dataDirectory)
        XCTAssertEqual(actual.runtimeDirectory, expected.runtimeDirectory)
    }

    private func assertFallbacks(environment: [String: String],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let paths = LinuxPaths(environment: environment, home: home)

        XCTAssertEqual(paths.configDirectory.path, "/home/test-user/.config/monkeyspaw", file: file, line: line)
        XCTAssertEqual(paths.dataDirectory.path, "/home/test-user/.local/share/monkeyspaw", file: file, line: line)
        XCTAssertNil(paths.runtimeDirectory, file: file, line: line)
    }
}
#endif
