#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// One native resident action, owned by the default GLib loop. The KDE daemon
/// owns persistent key choices; this driver owns presence and release callbacks.
final class KGlobalAccelHotkeyBackend: LinuxHotkeyBackend {
    private enum State { case idle, loading, ready, failed, stopped }
    private enum Operation { case registration, refresh }
    private enum OwnerAcquisition { case existing, started }
    private enum ConnectionOwnership { case owned, shared }

    private final class Work {
        let deadline: ContinuousClock.Instant
        let cancellable = g_cancellable_new()!
        var timer: guint = 0
        var completions: [() -> Void]
        init(budget: Duration, done: (() -> Void)?) {
            deadline = ContinuousClock.now.advanced(by: budget)
            completions = done.map { [$0] } ?? []
        }
        deinit { g_object_unref(cancellable) }
    }

    private final class Box {
        weak var owner: KGlobalAccelHotkeyBackend?
        let work: Work?
        let generation: Int
        let ownership: ConnectionOwnership
        let reply: ((OpaquePointer) -> Void)?
        let failure: ((UnsafeMutablePointer<GError>) -> Void)?
        init(_ owner: KGlobalAccelHotkeyBackend, work: Work? = nil,
             failure: ((UnsafeMutablePointer<GError>) -> Void)? = nil,
             reply: ((OpaquePointer) -> Void)? = nil) {
            self.owner = owner
            self.work = work
            generation = owner.generation
            ownership = owner.ownership
            self.reply = reply
            self.failure = failure
        }
    }

    private final class Flush {
        let cancellable = g_cancellable_new()!
        var timer: guint = 0
        deinit { g_object_unref(cancellable) }
    }

    let mechanism = HotkeyMechanism.kglobalaccel
    var onChange: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(mechanism: .kglobalaccel,
        status: .needsAction, detail: LinuxStrings.kdeRegistering)
    private let busAddress: String?
    private let budget: Duration
    private var connection: OpaquePointer?
    private var closedSignal: gulong = 0
    private var ownerSubscription: guint = 0
    private var subscriptions: [guint] = []
    private var ownerName: String?
    private var registeredOwner: String?
    private var componentPath: String?
    private var work: Work?
    private var state = State.idle
    private var generation = 0
    private var keysRevision = 0
    private var assigned = KGlobalAccelKeys(sequences: [])
    private var suggestion = KGlobalAccelKeys(sequences: [])
    private var onFire: (() -> Void)?

    init(busAddress: String? = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
         callBudget: Duration = Limits.kglobalaccelTimeout) {
        self.busAddress = busAddress
        budget = callBudget
    }

    deinit { shutdown() }

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        precondition(Thread.isMainThread)
        guard action == .togglePicker else {
            return HotkeyRegistration(mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        guard state != .stopped else {
            return HotkeyRegistration(mechanism: mechanism, status: .failed, detail: LinuxStrings.kdeUnavailable)
        }
        if self.onFire != nil { unregister(currentRegistration) }
        self.onFire = onFire
        suggestion = KGlobalAccelWire.translate(accelerator)
        currentRegistration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
            detail: LinuxStrings.kdeRegistering, configuration: .systemSettings)
        begin(.registration)
        return currentRegistration
    }

    func configure(done: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard state != .stopped, onFire != nil else { done(); return }
        if let work { work.completions.append(done); return }
        begin(state == .ready ? .refresh : .registration, done: done)
    }

    // GApplication/manual toggles must never verify a native release binding.
    func fire(_ action: HotkeyAction) -> Bool { false }

    func unregister(_ registration: HotkeyRegistration) {
        precondition(Thread.isMainThread)
        guard currentRegistration.id == registration.id else { return }
        onFire = nil
        generation += 1
        deactivate()
        removeSubscriptions()
        state = state == .stopped ? .stopped : .idle
        finish()
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        guard state != .stopped else { return }
        state = .stopped
        onFire = nil
        generation += 1
        deactivate()
        removeSubscriptions()
        finish()
        releaseConnection()
        onChange = nil
    }

    private func begin(_ operation: Operation, done: (() -> Void)? = nil) {
        let work = Work(budget: budget, done: done)
        self.work = work
        state = .loading
        publish(.needsAction, LinuxStrings.kdeRegistering)
        work.timer = GTK.after(budget.timeInterval) { [weak self, weak work] in
            guard let self, let work, self.work === work else { return }
            work.timer = 0
            self.fail(LinuxStrings.kdeTimedOut)
        }
        if operation == .refresh {
            readKeys(work) { [weak self] in self?.checkAssignment(work) }
            return
        }
        generation += 1
        removeSubscriptions()
        ownerName = nil
        componentPath = nil
        if connection != nil { acquireOwner(work) } else { connect(work) }
    }

    private func connect(_ work: Work) {
        let box = Box(self, work: work)
        let data = Unmanaged.passRetained(box).toOpaque()
        let callback: GAsyncReadyCallback = { _, result, data in
            guard let result, let data else { return }
            let box = Unmanaged<Box>.fromOpaque(data).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            let connection = box.ownership == .shared
                ? g_bus_get_finish(result, &error)
                : g_dbus_connection_new_for_address_finish(result, &error)
            defer { g_clear_error(&error) }
            guard let owner = box.owner, let work = box.work, owner.work === work, owner.state != .stopped else {
                if let connection { KGlobalAccelHotkeyBackend.dispose(connection, ownership: box.ownership) }
                return
            }
            guard let connection else { owner.fail(LinuxStrings.kdeUnavailable); return }
            owner.connection = connection
            g_dbus_connection_set_exit_on_close(connection, 0)
            owner.observeConnection(connection)
            owner.acquireOwner(work)
        }
        if let busAddress {
            let flags = GDBusConnectionFlags(rawValue: G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
                G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
            g_dbus_connection_new_for_address(busAddress, flags, nil, work.cancellable, callback, data)
        } else {
            g_bus_get(G_BUS_TYPE_SESSION, work.cancellable, callback, data)
        }
    }

    private func acquireOwner(_ work: Work, mode: OwnerAcquisition = .existing) {
        // An already running daemon needs no activation file. StartServiceByName
        // may fail for an owned but non-activatable service, so look it up first.
        call(work, destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
             interface: "org.freedesktop.DBus", method: "GetNameOwner",
             parameters: KGlobalAccelWire.tuple([g_variant_new_string(KGlobalAccelWire.busName)]),
             failure: { [weak self] error in
                 guard let self else { return }
                 if mode == .existing, g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_NAME_HAS_NO_OWNER.rawValue)) != 0 {
                     self.startService(work)
                 } else { self.fail(LinuxStrings.kdeUnavailable) }
             }) { [weak self] reply in
            guard let self else { return }
            guard KGlobalAccelWire.hasType(reply, "(s)") else { self.fail(LinuxStrings.kdeUnavailable); return }
            let value = g_variant_get_child_value(reply, 0)!
            defer { g_variant_unref(value) }
            let owner = String(cString: g_variant_get_string(value, nil))
            guard g_dbus_is_unique_name(owner) != 0 else { self.fail(LinuxStrings.kdeUnavailable); return }
            self.ownerName = owner
            self.registerAction(work)
        }
    }

    private func startService(_ work: Work) {
        // Only a registration attempt can start a daemon. Later calls are pinned
        // to its unique owner; loss waits for a new explicit Setup retry.
        call(work, destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
             interface: "org.freedesktop.DBus", method: "StartServiceByName",
             parameters: KGlobalAccelWire.tuple([g_variant_new_string(KGlobalAccelWire.busName), g_variant_new_uint32(0)])) { [weak self] reply in
            guard let self else { return }
            guard KGlobalAccelWire.hasType(reply, "(u)") else { self.fail(LinuxStrings.kdeUnavailable); return }
            self.acquireOwner(work, mode: .started)
        }
    }

    private func registerAction(_ work: Work) {
        // Track the sent mutation, even if its reply is cancelled/times out.
        // Ordered SetInactive on this same connection undoes only our presence.
        nativeCall(work, "doRegister", KGlobalAccelWire.tuple([KGlobalAccelWire.action()])) { [weak self] reply in
            guard let self else { return }
            guard KGlobalAccelWire.hasType(reply, "()") else { self.fail(LinuxStrings.kdeUnavailable); return }
            self.nativeCall(work, "getComponent", KGlobalAccelWire.tuple([g_variant_new_string(AppIdentity.linuxAppID)])) { [weak self] reply in
                guard let self else { return }
                guard KGlobalAccelWire.hasType(reply, "(o)") else { self.fail(LinuxStrings.kdeUnavailable); return }
                let value = g_variant_get_child_value(reply, 0)!
                defer { g_variant_unref(value) }
                let path = String(cString: g_variant_get_string(value, nil))
                guard path != "/", path.utf8.count <= Limits.maxPathBytes else { self.fail(LinuxStrings.kdeUnavailable); return }
                self.componentPath = path
                self.observeAction()
                self.readKeys(work) { [weak self] in self?.activateSavedKeys(work) }
            }
        }
    }

    private func readKeys(_ work: Work, done: @escaping () -> Void) {
        let revision = keysRevision
        nativeCall(work, "shortcutKeys", KGlobalAccelWire.tuple([KGlobalAccelWire.action()])) { [weak self] reply in
            guard let self else { return }
            guard let keys = KGlobalAccelWire.replyKeys(reply) else { self.fail(LinuxStrings.kdeUnavailable); return }
            if self.keysRevision == revision { self.assigned = keys }
            done()
        }
    }

    private func activateSavedKeys(_ work: Work) {
        let revision = keysRevision
        nativeCall(work, "setShortcutKeys", KGlobalAccelWire.setter(assigned, .present)) { [weak self] reply in
            guard let self else { return }
            guard let keys = KGlobalAccelWire.replyKeys(reply) else { self.fail(LinuxStrings.kdeUnavailable); return }
            if self.keysRevision == revision { self.assigned = keys }
            // Defaults do nothing until System Settings explicitly resets/assigns
            // them. Load active keys first so a fresh action stays unbound.
            self.nativeCall(work, "setShortcutKeys", KGlobalAccelWire.setter(self.suggestion, .defaultSuggestion)) { [weak self] reply in
                guard let self else { return }
                guard KGlobalAccelWire.replyKeys(reply) != nil else { self.fail(LinuxStrings.kdeUnavailable); return }
                self.checkAssignment(work)
            }
        }
    }

    private func checkAssignment(_ work: Work) {
        let revision = keysRevision
        let keys = assigned.bound.isEmpty ? suggestion.bound : assigned.bound
        checkAvailability(keys, index: 0, work: work) { [weak self] available in
            guard let self else { return }
            // A live edit wins over a read/probe already in flight, within the
            // original total deadline. Never publish stale readiness.
            guard self.keysRevision == revision else { self.checkAssignment(work); return }
            self.state = .ready
            if self.assigned.bound.isEmpty {
                self.publish(.unbound, available ? LinuxStrings.kdeAssign : LinuxStrings.kdeDefaultConflict)
            } else if !available {
                // A conflict supersedes earlier ShortcutService verification.
                self.publish(.failed, self.assigned.detail + ". " + LinuxStrings.kdeConflict)
            } else {
                self.publish(.registered, self.assigned.detail)
            }
            self.finish()
        }
    }

    private func checkAvailability(_ keys: [[Int32]], index: Int, work: Work, done: @escaping (Bool) -> Void) {
        guard index < keys.count else { done(true); return }
        nativeCall(work, "globalShortcutAvailable", KGlobalAccelWire.tuple([
            KGlobalAccelWire.sequence(keys[index]), g_variant_new_string(AppIdentity.linuxAppID)])) { [weak self] reply in
            guard let self else { return }
            guard KGlobalAccelWire.hasType(reply, "(b)") else { self.fail(LinuxStrings.kdeUnavailable); return }
            let value = g_variant_get_child_value(reply, 0)!
            defer { g_variant_unref(value) }
            guard g_variant_get_boolean(value) != 0 else { done(false); return }
            self.checkAvailability(keys, index: index + 1, work: work, done: done)
        }
    }

    private func nativeCall(_ work: Work, _ method: String, _ parameters: OpaquePointer,
                            reply: @escaping (OpaquePointer) -> Void) {
        call(work, destination: ownerName ?? "", path: KGlobalAccelWire.root,
             interface: KGlobalAccelWire.interface, method: method, parameters: parameters, reply: reply)
    }

    private func call(_ work: Work, destination: String, path: String, interface: String,
                      method: String, parameters: OpaquePointer,
                      failure: ((UnsafeMutablePointer<GError>) -> Void)? = nil,
                      reply: @escaping (OpaquePointer) -> Void) {
        g_variant_ref_sink(parameters)
        defer { g_variant_unref(parameters) }
        guard self.work === work, state != .stopped else { return }
        guard ContinuousClock.now < work.deadline else { fail(LinuxStrings.kdeTimedOut); return }
        guard let connection, !destination.isEmpty else { fail(LinuxStrings.kdeUnavailable); return }
        if method == "doRegister" { registeredOwner = ownerName }
        g_dbus_connection_call(connection, destination, path, interface, method, parameters, nil,
            G_DBUS_CALL_FLAGS_NO_AUTO_START, Self.milliseconds(work.deadline), work.cancellable,
            { source, result, data in
                guard let source, let result, let data else { return }
                let box = Unmanaged<Box>.fromOpaque(data).takeRetainedValue()
                var error: UnsafeMutablePointer<GError>?
                let reply = g_dbus_connection_call_finish(mp_dbus_connection(source), result, &error)
                defer { if let reply { g_variant_unref(reply) }; g_clear_error(&error) }
                guard let owner = box.owner, let work = box.work, owner.work === work,
                      owner.state != .stopped, owner.generation == box.generation else { return }
                guard ContinuousClock.now < work.deadline else { owner.fail(LinuxStrings.kdeTimedOut); return }
                if let error {
                    if let failure = box.failure { failure(error) } else { owner.fail(LinuxStrings.kdeUnavailable) }
                    return
                }
                guard let reply else { owner.fail(LinuxStrings.kdeUnavailable); return }
                box.reply?(reply)
            }, Unmanaged.passRetained(Box(self, work: work, failure: failure, reply: reply)).toOpaque())
    }

    private func observeAction() {
        guard let connection, let ownerName, let componentPath else { return }
        for (path, interface, member) in [(componentPath, KGlobalAccelWire.componentInterface, "globalShortcutReleased"),
                                        (KGlobalAccelWire.root, KGlobalAccelWire.interface, "yourShortcutsChanged")] {
            subscriptions.append(g_dbus_connection_signal_subscribe(connection, ownerName, interface, member, path,
                nil, G_DBUS_SIGNAL_FLAGS_NONE, { _, sender, path, _, member, parameters, data in
                    guard let sender, let path, let member, let parameters, let data else { return }
                    let box = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
                    guard let owner = box.owner, owner.state != .stopped, owner.state != .failed,
                          owner.generation == box.generation, String(cString: sender) == owner.ownerName else { return }
                    owner.signal(String(cString: member), path: String(cString: path), parameters: parameters)
                }, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox))
        }
    }

    private func signal(_ member: String, path: String, parameters: OpaquePointer) {
        if member == "globalShortcutReleased" {
            guard path == componentPath, state == .ready, currentRegistration.status == .registered,
                  KGlobalAccelWire.hasType(parameters, "(ssx)") else { return }
            let component = g_variant_get_child_value(parameters, 0)!
            let action = g_variant_get_child_value(parameters, 1)!
            let timestamp = g_variant_get_child_value(parameters, 2)!
            defer { g_variant_unref(component); g_variant_unref(action); g_variant_unref(timestamp) }
            guard String(cString: g_variant_get_string(component, nil)) == AppIdentity.linuxAppID,
                  String(cString: g_variant_get_string(action, nil)) == ActionName.toggle.rawValue else { return }
            _ = g_variant_get_int64(timestamp) // KDE uses x, not the portal's t.
            onFire?()
            return
        }
        guard member == "yourShortcutsChanged", path == KGlobalAccelWire.root,
              registeredOwner != nil, KGlobalAccelWire.hasType(parameters, "(asa(ai))") else { return }
        let action = g_variant_get_child_value(parameters, 0)!
        let keys = g_variant_get_child_value(parameters, 1)!
        defer { g_variant_unref(action); g_variant_unref(keys) }
        guard let fields = KGlobalAccelWire.strings(action), fields[0] == AppIdentity.linuxAppID,
              fields[1] == ActionName.toggle.rawValue, let assignment = KGlobalAccelWire.keys(keys) else { return }
        assigned = assignment
        keysRevision += 1
        if work == nil {
            // The signal already supplies the keys; probe only availability.
            let work = Work(budget: budget, done: nil)
            self.work = work
            state = .loading
            publish(.needsAction, LinuxStrings.kdeRegistering)
            work.timer = GTK.after(budget.timeInterval) { [weak self, weak work] in
                guard let self, let work, self.work === work else { return }
                work.timer = 0
                self.fail(LinuxStrings.kdeTimedOut)
            }
            checkAssignment(work)
        }
    }

    private static let releaseBox: GDestroyNotify = { data in
        if let data { Unmanaged<Box>.fromOpaque(data).release() }
    }

    private func observeConnection(_ connection: OpaquePointer) {
        let closed: @convention(c) (UnsafeMutableRawPointer?, gboolean, UnsafeMutablePointer<GError>?,
                                   UnsafeMutableRawPointer?) -> Void = { _, _, _, data in
            guard let data else { return }
            let owner = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().owner
            owner?.lost()
            owner?.releaseConnection()
        }
        closedSignal = mp_connect(UnsafeMutableRawPointer(connection), "closed", unsafeBitCast(closed, to: GCallback.self),
            Unmanaged.passRetained(Box(self)).toOpaque(), { data, _ in KGlobalAccelHotkeyBackend.releaseBox(data) })
        ownerSubscription = g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus",
            "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", KGlobalAccelWire.busName,
            G_DBUS_SIGNAL_FLAGS_NONE, { _, _, _, _, _, parameters, data in
                guard let data, let parameters, KGlobalAccelWire.hasType(parameters, "(sss)") else { return }
                let old = g_variant_get_child_value(parameters, 1)!
                defer { g_variant_unref(old) }
                guard !String(cString: g_variant_get_string(old, nil)).isEmpty else { return }
                Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().owner?.lost()
            }, Unmanaged.passRetained(Box(self)).toOpaque(), Self.releaseBox)
    }

    private func lost() {
        guard state != .stopped, onFire != nil else { return }
        // The old owner is dying or gone. Never call or auto-start it in cleanup.
        registeredOwner = nil
        fail(LinuxStrings.kdeLost)
    }

    private func fail(_ detail: String) {
        state = .failed
        generation += 1
        deactivate()
        removeSubscriptions()
        ownerName = nil
        componentPath = nil
        publish(.failed, detail)
        finish()
    }

    private func publish(_ status: RegistrationStatus, _ detail: String) {
        currentRegistration = HotkeyRegistration(id: currentRegistration.id, mechanism: mechanism,
            status: status, detail: detail, configuration: .systemSettings)
        onChange?()
    }

    private func finish() {
        guard let work else { return }
        self.work = nil
        if work.timer != 0 { g_source_remove(work.timer); work.timer = 0 }
        g_cancellable_cancel(work.cancellable)
        let completions = work.completions
        work.completions.removeAll()
        completions.forEach { $0() }
    }

    private func deactivate() {
        guard let connection, let registeredOwner else { return }
        self.registeredOwner = nil
        g_dbus_connection_call(connection, registeredOwner, KGlobalAccelWire.root, KGlobalAccelWire.interface,
            "setInactive", KGlobalAccelWire.tuple([KGlobalAccelWire.action()]), nil,
            G_DBUS_CALL_FLAGS_NO_AUTO_START, Self.milliseconds(ContinuousClock.now.advanced(by: budget)), nil, nil, nil)
    }

    private func removeSubscriptions() {
        if let connection { subscriptions.forEach { g_dbus_connection_signal_unsubscribe(connection, $0) } }
        subscriptions.removeAll()
    }

    private var ownership: ConnectionOwnership { busAddress == nil ? .shared : .owned }

    private func releaseConnection() {
        guard let connection else { return }
        removeSubscriptions()
        if closedSignal != 0 { g_signal_handler_disconnect(UnsafeMutableRawPointer(connection), closedSignal); closedSignal = 0 }
        if ownerSubscription != 0 { g_dbus_connection_signal_unsubscribe(connection, ownerSubscription); ownerSubscription = 0 }
        self.connection = nil
        Self.dispose(connection, ownership: ownership)
    }

    private static func dispose(_ connection: OpaquePointer, ownership: ConnectionOwnership) {
        if ownership == .owned, g_dbus_connection_is_closed(connection) == 0 {
            // Flush SetInactive before closing, without a synchronous UI wait.
            let flush = Flush()
            flush.timer = GTK.after(Limits.kglobalaccelTimeout.timeInterval) { [weak flush] in
                guard let flush else { return }
                flush.timer = 0
                g_cancellable_cancel(flush.cancellable)
            }
            g_dbus_connection_flush(connection, flush.cancellable, { source, result, data in
                guard let source, let result, let data else { return }
                let flush = Unmanaged<Flush>.fromOpaque(data).takeRetainedValue()
                if flush.timer != 0 { g_source_remove(flush.timer); flush.timer = 0 }
                let connection = mp_dbus_connection(source)!
                _ = g_dbus_connection_flush_finish(connection, result, nil)
                g_dbus_connection_close(connection, nil, nil, nil)
            }, Unmanaged.passRetained(flush).toOpaque())
        }
        g_object_unref(UnsafeMutableRawPointer(connection))
    }

    private static func milliseconds(_ deadline: ContinuousClock.Instant) -> Int32 {
        Int32(min(Double(Int32.max), max(1, ceil(ContinuousClock.now.duration(to: deadline).timeInterval * 1_000))))
    }
}
#endif
