#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GIO directory monitors are non-recursive. Reconcile the regular-file
/// snapshot on native events, arming every discovered directory before its
/// scan. This catches populated directory moves and missing-root attachment.
/// No debounce or prompt policy lives here. Lifecycle calls must run on the
/// owning GLib thread, whose main context delivers GFileMonitor callbacks.
final class RootedFileWatcher: FileStoreWatcher {
    private struct Monitor {
        let value: UnsafeMutablePointer<GFileMonitor>
        let signal: gulong
        let identity: String

        func cancel() {
            g_signal_handler_disconnect(value, signal)
            g_file_monitor_cancel(value)
            g_object_unref(value)
        }
    }

    private final class Callback {
        weak var owner: RootedFileWatcher?
        let epoch: UInt64

        init(_ owner: RootedFileWatcher, epoch: UInt64) {
            self.owner = owner
            self.epoch = epoch
        }
    }

    private let tree: FileWatchTree
    private let log: LogSink
    private var monitors = [String: Monitor]()
    private var pathsByIdentity = [String: String]()
    private var snapshot = FileWatchTree.Snapshot()
    private var onEvent: ((FileStoreEvent) -> Void)?
    private var epoch: UInt64 = 0
    private var hasRescanFailure = false

    init(root: URL, log: LogSink) throws {
        tree = try FileWatchTree(root: root)
        self.log = log
    }
    deinit { stop() }

    /// Idempotent while running; a second start retains the first handler.
    func start(_ onEvent: @escaping (FileStoreEvent) -> Void) throws {
        guard self.onEvent == nil else { return }
        epoch &+= 1
        self.onEvent = onEvent
        do {
            snapshot = try tree.scan(arm: arm)
            hasRescanFailure = false
            prune()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard onEvent != nil else { return }
        epoch &+= 1
        onEvent = nil
        for monitor in monitors.values { monitor.cancel() }
        monitors.removeAll()
        pathsByIdentity.removeAll()
        snapshot = FileWatchTree.Snapshot()
    }

    private func arm(_ url: URL, _ node: FileWatchTree.Node) throws {
        guard node.kind == .directory else { return }
        // GIO shares an inotify watch for aliases of the same inode. On a
        // directory rename, retire its old-path subscription before creating
        // the new one; canceling the old alias afterwards can lose the watch.
        if let oldPath = pathsByIdentity[node.identity], oldPath != url.path {
            removeMonitor(at: oldPath)
        }
        if let monitor = monitors[url.path] {
            if monitor.identity == node.identity, g_file_monitor_is_cancelled(monitor.value) == 0 { return }
            removeMonitor(at: url.path)
        }

        var error: UnsafeMutablePointer<GError>?
        guard let value = mp_monitor_directory(url.path, &error) else {
            g_clear_error(&error)
            throw FileStoreError.ioFailure
        }
        let box = Unmanaged.passRetained(Callback(self, epoch: epoch)).toOpaque()
        let changed: @convention(c) (UnsafeMutablePointer<GFileMonitor>?, OpaquePointer?, OpaquePointer?,
                                    GFileMonitorEvent, UnsafeMutableRawPointer?) -> Void = {
            _, file, other, _, data in
            guard let data else { return }
            let callback = Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue()
            callback.owner?.changed(file, other: other, epoch: callback.epoch)
        }
        let destroy: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).release()
        }
        let signal = mp_connect(value, "changed", unsafeBitCast(changed, to: GCallback.self), box, destroy)
        guard signal != 0 else {
            Unmanaged<Callback>.fromOpaque(box).release()
            g_file_monitor_cancel(value)
            g_object_unref(value)
            throw FileStoreError.ioFailure
        }
        monitors[url.path] = Monitor(value: value, signal: signal, identity: node.identity)
        pathsByIdentity[node.identity] = url.path
    }

    private func changed(_ file: OpaquePointer?, other: OpaquePointer?, epoch expectedEpoch: UInt64) {
        guard onEvent != nil, epoch == expectedEpoch,
              [file, other].contains(where: { file in
                  guard let file, let path = g_file_get_path(file) else { return false }
                  defer { g_free(path) }
                  return tree.containsOrIsAncestor(String(cString: path))
              }) else { return }

        // A raced-away directory is retried by its ancestor monitor. Keep the
        // last good baseline on I/O failure rather than inventing deletions.
        let next: FileWatchTree.Snapshot
        do {
            next = try tree.scan(arm: arm)
        } catch {
            if !hasRescanFailure {
                log.write(.error, "library rescan failed; keeping last baseline")
            }
            hasRescanFailure = true
            return
        }
        hasRescanFailure = false
        let events = FileWatchTree.changes(from: snapshot, to: next)
        snapshot = next
        prune()
        for event in events {
            guard epoch == expectedEpoch, let onEvent else { return }
            onEvent(event)
        }
    }

    private func prune() {
        for path in Array(monitors.keys) where snapshot.nodes[path]?.kind != .directory {
            removeMonitor(at: path)
        }
    }

    private func removeMonitor(at path: String) {
        guard let monitor = monitors.removeValue(forKey: path) else { return }
        pathsByIdentity.removeValue(forKey: monitor.identity)
        monitor.cancel()
    }
}
#endif
