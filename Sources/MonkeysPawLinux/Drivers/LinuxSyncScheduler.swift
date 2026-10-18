#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GLib fires timers; the shared worker executes sync callbacks and file work.
/// Retirement cancels native sources and revokes work already queued to the worker.
final class LinuxSyncScheduler: Scheduler {
    private let worker: BackgroundWork
    private let timer: Scheduler?
    private let lock = NSRecursiveLock()
    private var active = true
    private var sources: [UUID: guint] = [:]

    init(worker: BackgroundWork, timer: Scheduler? = nil) {
        self.worker = worker
        self.timer = timer
    }

    deinit { retire() }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let token = UUID()
        sources[token] = 0
        let fire = { [weak self] in self?.fire(token, work: work) }
        if let timer { timer.after(delay) { fire() } }
        else { sources[token] = GTK.after(delay.timeInterval) { fire() } }
    }

    func retire() {
        lock.lock()
        active = false
        let pending = sources.values.filter { $0 != 0 }
        sources.removeAll()
        // Removing under the lock cannot race a callback's removal.
        for source in pending { g_source_remove(source) }
        lock.unlock()
    }

    private func fire(_ token: UUID, work: @escaping () -> Void) {
        lock.lock()
        let admitted = active && sources.removeValue(forKey: token) != nil
        lock.unlock()
        guard admitted else { return }
        worker.run { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.active
            self.lock.unlock()
            guard active else { return }
            // SyncService's own epoch/permit fences an already admitted callback.
            work()
        }
    }
}
#endif
