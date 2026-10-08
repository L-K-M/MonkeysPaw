/// A diagnostic must never turn a revoked restore token into a consent dialog.
public enum PasteConsent: Sendable { case userInitiated, existingSession }

public protocol PasteInjector {
    var backend: PasteBackend { get }

    /// Enqueue injection off the UI thread and return immediately (§4.2).
    /// Completion may run on any thread and must be called exactly once.
    /// The driver bounds its own waits and reports .failed(.timeout) on timeout;
    /// it must not also report a later result. .sent does not prove receipt (§6.5).
    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void)

    func paste(chord: PasteChord, consent: PasteConsent,
               completion: @escaping (PasteAttemptResult) -> Void)
}

public extension PasteInjector {
    /// Drivers without interactive session setup keep their existing behavior.
    func paste(chord: PasteChord, consent: PasteConsent,
               completion: @escaping (PasteAttemptResult) -> Void) {
        paste(chord: chord, completion: completion)
    }
}
