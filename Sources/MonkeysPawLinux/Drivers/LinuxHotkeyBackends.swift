#if os(Linux)
import Foundation
import MonkeysPawCore

/// D-Bus actions are delivered by the compositor's binding, not a local key grab.
/// M1c/M1d can replace this selection without changing ShortcutService.
protocol LinuxHotkeyBackend: AnyObject, HotkeyBackend {
    var currentRegistration: HotkeyRegistration { get }
    var unboundActions: UnboundHotkeyActions { get }
    func registration(for action: HotkeyAction) -> HotkeyRegistration
    var onChange: (() -> Void)? { get set }
    @discardableResult func fire(_ action: HotkeyAction) -> Bool
    func configure(done: @escaping () -> Void)
    func configure(for action: HotkeyAction, done: @escaping () -> Void)
    func configureNative(done: @escaping () -> Void)
    func consumeActivationToken() -> String?
    func shutdown()
}

extension LinuxHotkeyBackend {
    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        action == .togglePicker ? currentRegistration : unboundActions.registration(for: action, mechanism: mechanism)
    }
    func configure(done: @escaping () -> Void) { done() }
    func configure(for action: HotkeyAction, done: @escaping () -> Void) {
        guard action == .togglePicker else { done(); return }
        configure(done: done)
    }
    func configureNative(done: @escaping () -> Void) { configure(done: done) }
    func consumeActivationToken() -> String? { nil }
    func shutdown() { unregister(currentRegistration) }
}

/// Catalogue entries for actions these adapters cannot bind yet (D9–D11).
/// Keep stable identities; unsupported adapters cannot consume callbacks.
final class UnboundHotkeyActions {
    private var registrations: [HotkeyAction: HotkeyRegistration] = [:]

    func registration(for action: HotkeyAction, mechanism: HotkeyMechanism) -> HotkeyRegistration {
        let registration = HotkeyRegistration(id: registrations[action]?.id ?? UUID(),
            mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut, configuration: .unavailable)
        registrations[action] = registration
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) -> Bool {
        registrations.values.contains { $0.id == registration.id }
    }

    /// A live registration may keep its initial id. Relinquish catalogue
    /// ownership so unregister reaches the live driver's teardown.
    func retire(_ action: HotkeyAction) {
        registrations.removeValue(forKey: action)
    }
}

final class ManualHotkeyBackend: LinuxHotkeyBackend {
    let mechanism = HotkeyMechanism.manual
    let unboundActions = UnboundHotkeyActions()
    var onChange: (() -> Void)?
    private var callbacks: [HotkeyAction: () -> Void] = [:]
    private var registrations: [HotkeyAction: HotkeyRegistration] = [:]
    private var isShutDown = false
    private let initialRegistration = HotkeyRegistration(
        mechanism: .manual, status: .needsAction, detail: GnomeKeybindingInstaller.command)
    var currentRegistration: HotkeyRegistration { registration(for: .togglePicker) }

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        if let registration = registrations[action] { return registration }
        if action == .togglePicker { return initialRegistration }
        return unboundRegistration(for: action)
    }

    private func unboundRegistration(for action: HotkeyAction) -> HotkeyRegistration {
        HotkeyRegistration(id: unboundActions.registration(for: action, mechanism: mechanism).id,
            mechanism: mechanism, status: .unbound, detail: GnomeKeybindingInstaller.command(for: action))
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard !isShutDown, accelerator != nil else {
            callbacks.removeValue(forKey: action)
            let registration = unboundRegistration(for: action)
            registrations[action] = registration
            return registration
        }
        unboundActions.retire(action)
        callbacks[action] = onFire
        let registration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
            detail: GnomeKeybindingInstaller.command(for: action))
        registrations[action] = registration
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let action = registrations.first(where: { $0.value.id == registration.id })?.key else { return }
        callbacks.removeValue(forKey: action)
        registrations[action] = HotkeyRegistration(id: registration.id, mechanism: mechanism,
            status: .unbound, detail: GnomeKeybindingInstaller.command(for: action))
    }

    func fire(_ action: HotkeyAction) -> Bool {
        guard !isShutDown, let onFire = callbacks[action] else { return false }
        onFire()
        return true
    }

    func shutdown() {
        isShutDown = true
        for registration in Array(registrations.values) { unregister(registration) }
    }
}

final class GnomeKeybindingBackend: LinuxHotkeyBackend {
    let mechanism = HotkeyMechanism.gnomeCustomKeybinding
    let unboundActions = UnboundHotkeyActions()
    var onChange: (() -> Void)?
    private let installer: GnomeKeybindingInstaller
    private let mainThread: MainThread
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.gsettings")
    private struct Entry {
        var registration: HotkeyRegistration
        let accelerator: Accelerator?
        let onFire: (() -> Void)?
    }
    private var entries: [HotkeyAction: Entry] = [:]
    private var configuring = Set<HotkeyAction>()
    private var isShutDown = false
    private let initialRegistration = HotkeyRegistration(
        mechanism: .gnomeCustomKeybinding, status: .needsAction, detail: LinuxStrings.installShortcut)
    var currentRegistration: HotkeyRegistration { registration(for: .togglePicker) }

    init(runner: LinuxToolRunner, mainThread: MainThread) {
        installer = GnomeKeybindingInstaller(runner: runner)
        self.mainThread = mainThread
    }

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        if let entry = entries[action] { return entry.registration }
        if action == .togglePicker { return initialRegistration }
        return unboundRegistration(for: action)
    }

    private func unboundRegistration(for action: HotkeyAction) -> HotkeyRegistration {
        HotkeyRegistration(id: unboundActions.registration(for: action, mechanism: mechanism).id,
            mechanism: mechanism, status: .unbound, detail: GnomeKeybindingInstaller.command(for: action))
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard !isShutDown, let accelerator else {
            let registration = unboundRegistration(for: action)
            entries[action] = Entry(registration: registration, accelerator: nil, onFire: nil)
            return registration
        }
        unboundActions.retire(action)
        let registration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
            detail: LinuxStrings.installShortcut(for: action))
        entries[action] = Entry(registration: registration, accelerator: accelerator, onFire: onFire)
        return registration
    }

    func configure(done: @escaping () -> Void) {
        configure(for: .togglePicker, done: done)
    }

    /// Called only after an explicit assignment. Nil repeat never creates a row.
    func configure(for action: HotkeyAction, done: @escaping () -> Void) {
        guard !isShutDown, !configuring.contains(action), let entry = entries[action],
              let accelerator = entry.accelerator, entry.onFire != nil else { done(); return }
        configuring.insert(action)
        let registration = entry.registration
        let deadline = ContinuousClock.now.advanced(by: Limits.portalConsentTimeout)
        worker.async {
            let binding = self.installer.install(action: action, accelerator: accelerator, deadline: deadline)
            self.mainThread.run {
                self.configuring.remove(action)
                defer { done() }
                guard !self.isShutDown, var current = self.entries[action],
                      current.registration.id == registration.id, current.onFire != nil else { return }
                let status: RegistrationStatus = binding.map { $0.isEmpty ? .unbound : .registered } ?? .failed
                current.registration = HotkeyRegistration(id: registration.id, mechanism: self.mechanism,
                    status: status, detail: binding.map { $0.isEmpty ? SetupStrings.unboundShortcut : $0 }
                        ?? LinuxStrings.shortcutFailed(for: action))
                self.entries[action] = current
                self.onChange?()
            }
        }
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let action = entries.first(where: { $0.value.registration.id == registration.id })?.key else { return }
        // The compositor-owned row survives app exit. Clear our callback and
        // requested key; the stored binding can still cold-start the app.
        let unbound = HotkeyRegistration(id: registration.id, mechanism: mechanism,
            status: .unbound, detail: GnomeKeybindingInstaller.command(for: action))
        entries[action] = Entry(registration: unbound, accelerator: nil, onFire: nil)
    }

    func fire(_ action: HotkeyAction) -> Bool {
        guard !isShutDown, let entry = entries[action], entry.registration.status != .failed,
              entry.registration.status != .unbound, let onFire = entry.onFire else { return false }
        onFire()
        return true
    }

    func shutdown() {
        isShutDown = true
        for entry in Array(entries.values) { unregister(entry.registration) }
    }
}
#endif
