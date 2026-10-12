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
    public func performFix(for kind: SetupRow.Kind) {
        mainThread.run {
            guard let row = self.snapshot().rows.first(where: { $0.kind == kind }) else { return }
            switch row.status {
            case .notApplicable: return
            case .ok:
                guard (kind == .hotkey || kind == .kde), row.registration?.configuration != nil else { return }
            case .needsAction, .unknown: break
            }

            // Keep duplicate completion checks on the UI thread as well.
            var didComplete = false
            self.probe.performFix(for: kind) {
                self.mainThread.run {
                    guard !didComplete else { return }
                    didComplete = true
                    self.refresh { _ in }
                }
            }
        }
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
        // The live read may itself notify ShortcutService observers. This
        // service will publish this snapshot, so do not recursively probe it.
        let wasReadingSnapshot = isReadingSnapshot
        isReadingSnapshot = true
        shortcuts.refreshRegistration(registration)
        isReadingSnapshot = wasReadingSnapshot
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
            SetupRow(kind: .kde, status: isKDE ? probe.kdeStatus() : .notApplicable,
                registration: isKDE && registration.alternativeConfiguration != nil
                    ? HotkeyRegistration(id: registration.id, mechanism: registration.mechanism,
                        status: registration.status, detail: registration.detail,
                        configuration: registration.alternativeConfiguration) : nil),
        ])
    }

    private func hostSession(of session: DesktopSession) -> DesktopSession {
        if case .flatpak(let host) = session { return hostSession(of: host) }
        return session
    }
}
