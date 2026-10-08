import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MonkeysPawCore

final class CGEventPasteInjector: PasteInjector {
    let backend = PasteBackend.cgEvent

    struct EventPair {
        let down: CGEvent
        let up: CGEvent
    }

    private let worker = DispatchQueue(label: "ch.lkmc.MonkeysPaw.cgEvent", qos: .userInitiated)
    private let isTrusted: () -> Bool
    private let post: (CGEvent) -> Void

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.isTrusted = isTrusted
        self.post = post
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        worker.async { [self] in
            // Check on every attempt; an app update can invalidate the AX grant.
            guard isTrusted() else {
                completion(.failed(.permissionDenied))
                return
            }
            guard let pair = Self.makeEventPair() else {
                completion(.failed(.backendUnavailable))
                return
            }

            // Both macOS chords use Cmd+V, including Terminal (§6.3).
            // The only wait is this bounded gap; no UI thread waits for injection.
            post(pair.down)
            Thread.sleep(forTimeInterval: Limits.cgEventPairGap.timeInterval)
            post(pair.up)
            completion(.sent)
        }
    }

    /// Construction is separate from posting so hosted tests send no real keys.
    static func makeEventPair() -> EventPair? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return nil }

        down.flags = .maskCommand
        up.flags = .maskCommand
        return EventPair(down: down, up: up)
    }
}
