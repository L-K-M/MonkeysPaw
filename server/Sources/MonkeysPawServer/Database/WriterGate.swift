/// Actor reentrancy alone does not serialize operations that suspend.
actor WriterGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }

        defer {
            if waiters.isEmpty {
                occupied = false
            } else {
                waiters.removeFirst().resume()
            }
        }

        try Task.checkCancellation()
        return try await operation()
    }
}
