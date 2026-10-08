#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Vervellum's owned-name/lowest-free-slot mechanism, with checked writes.
/// Run at user launch, never from a package's root postinst (§6.1).
struct GnomeKeybindingInstaller {
    static let command = "gapplication action \(AppIdentity.linuxAppID) toggle"
    static let bindingName = "Monkey's Paw: toggle"
    static let listSchema = "org.gnome.settings-daemon.plugins.media-keys"
    static let itemSchema = listSchema + ".custom-keybinding"
    static let basePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"

    private let runner: LinuxToolRunner

    init(runner: LinuxToolRunner) { self.runner = runner }

    /// An existing complete row is the installation record. Preserve a binding
    /// the user changed in GNOME Settings rather than resetting it each launch.
    func install(accelerator: Accelerator) -> String? {
        guard let schemas = run(["list-schemas"]),
              schemas.split(separator: "\n").contains(Substring(Self.listSchema)),
              let raw = run(["get", Self.listSchema, "custom-keybindings"]),
              let paths = Self.paths(in: raw) else { return nil }

        for path in paths {
            let schema = Self.itemSchema + ":" + path
            guard let rawName = run(["get", schema, "name"]),
                  let name = Self.string(in: rawName) else { return nil }
            guard name == Self.bindingName else { continue }

            guard let rawBinding = run(["get", schema, "binding"]),
                  let binding = Self.string(in: rawBinding),
                  let rawCommand = run(["get", schema, "command"]),
                  Self.string(in: rawCommand) == Self.command else { return nil }
            return binding
        }

        guard let binding = try? accelerator.gtkAccelerator() else { return nil }
        var index = 0
        while paths.contains(Self.basePath + "custom\(index)/") { index += 1 }
        let slot = Self.basePath + "custom\(index)/"
        let schema = Self.itemSchema + ":" + slot

        // Publish only after every field was written. A failed read/write is
        // never interpreted as an empty list that could erase other bindings.
        guard run(["set", schema, "command", Self.quote(Self.command)]) != nil,
              run(["set", schema, "binding", Self.quote(binding)]) != nil,
              run(["set", schema, "name", Self.quote(Self.bindingName)]) != nil,
              run(["set", Self.listSchema, "custom-keybindings", Self.encode(paths + [slot])]) != nil else {
            return nil
        }
        return binding
    }

    enum PortalMigration { case ready, editedBinding, unavailable }

    /// Retire only untouched M1b defaults. Fields and foreign list entries survive.
    /// Inspect every row before the single list write, failing closed on ambiguity.
    func prepareForPortal(deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: Limits.portalConsentTimeout)) -> PortalMigration {
        func read(_ arguments: [String]) -> String? { run(arguments, deadline: deadline) }
        guard let raw = read(["get", Self.listSchema, "custom-keybindings"]),
              let paths = Self.paths(in: raw),
              let defaultBinding = try? Accelerator.defaultBinding(for: .togglePicker)?.gtkAccelerator() else {
            return .unavailable
        }
        var retired = Set<String>()
        for path in paths {
            let schema = Self.itemSchema + ":" + path
            guard let rawName = read(["get", schema, "name"]), let name = Self.string(in: rawName),
                  let rawCommand = read(["get", schema, "command"]), let command = Self.string(in: rawCommand),
                  let rawBinding = read(["get", schema, "binding"]), let binding = Self.string(in: rawBinding) else {
                return .unavailable
            }
            guard name == Self.bindingName || command == Self.command else { continue }
            guard !binding.isEmpty else { continue }
            guard name == Self.bindingName, command == Self.command, binding == defaultBinding else {
                return .editedBinding
            }
            retired.insert(path)
        }
        guard !retired.isEmpty else { return .ready }
        // Re-read before publishing so a concurrent settings edit is not lost.
        guard let latest = read(["get", Self.listSchema, "custom-keybindings"]),
              Self.paths(in: latest) == paths,
              read(["set", Self.listSchema, "custom-keybindings", Self.encode(paths.filter { !retired.contains($0) })]) != nil else {
            return .unavailable
        }
        return .ready
    }

    static func paths(in text: String) -> [String]? {
        guard let raw = mp_parse_string_array(text) else { return nil }
        defer { g_strfreev(raw) }
        var result: [String] = []
        var cursor = raw
        while let item = cursor.pointee {
            let path = String(cString: item)
            // Relocatable schema paths must be valid dconf paths, not arbitrary
            // strings. Abort rather than replacing malformed external state.
            guard path.hasPrefix("/"), path.hasSuffix("/"), !path.contains("//"),
                  path.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte)
                          || (97...122).contains(byte) || [45, 47, 95].contains(byte)
                  }) else { return nil }
            result.append(path)
            cursor += 1
        }
        return result
    }

    static func encode(_ paths: [String]) -> String {
        paths.isEmpty ? "@as []" : "[" + paths.map(quote).joined(separator: ", ") + "]"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static func string(in text: String) -> String? {
        guard let raw = mp_parse_string(text) else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func run(_ arguments: [String], deadline: ContinuousClock.Instant? = nil) -> String? {
        let budget: Duration
        if let deadline {
            guard ContinuousClock.now < deadline else { return nil }
            budget = min(Limits.linuxToolTimeout, ContinuousClock.now.duration(to: deadline))
        } else { budget = Limits.linuxToolTimeout }
        guard case .success(let output) = runner.run("gsettings", arguments: arguments, timeout: budget) else { return nil }
        return output.text
    }
}
#endif
