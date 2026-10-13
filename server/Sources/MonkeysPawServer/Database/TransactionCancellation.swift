import Foundation

/// Fluent's future bridge starts another task; carry caller cancellation across it.
/// The lock protects the sole mutable value from the synchronous cancellation handler.
final class TransactionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
