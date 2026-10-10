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
    private var onChange: (@Sendable (LibraryChangeSet) -> Void)?
    private var pending = [String: PendingChange]()
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0

    public init(watcher: FileStoreWatcher, scheduler: Scheduler) {
        self.watcher = watcher
        self.scheduler = scheduler
    }

    deinit { watcher.stop() }

    /// Idempotent while running. The scheduler owns the delivery thread.
    public func start(_ onChange: @escaping @Sendable (LibraryChangeSet) -> Void) throws {
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
        return wasRunning
    }

    private func receive(_ event: FileStoreEvent, epoch expectedEpoch: UInt64) {
        stateLock.lock()
        guard onChange != nil, epoch == expectedEpoch,
              (try? FileStorePath.validate(event.relativePath)) != nil,
              LibraryPath.isPrompt(event.relativePath) else {
            stateLock.unlock()
            return
        }

        if var change = pending[event.relativePath] {
            change.present = event.kind != .deleted
            pending[event.relativePath] = change
        } else {
            pending[event.relativePath] = PendingChange(event.kind)
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
        guard epoch == expectedEpoch, generation == expectedGeneration, let onChange else {
            stateLock.unlock()
            return
        }

        var created = Set<String>()
        var modified = Set<String>()
        var deleted = Set<String>()
        for (path, change) in pending where LibraryPath.isPrompt(path) {
            switch change.kind {
            case .created: created.insert(path)
            case .modified: modified.insert(path)
            case .deleted: deleted.insert(path)
            case nil: break
            }
        }
        pending.removeAll()
        stateLock.unlock()

        let changes = LibraryChangeSet(created: created, modified: modified, deleted: deleted)
        if !changes.isEmpty { onChange(changes) }
    }
}
