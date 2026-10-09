import Foundation

/// Registration is reported immediately; verification requires a real activation.
public final class ShortcutService {
    /// This hook has one owner, SetupService. Assignment replaces the callback.
    public var onChange: (() -> Void)?

    /// State returned at registration. Read only on the injected MainThread.
    /// Setup reads live driver status from SetupProbe.
    public private(set) var registrations: [HotkeyAction: HotkeyRegistration] = [:]

    private enum ToggleState {
        case ready, debouncing
    }

    private let backend: HotkeyBackend
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private var verification: [HotkeyAction: ShortcutVerification] = [:]
    private struct Activation: Equatable {
        let mechanism: HotkeyMechanism
        let revision: UUID?
    }
    private var verifiedSelection: [HotkeyAction: Activation] = [:]
    private var activation: Activation {
        Activation(mechanism: backend.mechanism, revision: backend.activationRevision)
    }
    private var revision = 0
    private var toggleState = ToggleState.ready

    public init(backend: HotkeyBackend, scheduler: Scheduler, mainThread: MainThread) {
        self.backend = backend
        self.scheduler = scheduler
        self.mainThread = mainThread
    }

    public func configure(
        _ accelerators: [HotkeyAction: Accelerator], onFire: @escaping (HotkeyAction) -> Void
    ) {
        mainThread.run { [self] in
            // Ignore late activations from registrations that were replaced.
            self.revision += 1
            let revision = self.revision
            for registration in self.registrations.values where registration.status != .unbound {
                self.backend.unregister(registration)
            }
            self.registrations.removeAll()
            self.verification.removeAll()
            self.verifiedSelection.removeAll()
            self.toggleState = .ready

            for action in HotkeyAction.allCases {
                guard let accelerator = accelerators[action] else {
                    self.registrations[action] = HotkeyRegistration(
                        mechanism: self.backend.mechanism, status: .unbound,
                        detail: SetupStrings.unboundShortcut
                    )
                    continue
                }
                self.registrations[action] = self.backend.register(
                    action, accelerator: accelerator
                ) { [weak self] in
                    guard let self else { return }
                    let activation = self.activation
                    self.mainThread.run {
                        self.fired(action, revision: revision, activation: activation, onFire: onFire)
                    }
                }
            }
            self.onChange?()
        }
    }

    /// Read only on the injected MainThread.
    public func verification(for action: HotkeyAction) -> ShortcutVerification {
        guard verifiedSelection[action] == activation else { return .notStarted }
        return verification[action] ?? .notStarted
    }

    public func beginVerification(_ action: HotkeyAction = .togglePicker) {
        mainThread.run {
            guard let registration = self.registrations[action], registration.status != .unbound else { return }
            self.verification[action] = .waiting
            self.verifiedSelection[action] = self.activation
            self.onChange?()
        }
    }

    private func fired(_ action: HotkeyAction, revision: Int, activation: Activation,
                       onFire: (HotkeyAction) -> Void) {
        guard revision == self.revision, activation == self.activation else { return }

        if verification(for: action) == .waiting {
            verification[action] = .verified
            onChange?()
        }

        if action == .togglePicker {
            guard toggleState == .ready else { return }
            toggleState = .debouncing
            scheduler.after(Limits.toggleDebounce) { [weak self] in
                guard let self else { return }
                self.mainThread.run {
                    guard revision == self.revision else { return }
                    self.toggleState = .ready
                }
            }
        }
        onFire(action)
    }
}
