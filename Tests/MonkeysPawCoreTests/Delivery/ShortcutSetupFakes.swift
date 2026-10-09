import Foundation
import MonkeysPawCore

final class FakeHotkeyBackend: HotkeyBackend {
    var mechanism: HotkeyMechanism = .globalShortcutsPortal
    var activationRevision: UUID?
    var status: RegistrationStatus = .registered
    var detail = "Registered by the system"
    private(set) var registered: [(HotkeyAction, Accelerator)] = []
    private(set) var unregistered: [HotkeyRegistration] = []
    private(set) var callbacks: [HotkeyAction: () -> Void] = [:]

    func register(
        _ action: HotkeyAction, accelerator: Accelerator, onFire: @escaping () -> Void
    ) -> HotkeyRegistration {
        registered.append((action, accelerator))
        callbacks[action] = onFire
        return HotkeyRegistration(mechanism: mechanism, status: status, detail: detail)
    }

    func unregister(_ registration: HotkeyRegistration) { unregistered.append(registration) }
    func fire(_ action: HotkeyAction = .togglePicker) { callbacks[action]?() }
}

final class FakeSetupProbe: SetupProbe {
    var accessibility: SetupStatus = .unknown
    var portal: SetupStatus = .unknown
    var ydotool: SetupStatus = .unknown
    var hotkey = HotkeyRegistration(mechanism: .manual, status: .needsAction, detail: "Bind toggle manually")
    var kde: SetupStatus = .needsAction(fix: SetupStrings.kdeShortcut)
    var fixMode: FakeCompletionMode = .immediate
    private(set) var queried: [SetupRow.Kind] = []
    private(set) var fixes: [SetupRow.Kind] = []
    private var fixCompletions: [() -> Void] = []

    func accessibilityStatus() -> SetupStatus { queried.append(.accessibility); return accessibility }
    func portalStatus() -> SetupStatus { queried.append(.portal); return portal }
    func ydotoolStatus() -> SetupStatus { queried.append(.ydotool); return ydotool }
    func hotkeyRegistration() -> HotkeyRegistration { queried.append(.hotkey); return hotkey }
    func kdeStatus() -> SetupStatus { queried.append(.kde); return kde }

    func performFix(for kind: SetupRow.Kind, done: @escaping () -> Void) {
        fixes.append(kind)
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
