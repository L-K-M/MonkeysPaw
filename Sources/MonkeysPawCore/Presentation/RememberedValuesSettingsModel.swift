/// Settings → General (§5.4/§11.1). Construct, release and call intents on the
/// UI thread; state and onChange updates use the injected MainThread.
/// Views present native confirmation UI from state and forward its response.
public final class RememberedValuesSettingsModel {
    public enum Confirmation: Equatable, Sendable {
        case none
        case forgetAll
    }

    public struct State: Equatable, Sendable {
        public let confirmation: Confirmation
        public let lastOutcome: RememberedValuesOutcome?
        public var message: String? { lastOutcome.map(RememberedValuesStrings.message(for:)) }
    }

    /// One owner: the platform view. No picker observation or ownership.
    public var onChange: (() -> Void)?
    public private(set) var state = State(confirmation: .none, lastOutcome: nil)

    private let control: RememberedValuesControl
    private let mainThread: MainThread
    private var isForgetting = false

    public init(control: RememberedValuesControl, mainThread: MainThread) {
        self.control = control
        self.mainThread = mainThread
    }

    public func requestForgetAll() {
        mainThread.run {
            guard !self.isForgetting else { return }
            self.publish(confirmation: .forgetAll, outcome: nil)
        }
    }

    public func confirmForgetAll() {
        // Retain a confirmed mutation until it runs, even if Settings closes
        // before the platform main loop drains this intent.
        mainThread.run {
            guard self.state.confirmation == .forgetAll, !self.isForgetting else { return }
            // Forwarding can invoke picker/view callbacks inline. One native
            // confirmation must not trigger another reset through reentrancy.
            self.isForgetting = true
            let outcome = self.control.forgetAllValues()
            self.isForgetting = false
            self.publish(confirmation: .none, outcome: outcome)
        }
    }

    public func cancelForgetAll() {
        mainThread.run {
            guard self.state.confirmation == .forgetAll, !self.isForgetting else { return }
            self.publish(confirmation: .none, outcome: nil)
        }
    }

    private func publish(confirmation: Confirmation, outcome: RememberedValuesOutcome?) {
        let next = State(confirmation: confirmation, lastOutcome: outcome)
        guard next != state else { return }
        state = next
        onChange?()
    }
}
