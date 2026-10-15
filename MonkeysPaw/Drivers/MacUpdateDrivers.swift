import AppKit
import MonkeysPawCore

enum MacReleaseVersion {
    static func read(from info: [String: Any]) -> String? {
        // A present but invalid raw version must not become a guessed stable one.
        if let raw = info["MonkeysPawReleaseVersion"] { return raw as? String }
        return info["CFBundleShortVersionString"] as? String
    }
}

final class WorkspaceReleasePageOpener: ReleasePageOpening {
    private let open: (URL) -> Bool

    init(open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.open = open
    }

    func openReleasePage(_ url: URL, completion: @escaping (ReleasePageOpenOutcome) -> Void) {
        completion(open(url) ? .opened : .failed)
    }
}

/// Update-only timers can be removed without cancelling accepted delivery work.
final class MacUpdateScheduler: MonkeysPawCore.Scheduler {
    typealias Schedule = (Duration, @escaping () -> Void) -> (() -> Void)
    private let mainThread: MainThread
    private let schedule: Schedule
    private var pending: [UUID: (work: () -> Void, cancel: () -> Void)] = [:]
    private var isEnabled = false
    private var isStopped = false
    var pendingCount: Int { pending.count }

    init(mainThread: MainThread, schedule: @escaping Schedule = MacUpdateScheduler.scheduleTimer) {
        self.mainThread = mainThread
        self.schedule = schedule
    }

    deinit { for entry in pending.values { entry.cancel() } }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        mainThread.run { [weak self] in
            guard let self, self.isEnabled, !self.isStopped else { return }
            self.cancelPending()
            let id = UUID()
            self.pending[id] = (work, {})
            let cancel = self.schedule(delay) { [weak self] in
                guard let self, let entry = self.pending.removeValue(forKey: id),
                      self.isEnabled, !self.isStopped else { return }
                entry.work()
            }
            if self.pending[id] != nil { self.pending[id]?.cancel = cancel }
            else { cancel() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        mainThread.run { [weak self] in
            guard let self, !self.isStopped else { return }
            self.isEnabled = enabled
            if !enabled { self.cancelPending() }
        }
    }

    func stop() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.isEnabled = false
            self.cancelPending()
        }
    }

    private func cancelPending() {
        let cancellations = pending.values.map(\.cancel)
        pending.removeAll()
        for cancel in cancellations { cancel() }
    }

    static func scheduleTimer(_ delay: Duration, _ work: @escaping () -> Void) -> (() -> Void) {
        let timer = Timer(timeInterval: delay.timeInterval, repeats: false) { _ in work() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
