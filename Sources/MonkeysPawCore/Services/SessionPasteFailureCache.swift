/// Share one instance across the process; settings and self-test can reset it.
public final class SessionPasteFailureCache: PasteFailureCache {
    private var failures: [PasteBackend: PasteFailure] = [:]

    public init() {}

    public func failure(for backend: PasteBackend) -> PasteFailure? {
        failures[backend]
    }

    public func record(_ reason: PasteFailure, for backend: PasteBackend) {
        failures[backend] = reason
    }

    public func reset() {
        failures.removeAll()
    }
}
