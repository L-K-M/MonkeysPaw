import Foundation

/// General's update controls. Construct/release/retire on the UI thread;
/// intents and reports marshal through MainThread. View lifetime does not
/// control the shared automatic-check service; composition owns start/stop.
public final class UpdateSettingsModel {
    public struct State: Equatable, Sendable {
        public let automaticUpdateChecks: AutomaticUpdateChecks
        public let isReadOnly: Bool
        public let settingsError: SettingsError?
        public let update: UpdateSnapshot?
    }

    /// One owner: the native Settings view.
    public var onChange: (() -> Void)?
    public private(set) var state: State

    private let settings: SettingsModel
    private let updates: UpdateService
    private let mainThread: MainThread
    private var settingsObserver: UUID?
    private var updateObserver: UUID?
    private var snapshot: UpdateSnapshot?
    private var active = true

    public init(settings: SettingsModel, updates: UpdateService, mainThread: MainThread) {
        self.settings = settings
        self.updates = updates
        self.mainThread = mainThread
        state = State(automaticUpdateChecks: settings.automaticUpdateChecks,
            isReadOnly: settings.isReadOnly, settingsError: settings.error, update: nil)
        settingsObserver = settings.addObserver { [weak self] _, _ in
            self?.mainThread.run { [weak self] in
                guard let self, self.active else { return }
                self.updates.refreshAutomaticPolicy()
                self.publish()
            }
        }
        updateObserver = updates.addObserver { [weak self] snapshot in self?.receive(snapshot) }
        refresh()
    }

    deinit { detachObservers() }

    /// Retirement revokes queued intents; ordinary close may release the model
    /// while allowing an already accepted preference write to finish.
    public func retire() {
        active = false
        detachObservers()
        onChange = nil
    }

    public func setAutomaticUpdateChecks(_ mode: AutomaticUpdateChecks) {
        mainThread.run {
            guard self.active else { return }
            self.settings.setAutomaticUpdateChecks(mode)
            self.updates.refreshAutomaticPolicy()
            self.publish()
        }
    }

    public func checkNow() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.updates.checkNow()
        }
    }

    public func viewRelease() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.updates.openReleasePage()
        }
    }

    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.settings.refresh()
            self.updates.readStatus { [weak self] in self?.receive($0) }
            self.publish()
        }
    }

    private func receive(_ snapshot: UpdateSnapshot) {
        mainThread.run { [weak self] in
            guard let self, self.active else { return }
            self.snapshot = snapshot
            self.publish()
        }
    }

    private func publish() {
        guard active else { return }
        let next = State(automaticUpdateChecks: settings.automaticUpdateChecks,
            isReadOnly: settings.isReadOnly, settingsError: settings.error, update: snapshot)
        guard next != state else { return }
        state = next
        onChange?()
    }

    private func detachObservers() {
        if let settingsObserver { settings.removeObserver(settingsObserver) }
        if let updateObserver { updates.removeObserver(updateObserver) }
        settingsObserver = nil
        updateObserver = nil
    }
}
