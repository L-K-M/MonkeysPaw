import AppKit
import ApplicationServices
import MonkeysPawCore

final class MacSetupProbe: SetupProbe {
    private enum PromptState { case notRequested, requested }

    private let hotkeys: CarbonHotkeyBackend
    private let mainThread: MainThread
    private var promptState = PromptState.notRequested

    init(hotkeys: CarbonHotkeyBackend, mainThread: MainThread) {
        self.hotkeys = hotkeys
        self.mainThread = mainThread
    }

    func accessibilityStatus() -> SetupStatus {
        AXIsProcessTrusted() ? .ok : .needsAction(fix: Strings.accessibilityFix)
    }

    func portalStatus() -> SetupStatus { .notApplicable }
    func ydotoolStatus() -> SetupStatus { .notApplicable }
    func kdeStatus() -> SetupStatus { .notApplicable }

    func hotkeyRegistration() -> HotkeyRegistration {
        hotkeys.registration(for: .togglePicker)
    }

    func performFix(for kind: SetupRow.Kind, done: @escaping () -> Void) {
        mainThread.run { [self] in
            guard kind == .accessibility else {
                done()
                return
            }

            switch promptState {
            case .notRequested:
                promptState = .requested
                // Invoque uses this literal to avoid SDK variations in the imported constant.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .requested:
                // The system only shows its prompt once per run. A second Fix must
                // open Settings rather than silently reissuing that prompt.
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            done()
        }
    }
}
