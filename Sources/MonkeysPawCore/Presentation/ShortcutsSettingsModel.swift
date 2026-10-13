import Foundation

/// Settings → Shortcuts (§6.1/§11.1). Intents enter on the UI thread;
/// refreshed state and callbacks arrive through the services' MainThread.
public final class ShortcutsSettingsModel {
    public enum Binding: Equatable {
        case unknown
        case unbound
        case accelerator(Accelerator)
        /// Preserve system-owned descriptions, including KDE multi-chords.
        case reported(String)
    }

    public enum ChangePath: Equatable {
        case unavailable
        case inApp
        case systemSettings(action: SetupRow.Kind)
        case systemSettingsGuidance(String)
        case setup(SetupRow.Kind)
        case manualInstructions(String)
    }

    public struct ActionState: Equatable {
        public let action: HotkeyAction
        public let binding: Binding
        /// Backend detail includes any reported conflict or failure. Do not
        /// parse localized detail into a key or invent conflict detection.
        public let registration: HotkeyRegistration?
        public let verification: ShortcutVerification
        public let changePath: ChangePath

        public var registrationStatus: RegistrationStatus? {
            registration?.status
        }
    }

    /// One owner: the platform view. Service subscriptions remain independent.
    public var onChange: (() -> Void)?
    public private(set) var togglePicker = ActionState(
        action: .togglePicker, binding: .unknown, registration: nil,
        verification: .notStarted, changePath: .unavailable
    )
    public private(set) var repeatLast = ActionState(
        action: .repeatLast, binding: .unbound, registration: nil,
        verification: .notStarted, changePath: .unavailable
    )
    public var error: ShortcutRebindError? { error(for: .togglePicker) }
    public var instructions: String? { instructions(for: .togglePicker) }

    private let shortcuts: ShortcutService
    private let setup: SetupService
    private var observer: UUID?
    private var errors: [HotkeyAction: ShortcutRebindError] = [:]
    private var actionInstructions: [HotkeyAction: String] = [:]

    public init(shortcuts: ShortcutService, setup: SetupService) {
        self.shortcuts = shortcuts
        self.setup = setup
        observer = setup.addObserver { [weak self] snapshot in self?.update(snapshot) }
        refresh()
    }

    deinit {
        if let observer { setup.removeObserver(observer) }
    }

    public func refresh() {
        setup.refresh { _ in }
    }

    public func state(for action: HotkeyAction) -> ActionState {
        action == .togglePicker ? togglePicker : repeatLast
    }

    public func error(for action: HotkeyAction) -> ShortcutRebindError? { errors[action] }
    public func instructions(for action: HotkeyAction) -> String? { actionInstructions[action] }

    public func beginVerification(_ action: HotkeyAction = .togglePicker) {
        setup.beginHotkeyVerification(action)
    }

    public func setAccelerator(_ text: String, for action: HotkeyAction = .togglePicker) {
        shortcuts.setAccelerator(text, for: action) { [weak self] in self?.completed($0, for: action) }
    }

    public func clear(_ action: HotkeyAction) {
        shortcuts.clear(action) { [weak self] in self?.completed($0, for: action) }
    }

    private func completed(_ result: Result<HotkeyRegistration, ShortcutRebindError>, for action: HotkeyAction) {
        switch result {
        case .success:
            // An unchanged refreshed state must still publish the cleared error.
            if errors.removeValue(forKey: action) != nil { onChange?() }
            refresh()
        case .failure(let error):
            errors[action] = error
            onChange?()
        }
    }

    public func performPlatformChange(for action: HotkeyAction = .togglePicker) {
        // Recheck the live mechanism/capability before choosing an action.
        setup.refresh { [weak self] _ in
            guard let self else { return }
            self.actionInstructions.removeValue(forKey: action)
            defer { self.onChange?() }
            switch self.state(for: action).changePath {
            case .systemSettings(let kind), .setup(let kind):
                self.setup.performFix(for: kind, action: action)
            case .systemSettingsGuidance(let text), .manualInstructions(let text):
                self.actionInstructions[action] = text
            case .unavailable, .inApp: break
            }
        }
    }

    private func update(_ snapshot: SetupSnapshot) {
        var changed = false
        for action in HotkeyAction.allCases {
            guard let registration = snapshot.shortcutRegistrations[action] else { continue }
            if state(for: action).registration != registration {
                changed = errors.removeValue(forKey: action) != nil || changed
                changed = actionInstructions.removeValue(forKey: action) != nil || changed
            }
            let state = ActionState(action: action, binding: binding(for: registration),
                registration: registration, verification: shortcuts.verification(for: action),
                changePath: changePath(for: registration, session: snapshot.session))
            guard state != self.state(for: action) else { continue }
            if action == .togglePicker { togglePicker = state } else { repeatLast = state }
            changed = true
        }
        if changed { onChange?() }
    }

    private func binding(for registration: HotkeyRegistration) -> Binding {
        if registration.status == .unbound { return .unbound }
        guard registration.status == .registered else { return .unknown }
        if let accelerator = shortcuts.confirmedBinding(for: registration) { return .accelerator(accelerator) }
        guard registration.mechanism != .carbon, registration.mechanism != .manual,
              !registration.detail.isEmpty else { return .unknown }
        return .reported(registration.detail)
    }

    private func changePath(for registration: HotkeyRegistration, session: DesktopSession) -> ChangePath {
        if registration.configuration == .unavailable { return .unavailable }
        switch registration.mechanism {
        case .carbon: return .inApp
        case .kglobalaccel:
            // The composite's primary hotkey action may attach the portal;
            // its KDE row keeps the explicit native settings action instead.
            return .systemSettings(action: registration.configuration == .attachPortal ? .kde : .hotkey)
        case .globalShortcutsPortal:
            if registration.configuration == .systemSettings { return .systemSettings(action: .hotkey) }
            if registration.configuration == .attachPortal { return .setup(.hotkey) }
            switch registration.status {
            case .registered, .unbound: return .systemSettingsGuidance(systemGuidance(for: session))
            case .needsAction, .failed: return .setup(.hotkey)
            }
        case .gnomeCustomKeybinding:
            if registration.status == .registered {
                return .systemSettingsGuidance(systemGuidance(for: session))
            }
            return .setup(.hotkey)
        case .manual: return .manualInstructions(registration.detail)
        }
    }

    private func systemGuidance(for session: DesktopSession) -> String {
        switch session {
        case .flatpak(let host): return systemGuidance(for: host)
        case .kdeWayland, .kdeX11: return SetupStrings.kdeShortcut
        case .gnomeWayland, .gnomeX11: return SetupStrings.gnomeShortcut
        default: return SetupStrings.genericShortcutSettings
        }
    }
}
