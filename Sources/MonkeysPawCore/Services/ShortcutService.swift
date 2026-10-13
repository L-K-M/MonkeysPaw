import Foundation

/// Registration is reported immediately; verification requires a real activation.
public final class ShortcutService {
    /// Registration results, updated with live facts by SetupService refreshes.
    /// Read only on the injected MainThread.
    public private(set) var registrations: [HotkeyAction: HotkeyRegistration] = [:]

    private let backend: HotkeyBackend
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private let settings: SettingsService?
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
    private var revisions: [HotkeyAction: UUID] = [:]
    private var retiredIDs = Set<UUID>()
    private var debouncing = Set<HotkeyAction>()
    private var replacing = Set<HotkeyAction>()

    /// Inject settings to load Carbon choices and persist confirmed edits.
    public init(backend: HotkeyBackend, scheduler: Scheduler, mainThread: MainThread,
                settings: SettingsService? = nil) {
        self.backend = backend
        self.scheduler = scheduler
        self.mainThread = mainThread
        self.settings = settings
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
            guard self.replacing.isEmpty else { return }
            self.onFire = onFire
            for action in HotkeyAction.allCases {
                let accelerator = self.backend.mechanism == .carbon && self.settings != nil
                    ? self.settings?.snapshot.document.carbonShortcuts.accelerator(for: action)
                    : accelerators[action]
                self.install(action, accelerator: accelerator)
            }
            self.notifyObservers()
        }
    }

    /// Compatibility intent for existing picker callers.
    public func setPickerAccelerator(
        _ text: String, done: @escaping (Result<HotkeyRegistration, ShortcutRebindError>) -> Void
    ) {
        setAccelerator(text, for: .togglePicker, done: done)
    }

    public func setAccelerator(
        _ text: String, for action: HotkeyAction,
        done: @escaping (Result<HotkeyRegistration, ShortcutRebindError>) -> Void
    ) {
        let accelerator: Accelerator
        do { accelerator = try Accelerator(text) }
        catch let error as AcceleratorError {
            mainThread.run { done(.failure(.invalidAccelerator(error))) }
            return
        } catch {
            mainThread.run { done(.failure(.invalidAccelerator(.malformed))) }
            return
        }
        replace(action, accelerator: accelerator, done: done)
    }

    public func clear(
        _ action: HotkeyAction, done: @escaping (Result<HotkeyRegistration, ShortcutRebindError>) -> Void
    ) {
        replace(action, accelerator: nil, done: done)
    }

    private func replace(
        _ action: HotkeyAction, accelerator: Accelerator?,
        done: @escaping (Result<HotkeyRegistration, ShortcutRebindError>) -> Void
    ) {
        mainThread.run {
            guard self.backend.mechanism == .carbon, self.onFire != nil,
                  self.replacing.insert(action).inserted else {
                done(.failure(.unavailable))
                return
            }
            defer { self.replacing.remove(action) }

            if let error = self.settings?.snapshot.readOnlyError {
                done(.failure(.saveFailed(error)))
                return
            }
            do {
                if let binding = try accelerator?.carbonBinding() {
                    for other in HotkeyAction.allCases where other != action {
                        if binding == (try self.accelerators[other]?.carbonBinding()) {
                            throw ShortcutRebindError.collision(other)
                        }
                    }
                }
            } catch {
                done(.failure(error as? ShortcutRebindError ?? .unavailable))
                return
            }

            let previous = self.accelerators[action]
            let registration = self.install(action, accelerator: accelerator)
            var failure: ShortcutRebindError?
            if !Self.confirmed(registration, accelerator: accelerator) {
                failure = .registrationFailed
            } else {
                do { try self.settings?.setCarbonShortcut(action, accelerator: accelerator) }
                catch let error as SettingsError { failure = .saveFailed(error) }
                catch let error as ShortcutRebindError { failure = error }
                catch { failure = .saveFailed(.writeFailed(.ioFailure)) }
            }

            if let failure {
                let restored = self.install(action, accelerator: previous)
                self.notifyObservers()
                done(.failure(Self.confirmed(restored, accelerator: previous) ? failure : .recoveryFailed))
                return
            }

            self.notifyObservers()
            done(.success(registration))
        }
    }

    private static func confirmed(_ registration: HotkeyRegistration, accelerator: Accelerator?) -> Bool {
        registration.mechanism == .carbon && registration.status == (accelerator == nil ? .unbound : .registered)
    }

    /// Setup owns the live probe. Updating here fans out without re-registering.
    /// Called only on MainThread, inside Setup's snapshot read.
    func refreshRegistrations(_ incoming: [HotkeyAction: HotkeyRegistration]) {
        var changed = false
        for (action, registration) in incoming {
            guard !replacing.contains(action), !retiredIDs.contains(registration.id) else { continue }
            let previous = registrations[action]
            guard previous != registration else { continue }
            registrations[action] = registration
            if previous?.id != registration.id || previous?.mechanism != registration.mechanism
                || previous?.status != registration.status || previous?.detail != registration.detail {
                verification.removeValue(forKey: action)
                verifiedSelection.removeValue(forKey: action)
            }
            changed = true
        }
        if changed { notifyObservers() }
    }

    /// A requested Carbon key becomes a known binding only after native success,
    /// and only for that exact registration identity. Never infer a default.
    func confirmedBinding(for registration: HotkeyRegistration) -> Accelerator? {
        guard registration.mechanism == .carbon, registration.status == .registered else { return nil }
        return confirmedCarbonBindings[registration.id]
    }

    /// Read only on the injected MainThread.
    public func verification(for action: HotkeyAction) -> ShortcutVerification {
        guard verifiedSelection[action] == activation,
              let registration = registrations[action],
              registration.status != .unbound, registration.status != .failed else { return .notStarted }
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

    @discardableResult
    private func install(_ action: HotkeyAction, accelerator: Accelerator?) -> HotkeyRegistration {
        let revision = UUID()
        revisions[action] = revision
        if let registration = ownedRegistrations.removeValue(forKey: action) {
            retiredIDs.insert(registration.id)
            confirmedCarbonBindings.removeValue(forKey: registration.id)
            backend.unregister(registration)
        }
        verification.removeValue(forKey: action)
        verifiedSelection.removeValue(forKey: action)
        debouncing.remove(action)
        accelerators[action] = accelerator

        let registration = backend.register(action, accelerator: accelerator) { [weak self] in
            guard let self else { return }
            let activation = self.activation
            self.mainThread.run {
                self.fired(action, revision: revision, activation: activation)
            }
        }
        // An unbound declaration may reuse its driver's stable identity.
        retiredIDs.remove(registration.id)
        registrations[action] = registration
        ownedRegistrations[action] = registration
        if registration.mechanism == .carbon, registration.status == .registered {
            confirmedCarbonBindings[registration.id] = accelerator
        }
        return registration
    }

    private func notifyObservers() {
        for observer in Array(observers.values) { observer() }
    }

    private func fired(_ action: HotkeyAction, revision: UUID, activation: Activation) {
        guard revision == revisions[action], activation == self.activation,
              let registration = registrations[action],
              registration.status != .unbound, registration.status != .failed else { return }

        if registration.mechanism == activation.mechanism, verification(for: action) == .waiting {
            verification[action] = .verified
            notifyObservers()
        }

        guard debouncing.insert(action).inserted else { return }
        scheduler.after(Limits.toggleDebounce) { [weak self] in
            guard let self else { return }
            self.mainThread.run {
                guard revision == self.revisions[action] else { return }
                self.debouncing.remove(action)
            }
        }
        onFire?(action)
    }
}
