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
         home: URL? = nil) {
        self.environment = environment
        // g_get_home_dir() prefers HOME, falling back to the passwd home directory.
        let configuredHome = environment["HOME"].flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        self.home = home ?? configuredHome ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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

    /// Matches Unix load_user_special_dirs in GLib 2.74.6, glib/gutils.c:
    /// last accepted assignment wins; only the leading $HOME expands.
    /// Backslashes, embedded $ and backticks stay literal, never shell code.
    /// https://github.com/GNOME/glib/blob/2.74.6/glib/gutils.c
    var documentsDirectory: URL {
        let file = directory(environment: "XDG_CONFIG_HOME", fallback: ".config")
            .appendingPathComponent("user-dirs.dirs")
        var selected: URL?
        if let source = try? String(contentsOf: file, encoding: .utf8) {
            for line in source.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                }
                guard parts.count == 2, parts[0] == "XDG_DOCUMENTS_DIR",
                      var value = Self.quotedDirectory(parts[1]), !value.contains("\u{0}") else { continue }
                let isRelative = value.hasPrefix("$HOME")
                if isRelative { value = String(value.dropFirst(5)) }
                if value.hasSuffix("/") { value.removeLast() }
                let directory: URL
                if isRelative {
                    directory = home.appendingPathComponent(value, isDirectory: true)
                } else {
                    guard value.hasPrefix("/") else { continue }
                    directory = URL(fileURLWithPath: value, isDirectory: true)
                }
                guard directory.path.hasPrefix("/") else { continue }
                selected = directory
            }
        }
        return selected ?? home.appendingPathComponent("Documents", isDirectory: true)
    }

    private static func quotedDirectory(_ source: String) -> String? {
        guard source.first == "\"" else { return nil }
        let value = source.dropFirst()
        // GLib uses the final quote, preserving escapes and ignoring any suffix.
        guard let end = value.lastIndex(of: "\"") else { return nil }
        return String(value[..<end])
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
