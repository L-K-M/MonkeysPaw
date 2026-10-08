/// Registration is reported immediately; verification requires a real activation.
public final class ShortcutService {
    public var onChange: (() -> Void)?
    public private(set) var registrations: [HotkeyAction: HotkeyRegistration] = [:]

    private enum ToggleState {
        case ready, debouncing
    }

    private let backend: HotkeyBackend
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private var verification: [HotkeyAction: ShortcutVerification] = [:]
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
                    self.mainThread.run {
                        self.fired(action, revision: revision, onFire: onFire)
                    }
                }
            }
            self.onChange?()
        }
    }

    public func verification(for action: HotkeyAction) -> ShortcutVerification {
        verification[action] ?? .notStarted
    }

    public func beginVerification(_ action: HotkeyAction = .togglePicker) {
        mainThread.run {
            guard let registration = self.registrations[action], registration.status != .unbound else { return }
            self.verification[action] = .waiting
            self.onChange?()
        }
    }

    private func fired(_ action: HotkeyAction, revision: Int, onFire: (HotkeyAction) -> Void) {
        guard revision == self.revision else { return }

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
