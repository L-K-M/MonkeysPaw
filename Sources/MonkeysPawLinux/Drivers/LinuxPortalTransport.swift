#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

enum PortalInterface: String {
    case globalShortcuts = "org.freedesktop.portal.GlobalShortcuts"
    case remoteDesktop = "org.freedesktop.portal.RemoteDesktop"
}

enum PortalOption {
    case string(String)
    case uint32(UInt32)
}

struct PortalShortcut: Equatable {
    let id: String
    let properties: [String: String]
}

/// The argument shapes used by the two portals, before the options vardict.
/// Method names and session policy belong to the session drivers.
enum PortalArgument {
    case objectPath(String)
    case string(String)
    case shortcuts([PortalShortcut])
}

struct PortalResponse: Equatable {
    let sessionHandle: String?
    let devices: UInt32?
    let restoreToken: PortalRestoreToken?
    let shortcuts: [PortalShortcut]?
}

enum PortalRequestOutcome: Equatable {
    case success(PortalResponse)
    case cancelled
    // Request code 2 means an unsuccessful interaction, including denial.
    case denied
    case timedOut
    case unavailable
    case methodError
    case busFailure
    case malformedResponse
    case invalidArguments
    case tornDown
}

/// All entry points and callbacks run on the default GLib loop's thread.
/// No native values escape this boundary. Only LinuxEnvironment will construct
/// the production instance when sessions are wired in the second M1c PR.
final class LinuxPortalTransport {
    private enum ConnectionOwnership { case owned, shared }
    private enum RequestEnd { case response, aborted }
    private static let busName = "org.freedesktop.portal.Desktop"
    private static let desktopPath = "/org/freedesktop/portal/desktop"
    private static let requestInterface = "org.freedesktop.portal.Request"
    private static let requestPrefix = desktopPath + "/request/"

    private final class Pending {
        let id = UUID()
        let token = "monkeyspaw_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let interface: PortalInterface
        let method: String
        let arguments: [PortalArgument]
        let options: [String: PortalOption]
        let deadline: ContinuousClock.Instant
        let cancellable = g_cancellable_new()!
        var completion: ((PortalRequestOutcome) -> Void)?
        var timer: guint = 0
        var subscription: guint = 0
        var expectedHandle: String?
        var actualHandle: String?
        var earlyResponses: [String: PortalRequestOutcome] = [:]

        init(interface: PortalInterface, method: String, arguments: [PortalArgument],
             options: [String: PortalOption], deadline: ContinuousClock.Instant,
             completion: @escaping (PortalRequestOutcome) -> Void) {
            self.interface = interface
            self.method = method
            self.arguments = arguments
            self.options = options
            self.deadline = deadline
            self.completion = completion
        }

        deinit { g_object_unref(cancellable) }
    }

    private final class OwnerBox {
        weak var owner: LinuxPortalTransport?
        init(_ owner: LinuxPortalTransport) { self.owner = owner }
    }

    private final class RequestBox {
        weak var owner: LinuxPortalTransport?
        let pending: Pending
        init(_ owner: LinuxPortalTransport, _ pending: Pending) {
            self.owner = owner
            self.pending = pending
        }
    }

    private final class ConnectionAttempt {
        weak var owner: LinuxPortalTransport?
        let address: String?
        let cancellable = g_cancellable_new()!
        init(_ owner: LinuxPortalTransport, address: String?) {
            self.owner = owner
            self.address = address
        }
        deinit { g_object_unref(cancellable) }
    }

    private final class Flush {
        let cancellable = g_cancellable_new()!
        var timer: guint = 0
        deinit { g_object_unref(cancellable) }
    }

    private let busAddress: String?
    private var connection: OpaquePointer?
    private var attempt: ConnectionAttempt?
    private var closedSignal: gulong = 0
    private var ownerSubscription: guint = 0
    private var pending: [UUID: Pending] = [:]
    private var isShutDown = false

    init(busAddress: String? = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]) {
        self.busAddress = busAddress
    }

    deinit { shutdown() }

    /// One caller deadline covers connection, method reply and Response.
    /// The returned id allows cancellation without exposing a native request.
    @discardableResult
    func request(interface: PortalInterface, method: String,
                 arguments: [PortalArgument] = [], options: [String: PortalOption] = [:],
                 deadline: ContinuousClock.Instant,
                 completion: @escaping (PortalRequestOutcome) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let work = Pending(interface: interface, method: method, arguments: arguments,
                           options: options, deadline: deadline, completion: completion)
        pending[work.id] = work
        guard !isShutDown else { finish(work, .tornDown); return work.id }
        guard PortalWire.validString(method), g_dbus_is_member_name(method) != 0,
              options["handle_token"] == nil, PortalWire.valid(arguments, options) else {
            finish(work, .invalidArguments)
            return work.id
        }
        guard ContinuousClock.now < deadline else { finish(work, .timedOut); return work.id }

        work.timer = GTK.after(Self.remainingSeconds(deadline)) { [weak self, weak work] in
            guard let self, let work else { return }
            work.timer = 0
            self.finish(work, .timedOut)
        }
        if let connection { start(work, on: connection) } else { connect() }
        return work.id
    }

    func cancel(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard let work = pending[id] else { return }
        finish(work, .cancelled)
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        guard !isShutDown else { return }
        isShutDown = true
        for work in Array(pending.values) { finish(work, .tornDown) }
        releaseConnection()
    }

    private func connect() {
        guard attempt == nil else { return }
        let attempt = ConnectionAttempt(self, address: busAddress)
        self.attempt = attempt
        let data = Unmanaged.passRetained(attempt).toOpaque()
        let callback: GAsyncReadyCallback = { _, result, data in
            guard let result, let data else { return }
            let attempt = Unmanaged<ConnectionAttempt>.fromOpaque(data).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            let connection = attempt.address == nil
                ? g_bus_get_finish(result, &error)
                : g_dbus_connection_new_for_address_finish(result, &error)
            defer { g_clear_error(&error) }

            guard let owner = attempt.owner, owner.attempt === attempt else {
                if let connection {
                    LinuxPortalTransport.dispose(connection,
                        ownership: attempt.address == nil ? .shared : .owned)
                }
                return
            }
            owner.attempt = nil
            guard let connection else {
                for work in Array(owner.pending.values) { owner.finish(work, .busFailure) }
                return
            }
            owner.connection = connection
            g_dbus_connection_set_exit_on_close(connection, 0)
            owner.observeConnection(connection)
            for work in Array(owner.pending.values) { owner.start(work, on: connection) }
        }
        if let busAddress {
            let flags = GDBusConnectionFlags(rawValue:
                G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue |
                G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
            g_dbus_connection_new_for_address(busAddress, flags, nil, attempt.cancellable, callback, data)
        } else {
            // GIO resolves the session bus asynchronously when no address was
            // exported. This connection is shared with GTK and must not be closed.
            g_bus_get(G_BUS_TYPE_SESSION, attempt.cancellable, callback, data)
        }
    }

    private func start(_ work: Pending, on connection: OpaquePointer) {
        guard work.completion != nil, work.expectedHandle == nil else { return }
        guard ContinuousClock.now < work.deadline else { finish(work, .timedOut); return }
        guard let rawSender = g_dbus_connection_get_unique_name(connection) else {
            finish(work, .busFailure)
            return
        }
        let sender = String(cString: rawSender).dropFirst().replacingOccurrences(of: ".", with: "_")
        work.expectedHandle = Self.requestPrefix + sender + "/" + work.token

        // Subscribe before the call. A namespace subscription also captures an
        // older portal's different handle if it emits Response before replying.
        let signalData = Unmanaged.passRetained(RequestBox(self, work)).toOpaque()
        work.subscription = g_dbus_connection_signal_subscribe(connection, Self.busName,
            Self.requestInterface, "Response", nil, nil, G_DBUS_SIGNAL_FLAGS_NONE,
            { _, _, path, _, _, parameters, data in
                guard let path, let parameters, let data else { return }
                let box = Unmanaged<RequestBox>.fromOpaque(data).takeUnretainedValue()
                box.owner?.response(box.pending, path: String(cString: path), parameters: parameters)
            }, signalData, { data in
                guard let data else { return }
                Unmanaged<RequestBox>.fromOpaque(data).release()
            })

        let callData = Unmanaged.passRetained(RequestBox(self, work)).toOpaque()
        g_dbus_connection_call(connection, Self.busName, Self.desktopPath, work.interface.rawValue,
            work.method, PortalWire.parameters(work.arguments, work.options, token: work.token),
            nil, G_DBUS_CALL_FLAGS_NONE, Self.remainingMilliseconds(work.deadline), work.cancellable,
            { source, result, data in
                guard let source, let result, let data else { return }
                let box = Unmanaged<RequestBox>.fromOpaque(data).takeRetainedValue()
                let connection = mp_dbus_connection(source)!
                var error: UnsafeMutablePointer<GError>?
                let reply = g_dbus_connection_call_finish(connection, result, &error)
                defer {
                    if let reply { g_variant_unref(reply) }
                    g_clear_error(&error)
                }
                let handle = reply.flatMap(PortalWire.replyHandle)
                guard box.pending.completion != nil, let owner = box.owner else {
                    // Cancellation may win while a reply is already queued.
                    if let handle, LinuxPortalTransport.validRequestPath(handle) {
                        LinuxPortalTransport.closeRequest(handle, on: connection)
                    }
                    return
                }
                if let error {
                    owner.finish(box.pending, LinuxPortalTransport.failure(error))
                    return
                }
                guard let handle, LinuxPortalTransport.validRequestPath(handle) else {
                    owner.finish(box.pending, .malformedResponse)
                    return
                }
                box.pending.actualHandle = handle
                let buffered = box.pending.earlyResponses[handle]
                box.pending.earlyResponses.removeAll()
                if ContinuousClock.now >= box.pending.deadline {
                    owner.finish(box.pending, .timedOut)
                } else if let buffered {
                    owner.finish(box.pending, buffered, end: .response)
                }
            }, callData)
    }

    private func response(_ work: Pending, path: String, parameters: OpaquePointer) {
        guard work.completion != nil, Self.validRequestPath(path) else { return }
        guard ContinuousClock.now < work.deadline else { finish(work, .timedOut); return }
        if let actual = work.actualHandle {
            guard path == actual else { return }
            finish(work, PortalWire.response(parameters), end: .response)
            return
        }
        guard work.earlyResponses[path] == nil else { return }
        if path == work.expectedHandle || work.earlyResponses.count < Limits.portalEarlyResponseCap {
            work.earlyResponses[path] = PortalWire.response(parameters)
        }
    }

    private func finish(_ work: Pending, _ outcome: PortalRequestOutcome, end: RequestEnd = .aborted) {
        guard let completion = work.completion else { return }
        work.completion = nil
        pending.removeValue(forKey: work.id)
        if work.timer != 0 { g_source_remove(work.timer); work.timer = 0 }
        if let connection {
            if work.subscription != 0 {
                g_dbus_connection_signal_unsubscribe(connection, work.subscription)
                work.subscription = 0
            }
            if end == .aborted || outcome == .malformedResponse {
                if let handle = work.actualHandle ?? work.expectedHandle {
                    Self.closeRequest(handle, on: connection)
                }
            }
        }
        work.earlyResponses.removeAll()
        // Cancelling GIO's method wait loses a legacy portal's reply handle.
        // Keep that wait within the original deadline solely to close its actual
        // request; the caller's closure and signal/timer are already released.
        if outcome != .cancelled || end == .response {
            g_cancellable_cancel(work.cancellable)
        }
        if pending.isEmpty, let attempt {
            self.attempt = nil
            g_cancellable_cancel(attempt.cancellable)
        }
        completion(outcome)
    }

    private func observeConnection(_ connection: OpaquePointer) {
        let closed: @convention(c) (UnsafeMutableRawPointer?, gboolean,
            UnsafeMutablePointer<GError>?, UnsafeMutableRawPointer?) -> Void = { _, _, _, data in
                guard let data else { return }
                let box = Unmanaged<OwnerBox>.fromOpaque(data).takeUnretainedValue()
                guard let owner = box.owner else { return }
                owner.releaseConnection()
                for work in Array(owner.pending.values) { owner.finish(work, .busFailure) }
            }
        closedSignal = mp_connect(UnsafeMutableRawPointer(connection), "closed",
            unsafeBitCast(closed, to: GCallback.self), Unmanaged.passRetained(OwnerBox(self)).toOpaque(),
            { data, _ in
                guard let data else { return }
                Unmanaged<OwnerBox>.fromOpaque(data).release()
            })
        ownerSubscription = g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus",
            "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", Self.busName,
            G_DBUS_SIGNAL_FLAGS_NONE, { _, _, _, _, _, parameters, data in
                guard let data, let parameters, PortalWire.hasType(parameters, "(sss)") else { return }
                let newOwner = g_variant_get_child_value(parameters, 2)!
                defer { g_variant_unref(newOwner) }
                guard PortalWire.string(newOwner)?.isEmpty == true else { return }
                let box = Unmanaged<OwnerBox>.fromOpaque(data).takeUnretainedValue()
                guard let owner = box.owner else { return }
                for work in Array(owner.pending.values) { owner.finish(work, .unavailable) }
            }, Unmanaged.passRetained(OwnerBox(self)).toOpaque(), { data in
                guard let data else { return }
                Unmanaged<OwnerBox>.fromOpaque(data).release()
            })
    }

    private func releaseConnection() {
        guard let connection else { return }
        if closedSignal != 0 {
            g_signal_handler_disconnect(UnsafeMutableRawPointer(connection), closedSignal)
            closedSignal = 0
        }
        if ownerSubscription != 0 {
            g_dbus_connection_signal_unsubscribe(connection, ownerSubscription)
            ownerSubscription = 0
        }
        for work in pending.values where work.subscription != 0 {
            g_dbus_connection_signal_unsubscribe(connection, work.subscription)
            work.subscription = 0
        }
        self.connection = nil
        Self.dispose(connection, ownership: busAddress == nil ? .shared : .owned)
    }

    private static func dispose(_ connection: OpaquePointer, ownership: ConnectionOwnership) {
        if ownership == .owned, g_dbus_connection_is_closed(connection) == 0 {
            // Flush queued Close messages before closing our dedicated connection.
            // A stalled bus must not retain this cleanup indefinitely.
            let flush = Flush()
            flush.timer = GTK.after(Limits.portalCallTimeout.timeInterval) { [weak flush] in
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

    private static func closeRequest(_ path: String, on connection: OpaquePointer) {
        g_dbus_connection_call(connection, busName, path, requestInterface, "Close", nil, nil,
            G_DBUS_CALL_FLAGS_NO_AUTO_START, remainingMilliseconds(ContinuousClock.now.advanced(by:
                Limits.portalCallTimeout)), nil, nil, nil)
    }

    private static func validRequestPath(_ path: String) -> Bool {
        PortalWire.validString(path) && path.hasPrefix(requestPrefix)
            && path.utf8.count <= Limits.maxPathBytes
            && path.count > requestPrefix.count && g_variant_is_object_path(path) != 0
    }

    private static func remainingSeconds(_ deadline: ContinuousClock.Instant) -> Double {
        // Round upward so the GLib millisecond timer never expires early.
        return ceil(max(0, ContinuousClock.now.duration(to: deadline).timeInterval) * 1_000) / 1_000
    }

    private static func remainingMilliseconds(_ deadline: ContinuousClock.Instant) -> Int32 {
        Int32(min(Double(Int32.max), max(1, remainingSeconds(deadline) * 1_000)))
    }

    private static func failure(_ error: UnsafeMutablePointer<GError>) -> PortalRequestOutcome {
        if g_error_matches(error, g_io_error_quark(), Int32(G_IO_ERROR_TIMED_OUT.rawValue)) != 0
            || g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_NO_REPLY.rawValue)) != 0
            || g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_TIMEOUT.rawValue)) != 0 {
            return .timedOut
        }
        if g_error_matches(error, g_io_error_quark(), Int32(G_IO_ERROR_CLOSED.rawValue)) != 0
            || g_error_matches(error, g_io_error_quark(), Int32(G_IO_ERROR_CONNECTION_CLOSED.rawValue)) != 0
            || g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_DISCONNECTED.rawValue)) != 0 {
            return .busFailure
        }
        if g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_SERVICE_UNKNOWN.rawValue)) != 0
            || g_error_matches(error, g_dbus_error_quark(), Int32(G_DBUS_ERROR_NAME_HAS_NO_OWNER.rawValue)) != 0 {
            return .unavailable
        }
        return .methodError
    }
}

/// Fixed portal wire shapes only. GVariant references never reach a consumer.
private enum PortalWire {
    static func hasType(_ value: OpaquePointer, _ type: String) -> Bool {
        String(cString: g_variant_get_type_string(value)) == type
    }

    static func validString(_ value: String) -> Bool { !value.utf8.contains(0) }

    static func valid(_ arguments: [PortalArgument], _ options: [String: PortalOption]) -> Bool {
        for argument in arguments {
            switch argument {
            case .objectPath(let path):
                guard validString(path), g_variant_is_object_path(path) != 0 else { return false }
            case .string(let value):
                guard validString(value) else { return false }
            case .shortcuts(let shortcuts):
                guard shortcuts.allSatisfy({ validString($0.id) && $0.properties.allSatisfy {
                    validString($0.key) && validString($0.value)
                } }) else { return false }
            }
        }
        return options.allSatisfy { key, value in
            guard validString(key) else { return false }
            if case .string(let string) = value { return validString(string) }
            return true
        }
    }

    static func parameters(_ arguments: [PortalArgument], _ options: [String: PortalOption],
                           token: String) -> OpaquePointer {
        var children: [OpaquePointer?] = arguments.map { argument in
            switch argument {
            case .objectPath(let path): return g_variant_new_object_path(path)
            case .string(let string): return g_variant_new_string(string)
            case .shortcuts(let shortcuts):
                let builder = builder("a(sa{sv})")
                for shortcut in shortcuts {
                    let properties = shortcut.properties.mapValues { PortalOption.string($0) }
                    g_variant_builder_add_value(builder, tuple([
                        g_variant_new_string(shortcut.id), dictionary(properties)]))
                }
                defer { g_variant_builder_unref(builder) }
                return g_variant_builder_end(builder)
            }
        }
        var options = options
        options["handle_token"] = .string(token)
        children.append(dictionary(options))
        return tuple(children)
    }

    private static func builder(_ signature: String) -> UnsafeMutablePointer<GVariantBuilder> {
        let type = g_variant_type_new(signature)!
        defer { g_variant_type_free(type) }
        return g_variant_builder_new(type)!
    }

    private static func tuple(_ children: [OpaquePointer?]) -> OpaquePointer {
        children.withUnsafeBufferPointer { g_variant_new_tuple($0.baseAddress, UInt($0.count))! }
    }

    private static func dictionary(_ options: [String: PortalOption]) -> OpaquePointer {
        let builder = builder("a{sv}")
        defer { g_variant_builder_unref(builder) }
        for (key, option) in options {
            let value: OpaquePointer?
            switch option {
            case .string(let string): value = g_variant_new_string(string)
            case .uint32(let number): value = g_variant_new_uint32(number)
            }
            g_variant_builder_add_value(builder, g_variant_new_dict_entry(
                g_variant_new_string(key), g_variant_new_variant(value)))
        }
        return g_variant_builder_end(builder)!
    }

    static func string(_ value: OpaquePointer) -> String? {
        guard hasType(value, "s") || hasType(value, "o") else { return nil }
        return String(cString: g_variant_get_string(value, nil))
    }

    static func replyHandle(_ value: OpaquePointer) -> String? {
        guard hasType(value, "(o)"), g_variant_get_size(value) <= Limits.maxPathBytes + 1 else { return nil }
        let child = g_variant_get_child_value(value, 0)!
        defer { g_variant_unref(child) }
        return string(child)
    }

    static func response(_ value: OpaquePointer) -> PortalRequestOutcome {
        guard hasType(value, "(ua{sv})"), g_variant_get_size(value) <= Limits.portalResponseMaxBytes else {
            return .malformedResponse
        }
        let code = g_variant_get_child_value(value, 0)!
        let results = g_variant_get_child_value(value, 1)!
        defer { g_variant_unref(code); g_variant_unref(results) }
        switch g_variant_get_uint32(code) {
        case 1: return .cancelled
        case 2: return .denied
        case 0: break
        default: return .malformedResponse
        }

        var session: String?
        var devices: UInt32?
        var token: PortalRestoreToken?
        var shortcuts: [PortalShortcut]?
        var seen = Set<String>()
        for index in 0..<g_variant_n_children(results) {
            let entry = g_variant_get_child_value(results, index)!
            let keyValue = g_variant_get_child_value(entry, 0)!
            let wrapper = g_variant_get_child_value(entry, 1)!
            let child = g_variant_get_variant(wrapper)!
            defer {
                g_variant_unref(entry); g_variant_unref(keyValue)
                g_variant_unref(wrapper); g_variant_unref(child)
            }
            let key = string(keyValue)!
            guard seen.insert(key).inserted else { return .malformedResponse }
            switch key {
            case "session_handle":
                // The portal specification preserves this historical string,
                // despite it representing an object path (not a variant of o).
                guard hasType(child, "s"), let path = string(child),
                      g_variant_is_object_path(path) != 0 else { return .malformedResponse }
                session = path
            case "devices":
                guard hasType(child, "u") else { return .malformedResponse }
                devices = g_variant_get_uint32(child)
            case "restore_token":
                guard hasType(child, "s"), let text = string(child),
                      let restore = PortalRestoreToken(text) else { return .malformedResponse }
                token = restore
            case "shortcuts":
                guard let decoded = decodeShortcuts(child) else { return .malformedResponse }
                shortcuts = decoded
            default: break // Extra result fields are defined by other portal features.
            }
        }
        return .success(PortalResponse(sessionHandle: session, devices: devices,
                                       restoreToken: token, shortcuts: shortcuts))
    }

    private static func decodeShortcuts(_ value: OpaquePointer) -> [PortalShortcut]? {
        guard hasType(value, "a(sa{sv})") else { return nil }
        var shortcuts: [PortalShortcut] = []
        for index in 0..<g_variant_n_children(value) {
            let entry = g_variant_get_child_value(value, index)!
            let id = g_variant_get_child_value(entry, 0)!
            let dictionary = g_variant_get_child_value(entry, 1)!
            defer { g_variant_unref(entry); g_variant_unref(id); g_variant_unref(dictionary) }
            var properties: [String: String] = [:]
            for index in 0..<g_variant_n_children(dictionary) {
                let pair = g_variant_get_child_value(dictionary, index)!
                let key = g_variant_get_child_value(pair, 0)!
                let wrapper = g_variant_get_child_value(pair, 1)!
                let child = g_variant_get_variant(wrapper)!
                defer {
                    g_variant_unref(pair); g_variant_unref(key)
                    g_variant_unref(wrapper); g_variant_unref(child)
                }
                let name = string(key)!
                if name == "description" || name == "trigger_description" {
                    guard hasType(child, "s"), properties[name] == nil else { return nil }
                    properties[name] = string(child)
                }
            }
            shortcuts.append(PortalShortcut(id: string(id)!, properties: properties))
        }
        return shortcuts
    }
}
#endif
