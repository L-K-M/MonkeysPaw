#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Vervellum's owned-name/lowest-free-slot mechanism, with checked writes.
/// Run only from explicit Setup, never from startup or postinst (§6.1).
struct GnomeKeybindingInstaller {
    static let command = command(for: .togglePicker)
    static let bindingName = bindingName(for: .togglePicker)
    static let listSchema = "org.gnome.settings-daemon.plugins.media-keys"
    static let itemSchema = listSchema + ".custom-keybinding"
    static let basePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"

    private let runner: LinuxToolRunner

    init(runner: LinuxToolRunner) { self.runner = runner }

    static func command(for action: HotkeyAction) -> String {
        "gapplication action \(AppIdentity.linuxAppID) \(actionName(for: action))"
    }

    static func bindingName(for action: HotkeyAction) -> String {
        "Monkey's Paw: \(actionName(for: action))"
    }

    private static func actionName(for action: HotkeyAction) -> String {
        switch action {
        case .togglePicker: return "toggle"
        case .repeatLast: return "repeat"
        }
    }

    private struct Row: Equatable {
        let name: String
        let command: String
        let binding: String
        var isEmpty: Bool { name.isEmpty && command.isEmpty && binding.isEmpty }
    }

    private func row(at path: String, deadline: ContinuousClock.Instant) -> Row? {
        let schema = Self.itemSchema + ":" + path
        guard let rawName = run(["get", schema, "name"], deadline: deadline), let name = Self.string(in: rawName),
              let rawCommand = run(["get", schema, "command"], deadline: deadline), let command = Self.string(in: rawCommand),
              let rawBinding = run(["get", schema, "binding"], deadline: deadline), let binding = Self.string(in: rawBinding) else {
            return nil
        }
        return Row(name: name, command: command, binding: binding)
    }

    /// An existing complete row is the installation record. Preserve a binding
    /// the user changed in GNOME Settings rather than resetting it on Setup retry.
    func install(action: HotkeyAction = .togglePicker, accelerator: Accelerator,
                 deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: Limits.portalConsentTimeout)) -> String? {
        guard let schemas = run(["list-schemas"], deadline: deadline),
              schemas.split(separator: "\n").contains(Substring(Self.listSchema)),
              let raw = run(["get", Self.listSchema, "custom-keybindings"], deadline: deadline),
              let paths = Self.paths(in: raw) else { return nil }

        let command = Self.command(for: action)
        let name = Self.bindingName(for: action)
        var ownedBinding: String?
        for path in paths {
            guard let existing = row(at: path, deadline: deadline) else { return nil }
            guard existing.name == name || existing.command == command else { continue }
            guard existing.name == name, existing.command == command, ownedBinding == nil else { return nil }
            ownedBinding = existing.binding
        }
        if let ownedBinding { return ownedBinding }

        guard let binding = try? accelerator.gtkAccelerator() else { return nil }
        var index = 0
        var slot: String
        while true {
            slot = Self.basePath + "custom\(index)/"
            index += 1
            guard !paths.contains(slot) else { continue }
            // Removing a list entry leaves its dconf fields behind. Never claim
            // a dormant foreign or edited row just because it is unpublished.
            guard let candidate = row(at: slot, deadline: deadline) else { return nil }
            if candidate.isEmpty { break }
        }
        let schema = Self.itemSchema + ":" + slot

        // Publish only after every field was written. A failed read/write is
        // never interpreted as an empty list that could erase other bindings.
        guard let latest = run(["get", Self.listSchema, "custom-keybindings"], deadline: deadline),
              Self.paths(in: latest) == paths,
              row(at: slot, deadline: deadline)?.isEmpty == true,
              run(["set", schema, "command", Self.quote(command)], deadline: deadline) != nil,
              run(["set", schema, "binding", Self.quote(binding)], deadline: deadline) != nil,
              run(["set", schema, "name", Self.quote(name)], deadline: deadline) != nil,
              row(at: slot, deadline: deadline) == Row(name: name, command: command, binding: binding),
              let beforePublish = run(["get", Self.listSchema, "custom-keybindings"], deadline: deadline),
              Self.paths(in: beforePublish) == paths,
              run(["set", Self.listSchema, "custom-keybindings", Self.encode(paths + [slot])], deadline: deadline) != nil else {
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
        var rows: [String: Row] = [:]
        for path in paths {
            guard let row = row(at: path, deadline: deadline) else { return .unavailable }
            rows[path] = row
            guard HotkeyAction.allCases.contains(where: {
                row.name == Self.bindingName(for: $0) || row.command == Self.command(for: $0)
            }) else { continue }
            guard !row.binding.isEmpty else { continue }
            // Every repeat key was user-assigned; none is a retireable default.
            guard row.name == Self.bindingName, row.command == Self.command, row.binding == defaultBinding else {
                return .editedBinding
            }
            retired.insert(path)
        }
        guard !retired.isEmpty else { return .ready }
        // Recheck every row, including repeat becoming active, before publishing.
        // Separate CLI calls cannot prevent an edit after the final checks.
        guard let latest = read(["get", Self.listSchema, "custom-keybindings"]),
              Self.paths(in: latest) == paths else { return .unavailable }
        for path in paths {
            guard let current = row(at: path, deadline: deadline) else { return .unavailable }
            guard current == rows[path] else { return .editedBinding }
        }
        guard read(["set", Self.listSchema, "custom-keybindings", Self.encode(paths.filter { !retired.contains($0) })]) != nil else {
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
