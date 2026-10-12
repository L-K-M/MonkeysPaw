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
            action == .repeatLast ? .unbound : registration?.status
        }
    }

    /// One owner: the platform view. Service subscriptions remain independent.
    public var onChange: (() -> Void)?
    public private(set) var togglePicker = ActionState(
        action: .togglePicker, binding: .unknown, registration: nil,
        verification: .notStarted, changePath: .unavailable
    )
    public let repeatLast = ActionState(
        action: .repeatLast, binding: .unbound, registration: nil,
        verification: .notStarted, changePath: .unavailable
    )
    public private(set) var error: ShortcutRebindError?
    public private(set) var instructions: String?

    private let shortcuts: ShortcutService
    private let setup: SetupService
    private var observer: UUID?

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

    public func beginVerification() {
        setup.beginHotkeyVerification()
    }

    /// Only the picker has a change intent. Repeat remains inactive until M7.
    public func setAccelerator(_ text: String) {
        shortcuts.setPickerAccelerator(text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.error = nil
                self.refresh()
            case .failure(let error):
                self.error = error
                self.onChange?()
            }
        }
    }

    public func performPlatformChange() {
        // Recheck the live mechanism/capability before choosing an action.
        setup.refresh { [weak self] _ in
            guard let self else { return }
            self.instructions = nil
            switch self.togglePicker.changePath {
            case .systemSettings(let action), .setup(let action):
                self.setup.performFix(for: action)
            case .systemSettingsGuidance(let text), .manualInstructions(let text):
                self.instructions = text
                self.onChange?()
            case .unavailable, .inApp: break
            }
        }
    }

    private func update(_ snapshot: SetupSnapshot) {
        guard let registration = snapshot.rows.first(where: { $0.kind == .hotkey })?.registration else { return }
        if togglePicker.registration != registration {
            error = nil
            instructions = nil
        }

        let verification: ShortcutVerification
        switch registration.status {
        case .unbound, .failed: verification = .notStarted
        case .registered, .needsAction: verification = shortcuts.verification(for: .togglePicker)
        }
        togglePicker = ActionState(action: .togglePicker, binding: binding(for: registration),
            registration: registration, verification: verification,
            changePath: changePath(for: registration, session: snapshot.session))
        onChange?()
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
        case .gnomeWayland, .gnomeX11:
            return "Change the key in GNOME Settings → Keyboard → View and Customize Shortcuts"
        default: return "Change the key in your desktop's keyboard shortcut settings"
        }
    }
}
