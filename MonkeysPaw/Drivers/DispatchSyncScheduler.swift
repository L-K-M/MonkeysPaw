import Foundation
import MonkeysPawCore

/// Sync callbacks never occupy AppKit's queue. Core's epochs revoke admitted
/// work; this driver also releases timers and their captures on graph teardown.
final class DispatchSyncScheduler: MonkeysPawCore.Scheduler {
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.sync-timers", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var active = true

    init() { queue.setSpecific(key: queueKey, value: ()) }
    deinit { tearDown() }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            let id = UUID()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + max(0, delay.timeInterval))
            timer.setEventHandler { [weak self] in
                guard let self, self.active, let timer = self.timers.removeValue(forKey: id) else { return }
                timer.cancel()
                work()
            }
            self.timers[id] = timer
            timer.resume()
        }
    }

    func tearDown() {
        onQueue {
            active = false
            for timer in timers.values { timer.setEventHandler {}; timer.cancel() }
            timers.removeAll()
        }
    }

    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() }
        else { queue.sync(execute: work) }
    }
}
