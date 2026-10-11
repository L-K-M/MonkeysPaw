import Foundation

/// Coalesces raw filesystem events without reading files or clocks. Driver
/// and scheduler callbacks may arrive on different threads. Lifecycle and
/// delivery are serialized; a callback can stop or restart this service.
/// Locks protect internal state; lifecycle calls must still honor the driver's
/// owning-thread requirement.
public final class LibraryWatcher: @unchecked Sendable {
    private struct PendingChange {
        let originallyPresent: Bool
        var present: Bool

        init(_ kind: FileStoreEvent.Kind) {
            originallyPresent = kind != .created
            present = kind != .deleted
        }

        var kind: FileStoreEvent.Kind? {
            if !present { return originallyPresent ? .deleted : nil }
            return originallyPresent ? .modified : .created
        }
    }

    private let watcher: FileStoreWatcher
    private let scheduler: Scheduler
    private let lifecycleLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private var onChange: (@Sendable (LibraryWatchUpdate) -> Void)?
    private var pending = [RelativePath: PendingChange]()
    private var ready = [LibraryWatchUpdate]()
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0

    public init(watcher: FileStoreWatcher, scheduler: Scheduler) {
        self.watcher = watcher
        self.scheduler = scheduler
    }

    /// Best-effort cleanup runs on an arbitrary thread. Callers must call stop()
    /// on the driver's owning thread before releasing this service. Linux stop
    /// assumes its owning GLib thread; macOS marshals via queue.sync and is
    /// callable from any thread.
    deinit { watcher.stop() }

    /// Idempotent while running. All delivery uses the scheduler's thread.
    /// Health schedules zero-delay delivery, flushing earlier pending files
    /// first. No quiet window delays health, and later files cannot overtake it.
    public func start(_ onChange: @escaping @Sendable (LibraryWatchUpdate) -> Void) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateLock.lock()
        guard self.onChange == nil else { stateLock.unlock(); return }
        epoch &+= 1
        let currentEpoch = epoch
        self.onChange = onChange
        stateLock.unlock()

        do {
            try watcher.start { [weak self] event in self?.receive(event, epoch: currentEpoch) }
        } catch {
            clearState()
            watcher.stop()
            throw error
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard clearState() else { return }
        // Never hold stateLock while calling the driver: stop may wait for a
        // driver callback that is entering receive on its own serial queue.
        watcher.stop()
    }

    @discardableResult
    private func clearState() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        let wasRunning = onChange != nil
        epoch &+= 1
        generation &+= 1
        onChange = nil
        pending.removeAll()
        ready.removeAll()
        return wasRunning
    }

    private func receive(_ update: FileStoreWatchEvent, epoch expectedEpoch: UInt64) {
        if case .rootUnavailable(let error) = update {
            stateLock.lock()
            guard onChange != nil, epoch == expectedEpoch else { stateLock.unlock(); return }
            let changes = drainPending()
            if !changes.isEmpty { ready.append(.changes(changes)) }
            ready.append(.rootUnavailable(error))
            generation &+= 1
            stateLock.unlock()

            // Marshal health with zero delay rather than delivering on the raw
            // driver's queue. Holding lifecycleLock there could deadlock stop(),
            // which may wait for that driver queue while owning lifecycleLock.
            scheduler.after(.zero) { [weak self] in self?.emitReady(epoch: expectedEpoch) }
            return
        }
        guard case .file(let event) = update else { return }
        stateLock.lock()
        guard onChange != nil, epoch == expectedEpoch,
              (try? FileStorePath.validate(event.relativePath)) != nil,
              LibraryPath.isPrompt(event.relativePath) else {
            stateLock.unlock()
            return
        }

        let path = RelativePath(event.relativePath)
        if var change = pending[path] {
            change.present = event.kind != .deleted
            pending[path] = change
        } else {
            pending[path] = PendingChange(event.kind)
        }
        generation &+= 1
        let expectedGeneration = generation
        stateLock.unlock()

        // after is one-shot and cannot be canceled. Every prompt-path event
        // restarts the quiet window; earlier callbacks become harmless no-ops.
        scheduler.after(Limits.watchDebounce) { [weak self] in
            self?.emit(epoch: expectedEpoch, generation: expectedGeneration)
        }
    }

    private func emit(epoch expectedEpoch: UInt64, generation expectedGeneration: UInt64) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stateLock.lock()
        guard epoch == expectedEpoch, generation == expectedGeneration, onChange != nil else {
            stateLock.unlock()
            return
        }

        var updates = ready
        ready.removeAll()
        let changes = drainPending()
        if !changes.isEmpty { updates.append(.changes(changes)) }
        stateLock.unlock()
        deliver(updates, epoch: expectedEpoch)
    }

    private func emitReady(epoch expectedEpoch: UInt64) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        guard epoch == expectedEpoch, onChange != nil else { stateLock.unlock(); return }
        let updates = ready
        ready.removeAll()
        stateLock.unlock()
        deliver(updates, epoch: expectedEpoch)
    }

    /// Called under lifecycleLock, allowing consumer lifecycle re-entry. Check
    /// the epoch before each update so a stop/restart during flush drops health
    /// and any remaining output belonging to the previous run.
    private func deliver(_ updates: [LibraryWatchUpdate], epoch expectedEpoch: UInt64) {
        for update in updates {
            stateLock.lock()
            guard epoch == expectedEpoch, let onChange else { stateLock.unlock(); return }
            stateLock.unlock()
            onChange(update)
        }
    }

    /// stateLock owns pending; validation already happened at ingestion.
    private func drainPending() -> LibraryChangeSet {
        var created = Set<RelativePath>()
        var modified = Set<RelativePath>()
        var deleted = Set<RelativePath>()
        for (path, change) in pending {
            switch change.kind {
            case .created: created.insert(path)
            case .modified: modified.insert(path)
            case .deleted: deleted.insert(path)
            case nil: break
            }
        }
        pending.removeAll()
        return LibraryChangeSet(created: created, modified: modified, deleted: deleted)
    }
}
