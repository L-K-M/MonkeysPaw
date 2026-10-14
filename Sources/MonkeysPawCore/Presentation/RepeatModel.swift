import Foundation

/// Views forward repeat/load intents and render typed results. Hidden picker
/// drafts remain owned by PickerModel; this model never opens or resets it.
public final class RepeatModel: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, loading, repeating, inactive }

    public var onChange: (() -> Void)?
    public private(set) var state = State.idle
    public private(set) var availability = RepeatAvailability.nothingToRepeat
    public private(set) var result: RepeatResult?

    private let service: RepeatService
    private let main: MainThread
    private var observer: UUID?
    private var generation: UInt64 = 0

    public init(service: RepeatService, main: MainThread) {
        self.service = service
        self.main = main
        observer = service.addObserver { [weak self] availability in
            self?.main.run { [weak self] in
                guard let self, self.state != .inactive else { return }
                self.availability = availability
                self.onChange?()
            }
        }
    }

    deinit { if let observer { service.removeObserver(observer) } }

    public func load() {
        guard state == .idle else { return }
        state = .loading
        let generation = self.generation
        onChange?()
        service.load { [weak self] availability in
            guard let self, self.generation == generation, self.state == .loading else { return }
            self.availability = availability
            self.state = .idle
            self.onChange?()
        }
    }

    public func repeatLast() {
        guard state == .idle else { return }
        state = .repeating
        result = nil
        let generation = self.generation
        onChange?()
        let accepted = service.repeatLast { [weak self] result in
            guard let self, self.generation == generation, self.state == .repeating else { return }
            self.result = result
            self.availability = self.service.availability
            self.state = .idle
            self.onChange?()
        }
        if !accepted { state = .idle; onChange?() }
    }

    /// Composition retires the service durably before replacing its graph.
    /// Deactivation only withdraws this model's callbacks and current repeat.
    public func deactivate() {
        let wasRepeating = state == .repeating
        generation &+= 1
        state = .inactive
        if let observer { service.removeObserver(observer); self.observer = nil }
        if wasRepeating { service.cancel() }
        onChange = nil
    }
}
