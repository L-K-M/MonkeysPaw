#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// A flat tray menu supplied by composition. Zero is reserved for its root.
struct StatusNotifierEntry {
    let id: Int32
    let label: String
    let enabled: Bool
    let onActivate: (() -> Void)?

    init(id: Int32, label: String, enabled: Bool = true, onActivate: (() -> Void)? = nil) {
        precondition(id > 0 && !label.utf8.contains(0))
        self.id = id
        self.label = label
        self.enabled = enabled
        self.onActivate = onActivate
    }
}

/// Own and release on the default GLib loop's thread, like the other GDBus
/// drivers. A missing watcher is normal on stock GNOME; no service is started.
final class LinuxStatusNotifierItem {
    private enum ConnectionOwnership { case dedicated, shared }
    private final class Box {
        weak var owner: LinuxStatusNotifierItem?
        let generation: Int
        init(_ owner: LinuxStatusNotifierItem) {
            self.owner = owner
            generation = owner.generation
        }
        var current: LinuxStatusNotifierItem? {
            guard let owner, owner.isRunning, owner.generation == generation else { return nil }
            return owner
        }
    }

    private final class ConnectionAttempt {
        let box: Box
        let address: String?
        let cancellable = g_cancellable_new()!
        init(_ owner: LinuxStatusNotifierItem, address: String?) {
            box = Box(owner)
            self.address = address
        }
        deinit { g_object_unref(cancellable) }
    }

    private final class Registration {
        let box: Box
        let watcher: String
        let cancellable = g_cancellable_new()!
        init(_ owner: LinuxStatusNotifierItem, watcher: String) {
            box = Box(owner)
            self.watcher = watcher
        }
        deinit { g_object_unref(cancellable) }
    }

    private(set) var isAvailable = false
    var onAvailabilityChange: ((Bool) -> Void)?

    private let busAddress: String?
    private let onActivate: () -> Void
    // Release this name even when GIO supplies GTK's shared bus connection, so
    // the watcher can remove the item on stop without waiting for process exit.
    // Flatpak permits app-ID subnames without any foreign ownership grant.
    private let serviceName = "\(AppIdentity.linuxAppID).StatusNotifierItem-\(ProcessInfo.processInfo.processIdentifier)-1"
    private var isRunning = false
    private var generation = 0
    private var entries: [StatusNotifierEntry] = []
    private var revision: UInt32 = 1
    private var connection: OpaquePointer?
    private var attempt: ConnectionAttempt?
    private var registration: Registration?
    private var exports: [guint] = []
    private var nameOwner: guint = 0
    private var nameWatch: guint = 0
    private var ownsName = false
    private var watcher: String?

    init(busAddress: String? = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
         onActivate: @escaping () -> Void) {
        self.busAddress = busAddress
        self.onActivate = onActivate
    }

    deinit { stop() }

    func start() {
        precondition(Thread.isMainThread)
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let attempt = ConnectionAttempt(self, address: busAddress)
        self.attempt = attempt
        let callback: GAsyncReadyCallback = { _, result, data in
            // Balance the retained attempt before any other early return.
            guard let data else { return }
            let attempt = Unmanaged<ConnectionAttempt>.fromOpaque(data).takeRetainedValue()
            guard let result else { return }
            let connection = attempt.address == nil ? g_bus_get_finish(result, nil)
                : g_dbus_connection_new_for_address_finish(result, nil)
            guard let owner = attempt.box.current, owner.attempt === attempt else {
                if let connection { LinuxStatusNotifierItem.dispose(connection,
                    ownership: attempt.address == nil ? .shared : .dedicated) }
                return
            }
            owner.attempt = nil
            guard let connection else { owner.stop(); return }
            owner.connection = connection
            g_dbus_connection_set_exit_on_close(connection, 0)
            guard owner.exportObjects(connection) else { owner.stop(); return }
            owner.watchAndOwnName(connection)
        }
        let data = Unmanaged.passRetained(attempt).toOpaque()
        if let busAddress {
            let flags = GDBusConnectionFlags(rawValue:
                G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
                G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
            g_dbus_connection_new_for_address(busAddress, flags, nil, attempt.cancellable, callback, data)
        } else {
            g_bus_get(G_BUS_TYPE_SESSION, attempt.cancellable, callback, data)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        isRunning = false
        generation += 1
        if let attempt { g_cancellable_cancel(attempt.cancellable); self.attempt = nil }
        cancelRegistration()
        if nameWatch != 0 { g_bus_unwatch_name(nameWatch); nameWatch = 0 }
        if nameOwner != 0 { g_bus_unown_name(nameOwner); nameOwner = 0 }
        ownsName = false
        watcher = nil
        if let connection {
            for id in exports { g_dbus_connection_unregister_object(connection, id) }
            exports.removeAll()
            self.connection = nil
            Self.dispose(connection, ownership: busAddress == nil ? .shared : .dedicated)
        }
        publishAvailability(false)
    }

    /// IDs stay positive and unique across updates. Composition owns action
    /// policy, including the disabled Library unavailable row.
    func setEntries(_ entries: [StatusNotifierEntry]) {
        precondition(Thread.isMainThread)
        precondition(Set(entries.map(\.id)).count == entries.count)
        let previous = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0) })
        self.entries = entries
        revision &+= 1
        guard let connection else { return }

        emit("LayoutUpdated", StatusNotifierWire.tuple([
            g_variant_new_uint32(revision), g_variant_new_int32(0)]), on: connection)
        let changed = entries.filter {
            guard let old = previous[$0.id] else { return false }
            return old.label != $0.label || old.enabled != $0.enabled
        }
        guard !changed.isEmpty else { return }
        emit("ItemsPropertiesUpdated", StatusNotifierWire.tuple([
            StatusNotifierWire.groupProperties(changed, names: []),
            StatusNotifierWire.array("(ias)", [])]), on: connection)
    }

    func activate() {
        precondition(Thread.isMainThread)
        scheduleActivation(nil)
    }

    private func scheduleActivation(_ id: Int32?) {
        guard isRunning else { return }
        let generation = generation
        GTK.onMainLoop { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            guard let id else { self.onActivate(); return }
            guard let entry = self.entries.first(where: { $0.id == id }), entry.enabled else { return }
            entry.onActivate?()
        }
    }

    private static let releaseBox: GDestroyNotify = { data in
        if let data { Unmanaged<Box>.fromOpaque(data).release() }
    }

    private func watchAndOwnName(_ connection: OpaquePointer) {
        nameWatch = g_bus_watch_name_on_connection(connection, StatusNotifierWire.watcherName,
            G_BUS_NAME_WATCHER_FLAGS_NONE, { _, _, name, data in
                guard let name, let data,
                      let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current else { return }
                owner.cancelRegistration()
                owner.watcher = String(cString: name)
                owner.registerWithWatcher()
            }, { _, _, data in
                guard let data,
                      let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current else { return }
                owner.watcher = nil
                owner.cancelRegistration()
                owner.publishAvailability(false)
            }, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox)
        nameOwner = g_bus_own_name_on_connection(connection, serviceName,
            G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, { _, _, data in
                guard let data,
                      let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current else { return }
                owner.ownsName = true
                owner.registerWithWatcher()
            }, { _, _, data in
                guard let data,
                      let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current else { return }
                owner.ownsName = false
                owner.cancelRegistration()
                owner.publishAvailability(false)
            }, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox)
    }

    private func registerWithWatcher() {
        guard isRunning, ownsName, let watcher, let connection, registration == nil, !isAvailable else { return }
        let work = Registration(self, watcher: watcher)
        registration = work
        let type = g_variant_type_new("()")!
        defer { g_variant_type_free(type) }
        // Address the observed owner directly. NO_AUTO_START also prevents a
        // watcher disappearing between observation and call from being started.
        g_dbus_connection_call(connection, watcher, "/StatusNotifierWatcher", StatusNotifierWire.watcherName,
            "RegisterStatusNotifierItem", StatusNotifierWire.tuple([g_variant_new_string(serviceName)]), type,
            G_DBUS_CALL_FLAGS_NO_AUTO_START, Int32(Limits.portalCallTimeout.timeInterval * 1_000),
            work.cancellable, { source, result, data in
                guard let data else { return }
                let work = Unmanaged<Registration>.fromOpaque(data).takeRetainedValue()
                guard let source, let result else { return }
                let reply = g_dbus_connection_call_finish(mp_dbus_connection(source), result, nil)
                defer { if let reply { g_variant_unref(reply) } }
                guard let owner = work.box.current, owner.registration === work,
                      owner.watcher == work.watcher else { return }
                owner.registration = nil
                owner.publishAvailability(reply != nil)
            }, Unmanaged.passRetained(work).toOpaque())
    }

    private func cancelRegistration() {
        if let registration {
            self.registration = nil
            g_cancellable_cancel(registration.cancellable)
        }
    }

    private func publishAvailability(_ available: Bool) {
        guard isAvailable != available else { return }
        isAvailable = available
        let generation = generation
        GTK.onMainLoop { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onAvailabilityChange?(available)
        }
    }

    private func exportObjects(_ connection: OpaquePointer) -> Bool {
        guard let node = g_dbus_node_info_new_for_xml(StatusNotifierWire.xml, nil) else { return false }
        defer { g_dbus_node_info_unref(node) }
        var table = GDBusInterfaceVTable()
        table.method_call = { _, _, _, interface, method, parameters, invocation, data in
            guard let interface, let method, let parameters, let invocation, let data else { return }
            guard let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current else {
                g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownObject", "Item stopped")
                return
            }
            owner.receive(interface: String(cString: interface), method: String(cString: method),
                          parameters: parameters, invocation: invocation)
        }
        table.get_property = { _, _, _, interface, name, _, data in
            guard let interface, let name, let data,
                  Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().current != nil else { return nil }
            return StatusNotifierWire.property(String(cString: name), interface: String(cString: interface))
        }
        for (path, name) in [(StatusNotifierWire.itemPath, StatusNotifierWire.itemInterface),
                             (StatusNotifierWire.menuPath, StatusNotifierWire.menuInterface)] {
            guard let info = g_dbus_node_info_lookup_interface(node, name) else { return false }
            let data = Unmanaged.passRetained(Box(self)).toOpaque()
            let id = g_dbus_connection_register_object(connection, path, info, &table, data, Self.releaseBox, nil)
            guard id != 0 else { Unmanaged<Box>.fromOpaque(data).release(); return false }
            exports.append(id)
        }
        return true
    }

    private func receive(interface: String, method: String, parameters: OpaquePointer, invocation: OpaquePointer) {
        if interface == StatusNotifierWire.itemInterface {
            g_dbus_method_invocation_return_value(invocation, nil)
            if method == "Activate" { activate() }
            return
        }
        // GDBus validates signatures against the exported XML before dispatch.
        let first = g_variant_get_child_value(parameters, 0)!
        defer { g_variant_unref(first) }
        if method == "GetGroupProperties" {
            let names = g_variant_get_child_value(parameters, 1)!
            defer { g_variant_unref(names) }
            let ids = StatusNotifierWire.ids(first)
            let rows = ids.isEmpty ? entries : ids.compactMap { id in entries.first { $0.id == id } }
            var groups: [OpaquePointer?] = rows.map {
                StatusNotifierWire.tuple([g_variant_new_int32($0.id),
                    StatusNotifierWire.properties($0, names: StatusNotifierWire.strings(names))])
            }
            if ids.isEmpty || ids.contains(0) {
                groups.insert(StatusNotifierWire.tuple([g_variant_new_int32(0),
                    StatusNotifierWire.properties(nil, names: StatusNotifierWire.strings(names))]), at: 0)
            }
            g_dbus_method_invocation_return_value(invocation,
                StatusNotifierWire.tuple([StatusNotifierWire.array("(ia{sv})", groups)]))
            return
        }
        let id = g_variant_get_int32(first)
        let entry = entries.first { $0.id == id }
        guard id == 0 || entry != nil else {
            g_dbus_method_invocation_return_dbus_error(invocation, "com.canonical.dbusmenu.Error.InvalidMenuItem", "Unknown menu item")
            return
        }
        switch method {
        case "GetLayout":
            let depth = g_variant_get_child_value(parameters, 1)!
            let names = g_variant_get_child_value(parameters, 2)!
            defer { g_variant_unref(depth); g_variant_unref(names) }
            let recursion = g_variant_get_int32(depth)
            guard recursion >= -1 else {
                g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid recursion depth")
                return
            }
            let layout = StatusNotifierWire.layout(entry, children: id == 0 && recursion != 0 ? entries : [],
                                                   names: StatusNotifierWire.strings(names))
            g_dbus_method_invocation_return_value(invocation,
                StatusNotifierWire.tuple([g_variant_new_uint32(revision), layout]))
        case "AboutToShow":
            g_dbus_method_invocation_return_value(invocation, StatusNotifierWire.tuple([g_variant_new_boolean(0)]))
        case "Event":
            let event = g_variant_get_child_value(parameters, 1)!
            defer { g_variant_unref(event) }
            // Reply before callbacks that may quit or unexport the item.
            g_dbus_method_invocation_return_value(invocation, nil)
            if String(cString: g_variant_get_string(event, nil)) == "clicked", entry?.enabled == true {
                scheduleActivation(id)
            }
        default:
            // Unreachable while GDBus validates calls against the exported XML;
            // every invocation must still be completed exactly once.
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod",
                "Unknown menu method")
        }
    }

    private func emit(_ signal: String, _ value: OpaquePointer, on connection: OpaquePointer) {
        // emit_signal borrows a non-floating value; retain/sink and release here.
        g_variant_ref_sink(value)
        defer { g_variant_unref(value) }
        g_dbus_connection_emit_signal(connection, nil, StatusNotifierWire.menuPath,
                                      StatusNotifierWire.menuInterface, signal, value, nil)
    }

    private static func dispose(_ connection: OpaquePointer, ownership: ConnectionOwnership) {
        if ownership == .dedicated && g_dbus_connection_is_closed(connection) == 0 {
            g_dbus_connection_close(connection, nil, nil, nil)
        }
        g_object_unref(UnsafeMutableRawPointer(connection))
    }
}
#endif
