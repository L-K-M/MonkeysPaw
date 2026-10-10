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
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.file-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var monitor: Monitor?
    private var snapshot = FileWatchTree.Snapshot()
    private var onEvent: ((FileStoreEvent) -> Void)?
    private var epoch: UInt64 = 0

    init(root: URL) throws {
        tree = try FileWatchTree(root: root)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    func start(_ onEvent: @escaping (FileStoreEvent) -> Void) throws {
        try onQueue {
            guard self.onEvent == nil else { return }
            epoch &+= 1
            self.onEvent = onEvent
            do {
                let initial = try tree.scan()
                try arm(for: initial)
                // Baseline after attachment closes the initial scan/arm gap.
                snapshot = try tree.scan()
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
            monitor?.cancel()
            monitor = nil
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
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
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
        previous?.cancel()
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
        } catch { return }
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
