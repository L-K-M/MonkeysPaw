public protocol PasteInjector {
    var backend: PasteBackend { get }

    /// Enqueue injection off the UI thread and return immediately (§4.2).
    /// Completion may run on any thread; .sent does not prove receipt (§6.5).
    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void)
}
