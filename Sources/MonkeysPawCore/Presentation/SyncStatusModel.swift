import Foundation

protocol SyncStatusProviding {
    var report: SyncReport { get }
    func observe(_ observer: @escaping (SyncReport) -> Void) -> UUID
    func removeObserver(_ id: UUID)
    func syncNow()
}

extension SyncService: SyncStatusProviding {}

/// Share across footer, Library and Account surfaces. Construct/read/subscribe/
/// remove/retire on UI; queued service reports and intents use MainThread.
public final class SyncStatusModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public private(set) var state: SyncStatusState
    public var onChange: (() -> Void)?

    private let sync: SyncStatusProviding
    private let mainThread: MainThread
    private var serviceObserver: UUID?
    private var observers: [UUID: (SyncStatusState) -> Void] = [:]
    private var active = true
    private var publication: UInt64 = 0

    public convenience init(sync: SyncService, mainThread: MainThread) {
        self.init(sync: sync as SyncStatusProviding, mainThread: mainThread)
    }

    init(sync: SyncStatusProviding, mainThread: MainThread) {
        self.sync = sync
        self.mainThread = mainThread
        state = SyncStatusState(report: sync.report)
        serviceObserver = sync.observe { [weak self] _ in
            // Read the current report at delivery, not an older queued value.
            self?.refresh()
        }
    }

    deinit { detach() }

    @discardableResult
    public func addObserver(_ observer: @escaping (SyncStatusState) -> Void) -> UUID {
        let id = UUID()
        if active { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    public func retire() {
        active = false
        detach()
        observers.removeAll()
        onChange = nil
    }

    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.publish(self.sync.report, details: self.state.showsErrorDetails ? .shown : .hidden)
        }
    }

    public func syncNow() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.publish(self.sync.report, details: self.state.showsErrorDetails ? .shown : .hidden)
            guard self.active, SyncStatusState(report: self.sync.report).canSyncNow else { return }
            self.sync.syncNow()
        }
    }

    public func showErrorDetails() { setErrorDetails(.shown) }
    public func dismissErrorDetails() { setErrorDetails(.hidden) }

    private enum ErrorDetails { case shown, hidden }

    private func setErrorDetails(_ visibility: ErrorDetails) {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.publish(self.sync.report, details: visibility)
        }
    }

    private func publish(_ report: SyncReport, details: ErrorDetails) {
        let next = SyncStatusState(report: report, showsErrorDetails: details == .shown)
        guard active, next != state else { return }
        state = next
        publication &+= 1
        let version = publication
        for id in Array(observers.keys) {
            mainThread.run { [weak self] in
                guard let self, self.active, self.publication == version,
                      let observer = self.observers[id] else { return }
                observer(next)
            }
        }
        if active, publication == version { onChange?() }
    }

    private func detach() {
        if let serviceObserver { sync.removeObserver(serviceObserver) }
        serviceObserver = nil
    }

    public var description: String { "<sync status model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
