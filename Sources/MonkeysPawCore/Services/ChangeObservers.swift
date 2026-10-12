import Foundation

/// Small shared registry for service notifications. Capture membership at
/// commit, then deliver without a service or registry lock. Removal cancels
/// callbacks not yet taken for invocation; an invocation in progress may finish.
final class ChangeObservers {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var order: [UUID] = []

    func add(_ callback: @escaping @Sendable () -> Void) -> UUID {
        locked {
            let token = UUID()
            callbacks[token] = callback
            order.append(token)
            return token
        }
    }

    func remove(_ token: UUID) {
        locked {
            callbacks[token] = nil
            order.removeAll { $0 == token }
        }
    }

    func capture() -> [UUID] { locked { order } }

    func publish(_ tokens: [UUID]) {
        for token in tokens {
            let callback = locked { callbacks[token] }
            callback?()
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
