/// M1's canned picker. Call intents on the UI thread; service callbacks return
/// through MainThread, and the front end republishes onChange (§4.2).
public final class PanelModel {
    public enum State: Equatable {
        case idle
        case delivering
        case done(DeliveryOutcome)
    }

    /// This hook has one owner, the front end's view.
    /// Assignment replaces the previous callback.
    public var onChange: (() -> Void)?
    public private(set) var state = State.idle
    public var prompt: String { DeliveryStrings.testPrompt }

    private let delivery: DeliveryService

    public init(delivery: DeliveryService) { self.delivery = delivery }

    public func show() {
        guard state != .delivering else { return }
        state = .idle
        delivery.show()
        onChange?()
    }

    public func confirm(mode: DeliveryMode) {
        guard state == .idle else { return }
        state = .delivering
        onChange?()
        delivery.deliver(prompt, mode: mode) { [weak self] outcome in
            guard let self else { return }
            self.state = .done(outcome)
            self.onChange?()
        }
    }

    public func cancel() {
        guard state != .delivering else { return }
        // Dismissal's frontmost check belongs to the focus driver (§4.6).
        delivery.dismiss()
        state = .idle
        onChange?()
    }
}
