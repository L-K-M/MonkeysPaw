/// Driver-owned permission and installation checks, with actionable fixes (§6.4).
public protocol SetupProbe {
    func accessibilityStatus() -> SetupStatus
    func portalStatus() -> SetupStatus
    func ydotoolStatus() -> SetupStatus
    func hotkeyRegistration() -> HotkeyRegistration
    func kdeStatus() -> SetupStatus

    /// Launch a nonblocking driver action: prompt, open settings, or show
    /// instructions (§6.4). Call done exactly once on any thread after the
    /// action is launched or finished. The driver must bound its own waits.
    func performFix(for kind: SetupRow.Kind, done: @escaping () -> Void)
}
