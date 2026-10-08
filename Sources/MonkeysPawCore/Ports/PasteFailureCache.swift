/// Process-lifetime failures, accessed on the injected MainThread (§6.3).
public protocol PasteFailureCache {
    func failure(for backend: PasteBackend) -> PasteFailure?
    func record(_ reason: PasteFailure, for backend: PasteBackend)
    func reset()
}
