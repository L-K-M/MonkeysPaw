import Foundation

/// Small shared registry for service notifications. Capture membership at
/// commit, then deliver without a service or registry lock. Removal cancels
/// callbacks not yet taken for invocation; an invocation in progress may finish.
final class ChangeObservers<Event> {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable (Event) -> Void] = [:]
    private var order: [UUID] = []

    func add(_ callback: @escaping @Sendable (Event) -> Void) -> UUID {
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

    func publish(_ tokens: [UUID], event: Event) {
        for token in tokens {
            let callback = locked { callbacks[token] }
            callback?(event)
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

extension ChangeObservers where Event == Void {
    func add(_ callback: @escaping @Sendable () -> Void) -> UUID { add { _ in callback() } }
    func publish(_ tokens: [UUID]) { publish(tokens, event: ()) }
}
