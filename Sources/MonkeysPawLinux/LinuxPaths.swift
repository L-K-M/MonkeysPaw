#if os(Linux)
import Foundation
import MonkeysPawCore

/// Read XDG variables directly: Foundation's applicationSupportDirectory
/// hard-codes ~/.local/share on Linux and ignores XDG_DATA_HOME entirely.
/// Unset, empty and relative values fall back instead of becoming invalid paths.
struct LinuxPaths {
    private let environment: [String: String]
    private let home: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.environment = environment
        // NSHomeDirectory consults HOME and then passwd, including service accounts.
        self.home = home
    }

    /// $XDG_CONFIG_HOME/monkeyspaw, else ~/.config/monkeyspaw.
    var configDirectory: URL {
        directory(environment: "XDG_CONFIG_HOME", fallback: ".config")
            .appendingPathComponent(AppIdentity.binaryName, isDirectory: true)
    }

    /// $XDG_DATA_HOME/monkeyspaw, else ~/.local/share/monkeyspaw.
    var dataDirectory: URL {
        directory(environment: "XDG_DATA_HOME", fallback: ".local/share")
            .appendingPathComponent(AppIdentity.binaryName, isDirectory: true)
    }

    /// Runtime storage is optional until a driver can create a private fallback.
    /// Persistent config/data directories cannot stand in for a login's runtime dir.
    var runtimeDirectory: URL? {
        absoluteDirectory(environment: "XDG_RUNTIME_DIR")?
            .appendingPathComponent(AppIdentity.binaryName, isDirectory: true)
    }

    private func directory(environment key: String, fallback: String) -> URL {
        absoluteDirectory(environment: key)
            ?? home.appendingPathComponent(fallback, isDirectory: true)
    }

    private func absoluteDirectory(environment key: String) -> URL? {
        guard let value = environment[key], !value.isEmpty, value.hasPrefix("/") else {
            return nil
        }

        return URL(fileURLWithPath: value, isDirectory: true)
    }
}
#endif
