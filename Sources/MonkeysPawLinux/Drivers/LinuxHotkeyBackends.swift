#if os(Linux)
import Foundation
import MonkeysPawCore

/// D-Bus actions are delivered by the compositor's binding, not a local key grab.
/// M1c/M1d can replace this selection without changing ShortcutService.
protocol LinuxHotkeyBackend: AnyObject, HotkeyBackend {
    var currentRegistration: HotkeyRegistration { get }
    var onChange: (() -> Void)? { get set }
    @discardableResult func fire(_ action: HotkeyAction) -> Bool
}

final class ManualHotkeyBackend: LinuxHotkeyBackend {
    let mechanism = HotkeyMechanism.manual
    var onChange: (() -> Void)?
    private var onFire: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(
        mechanism: .manual, status: .needsAction, detail: GnomeKeybindingInstaller.command)

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker else {
            return HotkeyRegistration(mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        self.onFire = onFire
        currentRegistration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
                                                detail: GnomeKeybindingInstaller.command)
        return currentRegistration
    }

    func unregister(_ registration: HotkeyRegistration) {
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
    var onChange: (() -> Void)?
    private let installer: GnomeKeybindingInstaller
    private let mainThread: MainThread
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.gsettings")
    private var onFire: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(
        mechanism: .gnomeCustomKeybinding, status: .needsAction, detail: LinuxStrings.installingShortcut)

    init(runner: LinuxToolRunner, mainThread: MainThread) {
        installer = GnomeKeybindingInstaller(runner: runner)
        self.mainThread = mainThread
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker else {
            return HotkeyRegistration(mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        self.onFire = onFire
        let registration = HotkeyRegistration(mechanism: mechanism, status: .needsAction,
                                             detail: LinuxStrings.installingShortcut)
        currentRegistration = registration
        worker.async {
            let binding = self.installer.install(accelerator: accelerator)
            self.mainThread.run {
                guard self.currentRegistration.id == registration.id, self.onFire != nil else { return }
                let status: RegistrationStatus = binding == nil ? .failed : (binding!.isEmpty ? .unbound : .registered)
                self.currentRegistration = HotkeyRegistration(id: registration.id, mechanism: self.mechanism,
                    status: status, detail: binding.map { $0.isEmpty ? SetupStrings.unboundShortcut : $0 }
                        ?? LinuxStrings.shortcutFailed)
                self.onChange?()
            }
        }
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
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
