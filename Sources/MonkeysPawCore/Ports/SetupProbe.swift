/// Driver-owned permission and installation checks, with actionable fixes (§6.4).
public protocol SetupProbe {
    func accessibilityStatus() -> SetupStatus
    func portalStatus() -> SetupStatus
    func ydotoolStatus() -> SetupStatus
    func hotkeyRegistration() -> HotkeyRegistration
    func kdeStatus() -> SetupStatus
}
