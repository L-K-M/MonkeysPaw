import MonkeysPawCore

struct MacSessionProbe: SessionProbe {
    func currentSession() -> DesktopSession { .macOS }
}
