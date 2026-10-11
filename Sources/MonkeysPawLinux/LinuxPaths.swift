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

    /// user-dirs.dirs is data, never a shell script. Expand only a leading HOME.
    var documentsDirectory: URL {
        let file = directory(environment: "XDG_CONFIG_HOME", fallback: ".config")
            .appendingPathComponent("user-dirs.dirs")
        if let source = try? String(contentsOf: file, encoding: .utf8) {
            for line in source.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, parts[0] == "XDG_DOCUMENTS_DIR",
                      let value = Self.quotedDirectory(parts[1]) else { continue }
                let path: String
                if value == "$HOME" || value.hasPrefix("$HOME/") {
                    path = home.path + value.dropFirst(5)
                } else if value == "${HOME}" || value.hasPrefix("${HOME}/") {
                    path = home.path + value.dropFirst(7)
                } else {
                    path = value
                }
                guard path.hasPrefix("/"), !path.contains("$"), !path.contains("`"),
                      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return home.appendingPathComponent("Documents", isDirectory: true)
    }

    private static func quotedDirectory(_ source: String) -> String? {
        guard source.first == "\"" else { return nil }
        var value = ""
        var escaped = false
        for index in source.indices.dropFirst() {
            let character = source[index]
            if escaped {
                guard ["\\", "\"", "$", "`"].contains(character) else { return nil }
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let tail = source[source.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? value : nil
            } else {
                value.append(character)
            }
        }
        return nil
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
