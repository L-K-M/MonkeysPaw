import Foundation

/// Owns probing so SetupModel only calls the service layer (§4.2).
public final class SetupService {
    private let probe: SetupProbe
    private let session: SessionProbe
    private let shortcuts: ShortcutService
    private let selfTest: SelfTest
    private let mainThread: MainThread
    private var observers: [UUID: (SetupSnapshot) -> Void] = [:]
    private var shortcutObserver: UUID?
    private var isReadingSnapshot = false

    public init(
        probe: SetupProbe, session: SessionProbe, shortcuts: ShortcutService,
        selfTest: SelfTest, mainThread: MainThread
    ) {
        self.probe = probe
        self.session = session
        self.shortcuts = shortcuts
        self.selfTest = selfTest
        self.mainThread = mainThread
        shortcutObserver = shortcuts.addObserver { [weak self] in
            guard let self, !self.isReadingSnapshot else { return }
            self.refresh { _ in }
        }
    }

    deinit {
        if let shortcutObserver { shortcuts.removeObserver(shortcutObserver) }
    }

    /// Subscribers share one probe result per refresh, including live backend
    /// changes refreshed by the composition root. Callbacks run on MainThread.
    /// Removal applies after any notification already in progress.
    @discardableResult
    public func addObserver(_ observer: @escaping (SetupSnapshot) -> Void) -> UUID {
        let token = UUID()
        mainThread.run { self.observers[token] = observer }
        return token
    }

    public func removeObserver(_ token: UUID) {
        mainThread.run { self.observers.removeValue(forKey: token) }
    }

    public func refresh(done: @escaping (SetupSnapshot) -> Void) {
        mainThread.run {
            let snapshot = self.snapshot()
            // Notify observers before `done`: ShortcutsSettingsModel's
            // performPlatformChange reads its updated changePath there.
            for observer in Array(self.observers.values) { observer(snapshot) }
            done(snapshot)
        }
    }

    /// Recheck the row so a stale view cannot launch an unnecessary fix.
    public func performFix(for kind: SetupRow.Kind, action: HotkeyAction = .togglePicker) {
        mainThread.run {
            let snapshot = self.snapshot()
            guard var row = snapshot.rows.first(where: { $0.kind == kind }) else { return }
            if kind == .hotkey, let registration = snapshot.shortcutRegistrations[action] {
                row = SetupRow(kind: kind, status: self.hotkeyStatus(registration, action: action),
                               registration: registration)
            }
            if kind == .kde, let registration = snapshot.shortcutRegistrations[action] {
                if registration.configuration == .unavailable { return }
                row = SetupRow(kind: kind, status: row.status,
                    registration: registration.alternativeConfiguration.map {
                        HotkeyRegistration(id: registration.id, mechanism: registration.mechanism,
                            status: registration.status, detail: registration.detail, configuration: $0)
                    })
            }
            if (kind == .hotkey || kind == .kde), row.registration?.configuration == .unavailable { return }
            switch row.status {
            case .notApplicable: return
            case .ok:
                guard (kind == .hotkey || kind == .kde), row.registration?.configuration != nil else { return }
            case .needsAction, .unknown: break
            }

            // Keep duplicate completion checks on the UI thread as well.
            var didComplete = false
            self.probe.performFix(for: kind, action: action) {
                self.mainThread.run {
                    guard !didComplete else { return }
                    didComplete = true
                    self.refresh { _ in }
                }
            }
        }
    }

    public func beginHotkeyVerification(_ action: HotkeyAction = .togglePicker) {
        shortcuts.beginVerification(action)
    }

    public func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }

    private func snapshot() -> SetupSnapshot {
        let session = session.currentSession()
        let pickerRegistration = probe.hotkeyRegistration(for: .togglePicker)
        var incoming: [HotkeyAction: HotkeyRegistration] = [.togglePicker: pickerRegistration]
        for action in HotkeyAction.allCases where action != .togglePicker {
            incoming[action] = probe.hotkeyRegistration(for: action)
        }
        // The live read may itself notify ShortcutService observers. This
        // service will publish this snapshot, so do not recursively probe it.
        let wasReadingSnapshot = isReadingSnapshot
        isReadingSnapshot = true
        shortcuts.refreshRegistrations(incoming)
        isReadingSnapshot = wasReadingSnapshot
        let registrations = shortcuts.registrations
        let registration = registrations[.togglePicker] ?? pickerRegistration
        let hotkeyStatus = hotkeyStatus(registration, action: .togglePicker)

        let host = hostSession(of: session)
        let isKDE = host == .kdeWayland || host == .kdeX11
        let hasPortal: Bool
        let hasYdotool: Bool
        switch session {
        case .macOS:
            hasPortal = false
            hasYdotool = false
        case .flatpak:
            hasPortal = true
            hasYdotool = false
        case .gnomeWayland, .gnomeX11, .kdeWayland, .kdeX11:
            hasPortal = true
            hasYdotool = true
        case .otherX11, .wlroots:
            hasPortal = false
            hasYdotool = true
        }

        // Do not probe mechanisms absent from this session or sandbox ladder.
        return SetupSnapshot(session: session, rows: [
            SetupRow(kind: .accessibility, status: session == .macOS ? probe.accessibilityStatus() : .notApplicable),
            SetupRow(kind: .portal, status: hasPortal ? probe.portalStatus() : .notApplicable),
            SetupRow(kind: .ydotool, status: hasYdotool ? probe.ydotoolStatus() : .notApplicable),
            SetupRow(kind: .hotkey, status: hotkeyStatus, registration: registration),
            SetupRow(kind: .kde, status: isKDE ? probe.kdeStatus() : .notApplicable,
                registration: isKDE && registration.alternativeConfiguration != nil
                    ? HotkeyRegistration(id: registration.id, mechanism: registration.mechanism,
                        status: registration.status, detail: registration.detail,
                        configuration: registration.alternativeConfiguration) : nil),
        ], shortcutRegistrations: registrations)
    }

    private func hotkeyStatus(_ registration: HotkeyRegistration, action: HotkeyAction) -> SetupStatus {
        if registration.status == .unbound {
            return .needsAction(fix: SetupStrings.assignShortcut)
        } else if registration.status == .failed {
            // A current failure supersedes proof from an earlier activation.
            return .needsAction(fix: registration.detail)
        } else if shortcuts.verification(for: action) == .verified {
            return .ok
        } else if registration.status == .registered {
            return .needsAction(fix: SetupStrings.pressShortcut)
        } else {
            return .needsAction(fix: registration.detail)
        }
    }

    private func hostSession(of session: DesktopSession) -> DesktopSession {
        if case .flatpak(let host) = session { return hostSession(of: host) }
        return session
    }
}
