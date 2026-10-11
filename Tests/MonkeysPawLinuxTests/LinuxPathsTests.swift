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
        XCTAssertEqual(actual.documentsDirectory, expected.documentsDirectory)
    }

    func testDocumentsExpandsHomeInUserDirectories() throws {
        try withDirectories { directory in
            let config = directory.appendingPathComponent(".config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try Data("# ignored\nXDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\nXDG_DOCUMENTS_DIR=\"$HOME/My Documents\"\n".utf8)
                .write(to: config.appendingPathComponent("user-dirs.dirs"))
            let paths = LinuxPaths(environment: [:], home: directory)
            XCTAssertEqual(paths.documentsDirectory.path, directory.appendingPathComponent("My Documents").path)
        }
    }

    func testDocumentsUsesConfigOverrideAndAbsoluteQuotedPath() throws {
        try withDirectories { directory in
            try Data(" XDG_DOCUMENTS_DIR = \"/relocated/Doc \\\"files\\\"\" # comment\n".utf8)
                .write(to: directory.appendingPathComponent("user-dirs.dirs"))
            let paths = LinuxPaths(environment: ["XDG_CONFIG_HOME": directory.path], home: home)
            XCTAssertEqual(paths.documentsDirectory.path, "/relocated/Doc \"files\"")
        }
    }

    func testDocumentsUsesInjectedHomeEnvironmentAndHomeOnlySetting() throws {
        try withDirectories { directory in
            for value in ["$HOME", "${HOME}", "${HOME}/Docs"] {
                try Data("XDG_DOCUMENTS_DIR=\"\(value)\"\n".utf8)
                    .write(to: directory.appendingPathComponent("user-dirs.dirs"))
                let paths = LinuxPaths(environment: ["HOME": "/relocated/home", "XDG_CONFIG_HOME": directory.path])
                XCTAssertEqual(paths.documentsDirectory.path, value.hasSuffix("/Docs") ? "/relocated/home/Docs" : "/relocated/home")
            }
        }
    }

    func testDocumentsFallsBackForMissingOrMalformedSettings() throws {
        try withDirectories { directory in
            let paths = LinuxPaths(environment: ["XDG_CONFIG_HOME": directory.path], home: home)
            XCTAssertEqual(paths.documentsDirectory.path, "/home/test-user/Documents")
            for value in ["", "# XDG_DOCUMENTS_DIR=\"/ignored\"", "XDG_DOCUMENTS_DIR=Documents",
                          "XDG_DOCUMENTS_DIR=\"relative\"", "XDG_DOCUMENTS_DIR=\"\"",
                          "XDG_DOCUMENTS_DIR=\"$OTHER/docs\"", "XDG_DOCUMENTS_DIR=\"$(touch /tmp/wrong)\"",
                          "XDG_DOCUMENTS_DIR=\"/unterminated", "XDG_DOCUMENTS_DIR=\"/valid\"; command"] {
                try Data(value.utf8).write(to: directory.appendingPathComponent("user-dirs.dirs"))
                XCTAssertEqual(paths.documentsDirectory.path, "/home/test-user/Documents")
            }
        }
    }

    private func withDirectories(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp-documents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
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
