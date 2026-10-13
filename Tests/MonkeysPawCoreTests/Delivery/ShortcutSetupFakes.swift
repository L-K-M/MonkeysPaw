import Foundation
import MonkeysPawCore

final class FakeHotkeyBackend: HotkeyBackend {
    var mechanism: HotkeyMechanism = .globalShortcutsPortal
    var activationRevision: UUID?
    var status: RegistrationStatus = .registered
    var detail = "Registered by the system"
    var registrationOutcomes: [RegistrationStatus] = []
    private(set) var registered: [(HotkeyAction, Accelerator?)] = []
    private(set) var unregistered: [HotkeyRegistration] = []
    private(set) var callbacks: [HotkeyAction: () -> Void] = [:]
    private(set) var currentRegistrations: [HotkeyAction: HotkeyRegistration] = [:]

    func register(
        _ action: HotkeyAction, accelerator: Accelerator?, onFire: @escaping () -> Void
    ) -> HotkeyRegistration {
        registered.append((action, accelerator))
        callbacks[action] = onFire
        let outcome: RegistrationStatus = accelerator == nil ? .unbound
            : (registrationOutcomes.isEmpty ? status : registrationOutcomes.removeFirst())
        let registration = HotkeyRegistration(mechanism: mechanism, status: outcome, detail: detail)
        currentRegistrations[action] = registration
        return registration
    }

    func unregister(_ registration: HotkeyRegistration) {
        unregistered.append(registration)
        currentRegistrations = currentRegistrations.filter { $0.value != registration }
    }
    func fire(_ action: HotkeyAction = .togglePicker) { callbacks[action]?() }
}

final class FakeSetupProbe: SetupProbe {
    var accessibility: SetupStatus = .unknown
    var portal: SetupStatus = .unknown
    var ydotool: SetupStatus = .unknown
    var hotkey = HotkeyRegistration(mechanism: .manual, status: .needsAction, detail: "Bind toggle manually")
    var liveHotkey: (() -> HotkeyRegistration?)?
    var repeatHotkey = HotkeyRegistration(mechanism: .manual, status: .unbound,
        detail: SetupStrings.unboundShortcut, configuration: .unavailable)
    var liveRepeatHotkey: (() -> HotkeyRegistration?)?
    var kde: SetupStatus = .needsAction(fix: SetupStrings.kdeShortcut)
    var fixMode: FakeCompletionMode = .immediate
    private(set) var queried: [SetupRow.Kind] = []
    private(set) var fixes: [SetupRow.Kind] = []
    private(set) var fixedActions: [HotkeyAction] = []
    private(set) var queriedActions: [HotkeyAction] = []
    private var fixCompletions: [() -> Void] = []

    func accessibilityStatus() -> SetupStatus { queried.append(.accessibility); return accessibility }
    func portalStatus() -> SetupStatus { queried.append(.portal); return portal }
    func ydotoolStatus() -> SetupStatus { queried.append(.ydotool); return ydotool }
    func hotkeyRegistration(for action: HotkeyAction) -> HotkeyRegistration {
        // The row query remains one picker row; catalogue queries are separate.
        queriedActions.append(action)
        if action == .togglePicker { queried.append(.hotkey); return liveHotkey?() ?? hotkey }
        return liveRepeatHotkey?() ?? repeatHotkey
    }
    func kdeStatus() -> SetupStatus { queried.append(.kde); return kde }

    func performFix(for kind: SetupRow.Kind, action: HotkeyAction, done: @escaping () -> Void) {
        fixes.append(kind)
        fixedActions.append(action)
        switch fixMode {
        case .immediate: done()
        case .deferred: fixCompletions.append(done)
        }
    }

    func completeFix(times: Int = 1) {
        let completion = fixCompletions.removeFirst()
        for _ in 0..<times { completion() }
    }
}
