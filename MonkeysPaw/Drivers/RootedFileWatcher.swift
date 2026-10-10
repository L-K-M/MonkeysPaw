import CoreServices
import Foundation
import MonkeysPawCore

/// A recursive FSEvents stream avoids one open descriptor per file. Native
/// notifications trigger a regular-file snapshot diff, including in-place
/// edits and directory moves. Zero stream latency leaves debounce to Core.
/// WatchRoot covers ancestor replacement; every batch is fully rescanned,
/// including dropped-event batches. State belongs to the serial queue.
final class RootedFileWatcher: FileStoreWatcher {
    private struct Monitor {
        let stream: FSEventStreamRef
        let path: String
        let identity: String
        let token: UUID

        func cancel() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private final class Callback {
        weak var owner: RootedFileWatcher?
        let epoch: UInt64
        let token: UUID

        init(_ owner: RootedFileWatcher, epoch: UInt64, token: UUID) {
            self.owner = owner
            self.epoch = epoch
            self.token = token
        }
    }

    private let tree: FileWatchTree
    private let log: LogSink
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.file-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var monitor: Monitor?
    private var snapshot = FileWatchTree.Snapshot()
    private var onEvent: (@Sendable (FileStoreEvent) -> Void)?
    private var epoch: UInt64 = 0
    private var hasRescanFailure = false

    init(root: URL, log: LogSink) throws {
        tree = try FileWatchTree(root: root)
        self.log = log
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    /// Idempotent while running; a second start retains the first handler.
    func start(_ onEvent: @escaping @Sendable (FileStoreEvent) -> Void) throws {
        try onQueue {
            guard self.onEvent == nil else { return }
            epoch &+= 1
            self.onEvent = onEvent
            do {
                let initial = try tree.scan()
                try arm(for: initial)
                // Baseline after attachment closes the initial scan/arm gap.
                // Changes between start() and this baseline are deliberately folded in.
                snapshot = try tree.scan()
                hasRescanFailure = false
            } catch {
                stop()
                throw error
            }
        }
    }

    func stop() {
        onQueue {
            guard onEvent != nil else { return }
            epoch &+= 1
            onEvent = nil
            let retiring = monitor
            monitor = nil
            // A consumer can stop inside this stream's callback. Retire it
            // after the callback returns; epochs already reject stale events.
            queue.async { retiring?.cancel() }
            snapshot = FileWatchTree.Snapshot()
        }
    }

    @discardableResult
    private func arm(for snapshot: FileWatchTree.Snapshot) throws -> Bool {
        var directory = tree.root
        while snapshot.nodes[directory.path]?.kind != .directory {
            directory.deleteLastPathComponent()
        }
        guard let node = snapshot.nodes[directory.path] else { throw FileStoreError.ioFailure }
        if monitor?.path == directory.path, monitor?.identity == node.identity { return false }

        let token = UUID()
        let callback = Callback(self, epoch: epoch, token: token)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Callback>.fromOpaque(info).release()
            }, copyDescription: nil)
        let changed: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            callback.owner?.changed(epoch: callback.epoch, token: callback.token)
        }
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        // Ancestors need directory-level events only until the root appears.
        if directory.path == tree.root.path {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, changed, &context,
            [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags) else {
            throw FileStoreError.ioFailure
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FileStoreError.ioFailure
        }
        let previous = monitor
        monitor = Monitor(stream: stream, path: directory.path, identity: node.identity, token: token)
        // arm can run inside the retired stream's callback. Defer teardown
        // on the serial queue until it returns; tokens reject stale events.
        queue.async { previous?.cancel() }
        return true
    }

    private func changed(epoch expectedEpoch: UInt64, token: UUID) {
        guard onEvent != nil, epoch == expectedEpoch, monitor?.token == token else { return }
        // Keep the last good baseline on transient I/O failure. The current
        // stream remains armed so a later native event can retry attachment.
        var next: FileWatchTree.Snapshot
        do {
            next = try tree.scan()
            if try arm(for: next) { next = try tree.scan() }
        } catch {
            if !hasRescanFailure {
                log.write(.error, "library rescan failed; keeping last baseline: \(String(describing: error))")
            }
            hasRescanFailure = true
            return
        }
        hasRescanFailure = false
        let events = FileWatchTree.changes(from: snapshot, to: next)
        snapshot = next
        for event in events {
            guard epoch == expectedEpoch, let onEvent else { return }
            onEvent(event)
        }
    }

    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }
}
