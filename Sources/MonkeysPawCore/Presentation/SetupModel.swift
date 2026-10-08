/// Platform-neutral Setup state (§6.4). Intents enter on the UI thread.
public final class SetupModel {
    public enum State: Equatable {
        case idle
        case testing
        case tested(SelfTestReport)
    }

    public var onChange: (() -> Void)?
    public private(set) var state = State.idle
    public private(set) var session: DesktopSession?
    public private(set) var rows = SetupRow.Kind.allCases.map { SetupRow(kind: $0, status: .unknown) }

    private let setup: SetupService

    public init(setup: SetupService) {
        self.setup = setup
        setup.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public func refresh() {
        setup.refresh { [weak self] snapshot in
            guard let self else { return }
            self.session = snapshot.session
            self.rows = snapshot.rows
            self.onChange?()
        }
    }

    public func beginHotkeyVerification() {
        setup.beginHotkeyVerification()
    }

    public func runSelfTest() {
        guard state != .testing else { return }
        state = .testing
        onChange?()
        setup.runSelfTest { [weak self] report in
            guard let self else { return }
            self.state = .tested(report)
            self.refresh()
        }
    }
}
