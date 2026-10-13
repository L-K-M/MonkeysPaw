import Foundation

/// Registration is reported immediately; verification requires a real activation.
public final class ShortcutService {
    /// Registration results, updated with live facts by SetupService refreshes.
    /// Read only on the injected MainThread.
    public private(set) var registrations: [HotkeyAction: HotkeyRegistration] = [:]

    private enum ToggleState {
        case ready, debouncing
    }

    private let backend: HotkeyBackend
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private var observers: [UUID: () -> Void] = [:]
    private var accelerators: [HotkeyAction: Accelerator] = [:]
    private var onFire: ((HotkeyAction) -> Void)?
    private var confirmedCarbonBindings: [UUID: Accelerator] = [:]
    private var ownedRegistrations: [HotkeyAction: HotkeyRegistration] = [:]
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

    /// Add/remove are marshalled through MainThread, as are notifications.
    /// Removal takes effect for subsequent notifications; an in-progress
    /// notification uses a snapshot so observers may safely remove themselves.
    @discardableResult
    public func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        mainThread.run { self.observers[token] = observer }
        return token
    }

    public func removeObserver(_ token: UUID) {
        mainThread.run { self.observers.removeValue(forKey: token) }
    }

    public func configure(
        _ accelerators: [HotkeyAction: Accelerator], onFire: @escaping (HotkeyAction) -> Void
    ) {
        mainThread.run { [self] in
            self.apply(accelerators, onFire: onFire)
        }
    }

    /// Carbon is app-owned. Validate before tearing down the working binding.
    /// A successful request still exposes the backend's registration status;
    /// it does not verify activation or promise that native registration worked.
    public func setPickerAccelerator(
        _ text: String, done: @escaping (Result<HotkeyRegistration, ShortcutRebindError>) -> Void
    ) {
        mainThread.run {
            guard self.backend.mechanism == .carbon, let onFire = self.onFire else {
                done(.failure(.unavailable))
                return
            }

            let accelerator: Accelerator
            do { accelerator = try Accelerator(text) }
            catch let error as AcceleratorError {
                done(.failure(.invalidAccelerator(error)))
                return
            } catch {
                done(.failure(.invalidAccelerator(.malformed)))
                return
            }

            // Mirrors CarbonHotkeyBackend.translate's portable rejection rules.
            let commandAliases: Set<Accelerator.Modifier> = [.command, .superKey, .commandOrControl]
            guard accelerator.modifiers.intersection(commandAliases).count <= 1 else {
                done(.failure(.overlappingCommandModifiers))
                return
            }
            switch accelerator.key {
            case .function(let number) where number > 20:
                done(.failure(.unsupportedCarbonKey))
                return
            case .named(.insert), .named(.printScreen):
                done(.failure(.unsupportedCarbonKey))
                return
            default: break
            }

            var accelerators = self.accelerators
            accelerators[.togglePicker] = accelerator
            self.apply(accelerators, onFire: onFire)
            // apply registers every configured action; keep the completion total.
            guard let registration = self.registrations[.togglePicker] else {
                done(.failure(.unavailable))
                return
            }
            done(.success(registration))
        }
    }

    /// Setup owns the live probe. Updating here fans out without re-registering.
    /// Called only on MainThread, inside Setup's snapshot read.
    func refreshRegistration(_ registration: HotkeyRegistration) {
        let previous = registrations[.togglePicker]
        guard previous != registration else { return }
        registrations[.togglePicker] = registration
        if previous?.id != registration.id || previous?.mechanism != registration.mechanism
            || previous?.status != registration.status || previous?.detail != registration.detail {
            verification.removeValue(forKey: .togglePicker)
            verifiedSelection.removeValue(forKey: .togglePicker)
        }
        notifyObservers()
    }

    /// A requested Carbon key becomes a known binding only after native success,
    /// and only for that exact registration identity. Never infer a default.
    func confirmedBinding(for registration: HotkeyRegistration) -> Accelerator? {
        guard registration.mechanism == .carbon, registration.status == .registered else { return nil }
        return confirmedCarbonBindings[registration.id]
    }

    /// Read only on the injected MainThread.
    public func verification(for action: HotkeyAction) -> ShortcutVerification {
        guard verifiedSelection[action] == activation else { return .notStarted }
        return verification[action] ?? .notStarted
    }

    public func beginVerification(_ action: HotkeyAction = .togglePicker) {
        mainThread.run {
            guard let registration = self.registrations[action],
                  registration.status != .unbound, registration.status != .failed else { return }
            self.verification[action] = .waiting
            self.verifiedSelection[action] = self.activation
            self.notifyObservers()
        }
    }

    private func apply(_ accelerators: [HotkeyAction: Accelerator], onFire: @escaping (HotkeyAction) -> Void) {
        // Ignore late activations from registrations that were replaced.
        revision += 1
        let revision = revision
        for registration in ownedRegistrations.values where registration.status != .unbound {
            backend.unregister(registration)
        }
        registrations.removeAll()
        ownedRegistrations.removeAll()
        verification.removeAll()
        verifiedSelection.removeAll()
        confirmedCarbonBindings.removeAll()
        toggleState = .ready
        self.accelerators = accelerators
        self.onFire = onFire

        for action in HotkeyAction.allCases {
            guard let accelerator = accelerators[action] else {
                registrations[action] = HotkeyRegistration(
                    mechanism: backend.mechanism, status: .unbound, detail: SetupStrings.unboundShortcut
                )
                continue
            }
            let registration = backend.register(action, accelerator: accelerator) { [weak self] in
                guard let self else { return }
                let activation = self.activation
                self.mainThread.run {
                    self.fired(action, revision: revision, activation: activation, onFire: onFire)
                }
            }
            registrations[action] = registration
            ownedRegistrations[action] = registration
            if registration.mechanism == .carbon, registration.status == .registered {
                confirmedCarbonBindings[registration.id] = accelerator
            }
        }
        notifyObservers()
    }

    private func notifyObservers() {
        for observer in Array(observers.values) { observer() }
    }

    private func fired(_ action: HotkeyAction, revision: Int, activation: Activation,
                       onFire: (HotkeyAction) -> Void) {
        guard revision == self.revision, activation == self.activation else { return }

        if verification(for: action) == .waiting {
            verification[action] = .verified
            notifyObservers()
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
