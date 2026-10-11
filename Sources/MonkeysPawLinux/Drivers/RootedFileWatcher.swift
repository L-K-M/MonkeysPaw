#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GIO directory monitors are non-recursive. Reconcile the regular-file
/// snapshot after queued native events quiesce, arming every discovered
/// directory before its scan. This catches populated directory moves and
/// missing-root attachment.
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
    private var monitors = [Data: Monitor]()
    private var pathsByIdentity = [String: Data]()
    private var snapshot = FileWatchTree.Snapshot()
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    private var epoch: UInt64 = 0
    private var hasRescanFailure = false
    private var rootUnavailable = false
    private var needsRescan = false
    private var rescanSource: guint = 0

    init(root: URL, log: LogSink) throws {
        tree = try FileWatchTree(root: root)
        self.log = log
    }
    deinit { stop() }

    /// Idempotent while running; a second start retains the first handler.
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {
        guard self.onEvent == nil else { return }
        epoch &+= 1
        self.onEvent = onEvent
        do {
            snapshot = try tree.scan(arm: arm)
            if let error = snapshot.rootError, error != .notFound { throw error }
            rootUnavailable = snapshot.rootError != nil
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
        if rescanSource != 0 {
            g_source_remove(rescanSource)
            rescanSource = 0
        }
        needsRescan = false
        rootUnavailable = false
        hasRescanFailure = false
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
        if let oldPath = pathsByIdentity[node.identity], oldPath != Data(url.path.utf8) {
            removeMonitor(at: oldPath)
        }
        if let monitor = monitors[Data(url.path.utf8)] {
            if monitor.identity == node.identity, g_file_monitor_is_cancelled(monitor.value) == 0 { return }
            removeMonitor(at: Data(url.path.utf8))
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
        monitors[Data(url.path.utf8)] = Monitor(value: value, signal: signal, identity: node.identity)
        pathsByIdentity[node.identity] = Data(url.path.utf8)
    }

    private func changed(_ file: OpaquePointer?, other: OpaquePointer?, epoch expectedEpoch: UInt64) {
        guard onEvent != nil, epoch == expectedEpoch,
              [file, other].contains(where: { file in
                  guard let file, let path = g_file_get_path(file) else { return false }
                  defer { g_free(path) }
                  return tree.containsOrIsAncestor(String(cString: path))
              }) else { return }

        needsRescan = true
        guard rescanSource == 0 else { return }
        let box = Unmanaged.passRetained(Callback(self, epoch: expectedEpoch)).toOpaque()
        let rescan: GSourceFunc = { data in
            guard let data else { return 0 }
            let callback = Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue()
            callback.owner?.performRescan(epoch: callback.epoch)
            return 0 // G_SOURCE_REMOVE; the destroy notify releases the box.
        }
        let destroy: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).release()
        }
        // Idle priority lets queued monitor events drain before one scan,
        // without adding a fixed delay or moving work off the owning thread.
        rescanSource = mp_rescan_idle(rescan, box, destroy)
    }

    private func performRescan(epoch expectedEpoch: UInt64) {
        guard epoch == expectedEpoch, onEvent != nil else { return }
        // Clear before delivery: the consumer may stop or restart the watcher.
        rescanSource = 0
        guard needsRescan else { return }
        needsRescan = false

        // GLib 2.80.0 inotify-path.c:ip_event_callback discards IN_Q_OVERFLOW,
        // so GFileMonitor exposes no overflow flag. Full scans reconcile all
        // delivered batches, including changes whose individual events were
        // dropped; an overflow cannot produce a separate driver warning.
        let next: FileWatchTree.Snapshot
        do {
            next = try tree.scan(arm: arm)
        } catch {
            warnAboutRescan(error as? FileStoreError ?? .ioFailure)
            return
        }
        if let error = next.rootError {
            if error == .ioFailure { warnAboutRescan(error) }
            guard !rootUnavailable else { return }
            rootUnavailable = true
            onEvent?(.rootUnavailable(error))
            return
        }
        rootUnavailable = false
        hasRescanFailure = false
        let events = FileWatchTree.changes(from: snapshot, to: next)
        snapshot = next
        prune()
        for event in events {
            guard epoch == expectedEpoch, let onEvent else { return }
            onEvent(.file(event))
        }
    }

    private func warnAboutRescan(_ error: FileStoreError) {
        if !hasRescanFailure {
            log.write(.warning, "library rescan failed; keeping last baseline: \(error.rawValue)")
        }
        hasRescanFailure = true
    }

    private func prune() {
        for path in Array(monitors.keys) where snapshot.nodes[path]?.kind != .directory {
            removeMonitor(at: path)
        }
    }

    private func removeMonitor(at path: Data) {
        guard let monitor = monitors.removeValue(forKey: path) else { return }
        pathsByIdentity.removeValue(forKey: monitor.identity)
        monitor.cancel()
    }
}
#endif
