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
    func configureNative(done: @escaping () -> Void)
    func consumeActivationToken() -> String?
    func shutdown()
}

extension LinuxHotkeyBackend {
    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        action == .togglePicker ? currentRegistration : unboundActions.registration(for: action, mechanism: mechanism)
    }
    func configure(done: @escaping () -> Void) { done() }
    func configureNative(done: @escaping () -> Void) { configure(done: done) }
    func consumeActivationToken() -> String? { nil }
    func shutdown() { unregister(currentRegistration); unboundActions.clearCallbacks() }
}

/// Catalogue entries for actions these adapters cannot bind yet (D9–D11).
/// Retain callbacks without making unsupported actions appear effective.
final class UnboundHotkeyActions {
    private var registrations: [HotkeyAction: HotkeyRegistration] = [:]
    private var callbacks: [HotkeyAction: () -> Void] = [:]

    func registration(for action: HotkeyAction, mechanism: HotkeyMechanism) -> HotkeyRegistration {
        let registration = HotkeyRegistration(id: registrations[action]?.id ?? UUID(),
            mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut, configuration: .unavailable)
        registrations[action] = registration
        return registration
    }

    func register(_ action: HotkeyAction, mechanism: HotkeyMechanism,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        callbacks[action] = onFire
        return registration(for: action, mechanism: mechanism)
    }

    func unregister(_ registration: HotkeyRegistration) -> Bool {
        guard let action = registrations.first(where: { $0.value.id == registration.id })?.key else { return false }
        callbacks.removeValue(forKey: action)
        return true
    }

    func clearCallbacks() { callbacks.removeAll() }
}

final class ManualHotkeyBackend: LinuxHotkeyBackend {
    let mechanism = HotkeyMechanism.manual
    let unboundActions = UnboundHotkeyActions()
    var onChange: (() -> Void)?
    private var onFire: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(
        mechanism: .manual, status: .needsAction, detail: GnomeKeybindingInstaller.command)

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker, accelerator != nil else {
            if action == .togglePicker { unregister(currentRegistration) }
            let registration = unboundActions.register(action, mechanism: mechanism, onFire: onFire)
            if action == .togglePicker { currentRegistration = registration }
            return registration
        }
        self.onFire = onFire
        currentRegistration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
                                                detail: GnomeKeybindingInstaller.command)
        return currentRegistration
    }

    func unregister(_ registration: HotkeyRegistration) {
        if unboundActions.unregister(registration) { return }
        guard currentRegistration.id == registration.id else { return }
        onFire = nil
    }

    func fire(_ action: HotkeyAction) -> Bool {
        guard action == .togglePicker, let onFire else { return false }
        onFire()
        return true
    }
}

final class GnomeKeybindingBackend: LinuxHotkeyBackend {
    let mechanism = HotkeyMechanism.gnomeCustomKeybinding
    let unboundActions = UnboundHotkeyActions()
    var onChange: (() -> Void)?
    private let installer: GnomeKeybindingInstaller
    private let mainThread: MainThread
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.gsettings")
    private var onFire: (() -> Void)?
    private var accelerator: Accelerator?
    private var isConfiguring = false
    private(set) var currentRegistration = HotkeyRegistration(
        mechanism: .gnomeCustomKeybinding, status: .needsAction, detail: LinuxStrings.installShortcut)

    init(runner: LinuxToolRunner, mainThread: MainThread) {
        installer = GnomeKeybindingInstaller(runner: runner)
        self.mainThread = mainThread
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker, let accelerator else {
            if action == .togglePicker { unregister(currentRegistration) }
            let registration = unboundActions.register(action, mechanism: mechanism, onFire: onFire)
            if action == .togglePicker { currentRegistration = registration }
            return registration
        }
        self.onFire = onFire
        self.accelerator = accelerator
        currentRegistration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
                                                 detail: LinuxStrings.installShortcut)
        return currentRegistration
    }

    func configure(done: @escaping () -> Void) {
        guard !isConfiguring, let accelerator, onFire != nil else { done(); return }
        isConfiguring = true
        let registration = currentRegistration
        worker.async {
            let binding = self.installer.install(accelerator: accelerator)
            self.mainThread.run {
                self.isConfiguring = false
                defer { done() }
                guard self.currentRegistration.id == registration.id, self.onFire != nil else { return }
                let status: RegistrationStatus = binding == nil ? .failed : (binding!.isEmpty ? .unbound : .registered)
                self.currentRegistration = HotkeyRegistration(id: registration.id, mechanism: self.mechanism,
                    status: status, detail: binding.map { $0.isEmpty ? SetupStrings.unboundShortcut : $0 }
                        ?? LinuxStrings.shortcutFailed)
                self.onChange?()
            }
        }
    }

    func unregister(_ registration: HotkeyRegistration) {
        if unboundActions.unregister(registration) { return }
        guard currentRegistration.id == registration.id else { return }
        // The compositor-owned row survives app exit. Remove only our callback;
        // the binding can still cold-start the app through its D-Bus service.
        onFire = nil
    }

    func fire(_ action: HotkeyAction) -> Bool {
        guard action == .togglePicker, let onFire else { return false }
        onFire()
        return true
    }
}
#endif
