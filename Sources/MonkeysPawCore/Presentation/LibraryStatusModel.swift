import Foundation

/// Composition's library health for menus, Settings and onboarding (§11.5).
/// Share one instance per process. Construct/release and add/remove observers
/// on the UI thread; updates and notification requests use MainThread.
public final class LibraryStatusModel {
    public enum State: Equatable, Sendable {
        case available
        case unavailableAtStartup
        case lostWhileRunning
    }

    public private(set) var state: State
    public var libraryAvailable: Bool { state == .available }
    public var needsLibraryFolderStep: Bool { state == .unavailableAtStartup }
    public var menuLabel: String {
        libraryAvailable ? OnboardingStrings.libraryAvailableMenu : OnboardingStrings.libraryUnavailableMenu
    }

    private let mainThread: MainThread
    private let notifyStartupUnavailable: () -> Void
    private var notificationRequested = false
    private var observers: [UUID: (State) -> Void] = [:]

    /// The closure is a one-shot request to composition, which implements
    /// LibraryAvailabilityNotifier. No settings flags or drivers are changed here.
    public init(initialState: State, mainThread: MainThread,
                notifyStartupUnavailable: @escaping () -> Void) {
        state = initialState
        self.mainThread = mainThread
        self.notifyStartupUnavailable = notifyStartupUnavailable
        mainThread.run { self.requestStartupNotificationIfNeeded() }
    }

    /// Independent subscribers receive real changes through MainThread.
    /// Removal applies after any notification already in progress.
    @discardableResult
    public func addObserver(_ observer: @escaping (State) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Runtime root loss is terminal for this process, even if a later graph
    /// reports availability. Restoration requires a restart, not a rescan.
    public func update(_ next: State) {
        mainThread.run {
            guard self.state != .lostWhileRunning, self.state != next else { return }
            self.state = next
            let notify = self.takeStartupNotificationRequest()
            for observer in Array(self.observers.values) { observer(next) }
            if notify { self.notifyStartupUnavailable() }
        }
    }

    private func requestStartupNotificationIfNeeded() {
        if takeStartupNotificationRequest() { notifyStartupUnavailable() }
    }

    private func takeStartupNotificationRequest() -> Bool {
        guard state == .unavailableAtStartup, !notificationRequested else { return false }
        notificationRequested = true
        return true
    }
}
