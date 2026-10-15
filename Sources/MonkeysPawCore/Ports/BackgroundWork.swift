import Foundation

/// Serial, nonblocking work away from the platform's UI thread (§4.2).
///
/// Drivers accept submissions from any thread and run them exactly once, in
/// submission order. A retiring driver must release work it will never run.
/// A serial dispatch queue is suitable on either desktop; Linux never hops
/// to the dispatch main queue. Services deliver results through MainThread.
/// Tests may execute inline or hold work until explicitly released.
public protocol BackgroundWork {
    func run(_ work: @escaping () -> Void)
}

extension BackgroundWork {
    /// Success proves earlier submissions finished. A rejected or discarded
    /// barrier throws CancellationError; callers must not replace or quit then.
    public func drainSubmittedWork() async throws {
        try await withCheckedThrowingContinuation { completion in
            let barrier = BackgroundWorkBarrier(completion)
            run { barrier.finish() }
        }
    }
}

private final class BackgroundWorkBarrier {
    private let lock = NSLock()
    private var completion: CheckedContinuation<Void, Error>?

    init(_ completion: CheckedContinuation<Void, Error>) { self.completion = completion }

    func finish() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?.resume()
    }

    deinit { completion?.resume(throwing: CancellationError()) }
}
