/// Owns probing so SetupModel only calls the service layer (§4.2).
public final class SetupService {
    public var onChange: (() -> Void)?

    private let probe: SetupProbe
    private let session: SessionProbe
    private let shortcuts: ShortcutService
    private let selfTest: SelfTest
    private let mainThread: MainThread

    public init(
        probe: SetupProbe, session: SessionProbe, shortcuts: ShortcutService,
        selfTest: SelfTest, mainThread: MainThread
    ) {
        self.probe = probe
        self.session = session
        self.shortcuts = shortcuts
        self.selfTest = selfTest
        self.mainThread = mainThread
        shortcuts.onChange = { [weak self] in self?.onChange?() }
    }

    public func refresh(done: @escaping (SetupSnapshot) -> Void) {
        mainThread.run { done(self.snapshot()) }
    }

    public func beginHotkeyVerification() {
        shortcuts.beginVerification()
    }

    public func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }

    private func snapshot() -> SetupSnapshot {
        let session = session.currentSession()
        let registration = probe.hotkeyRegistration()
        let hotkeyStatus: SetupStatus
        if registration.status == .unbound {
            hotkeyStatus = .needsAction(fix: SetupStrings.assignShortcut)
        } else if registration.status == .failed {
            // A current failure supersedes proof from an earlier activation.
            hotkeyStatus = .needsAction(fix: registration.detail)
        } else if shortcuts.verification(for: .togglePicker) == .verified {
            hotkeyStatus = .ok
        } else if registration.status == .registered {
            hotkeyStatus = .needsAction(fix: SetupStrings.pressShortcut)
        } else {
            hotkeyStatus = .needsAction(fix: registration.detail)
        }

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
            SetupRow(kind: .kde, status: isKDE ? probe.kdeStatus() : .notApplicable),
        ])
    }

    private func hostSession(of session: DesktopSession) -> DesktopSession {
        if case .flatpak(let host) = session { return hostSession(of: host) }
        return session
    }
}
