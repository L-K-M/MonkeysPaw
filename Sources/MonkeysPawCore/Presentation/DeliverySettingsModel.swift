import Foundation

/// Construct, retire and release on the UI thread. Every intent and publication
/// uses MainThread; retired/released models drop queued work and late reports.
public final class DeliverySettingsModel {
    public enum TestState: Equatable, Sendable {
        case idle
        case testing
        case tested(SelfTestReport)
    }

    public struct State: Equatable, Sendable {
        public let preferences: DeliveryPreferences
        public let isReadOnly: Bool
        public let settingsError: SettingsError?
        public let delivery: DeliveryStatusSnapshot?
        public let permissionRows: [SetupRow]
        public let test: TestState
    }

    /// One owner: the platform view. Navigation requests its existing Setup window.
    public var onChange: (() -> Void)?
    public var onOpenSetup: (() -> Void)?
    public private(set) var state: State

    private let settings: SettingsModel
    private let delivery: DeliveryService
    private let setup: SetupService
    private let mainThread: MainThread
    private var settingsObserver: UUID?
    private var setupObserver: UUID?
    private var isActive = true
    private var status: DeliveryStatusSnapshot?
    private var permissionRows: [SetupRow] = []
    private var test = TestState.idle

    public init(settings: SettingsModel, delivery: DeliveryService,
                setup: SetupService, mainThread: MainThread) {
        self.settings = settings
        self.delivery = delivery
        self.setup = setup
        self.mainThread = mainThread
        state = State(preferences: settings.deliveryPreferences, isReadOnly: settings.isReadOnly,
            settingsError: settings.error, delivery: nil, permissionRows: [], test: .idle)
        settingsObserver = settings.addObserver { [weak self] _, _ in
            self?.mainThread.run { [weak self] in self?.publish() }
        }
        setupObserver = setup.addObserver { [weak self] snapshot in
            self?.updateStatus(from: snapshot)
        }
        refresh()
    }

    deinit { detachObservers() }

    /// Permanently retire a discarded model without stopping shared Setup work.
    public func retire() {
        isActive = false
        detachObservers()
        onChange = nil
        onOpenSetup = nil
    }

    public func setLinuxDefaultPasteChord(_ chord: PasteChord) {
        perform { $0.setLinuxDefaultPasteChord(chord) }
    }

    public func setClipboardRestore(_ mode: ClipboardRestoreMode) {
        perform { $0.setClipboardRestore(mode) }
    }

    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, self.isActive else { return }
            self.settings.refresh()
            self.publish()
            self.setup.refresh { _ in }
        }
    }

    public func openSetup() {
        mainThread.run { [weak self] in
            guard let self, self.isActive else { return }
            self.onOpenSetup?()
        }
    }

    public func runSelfTest() {
        mainThread.run { [weak self] in
            guard let self, self.isActive, self.test != .testing else { return }
            self.test = .testing
            self.publish()
            self.setup.runSelfTest { [weak self] report in
                self?.mainThread.run { [weak self] in
                    guard let self, self.isActive else { return }
                    self.test = .tested(report)
                    self.publish()
                    self.refresh()
                }
            }
        }
    }

    private func perform(_ intent: @escaping (SettingsModel) -> Void) {
        mainThread.run { [weak self] in
            guard let self, self.isActive else { return }
            intent(self.settings)
            self.publish()
        }
    }

    private func updateStatus(from snapshot: SetupSnapshot) {
        delivery.readStatus { [weak self] status in
            self?.mainThread.run { [weak self] in
                guard let self, self.isActive else { return }
                self.status = status
                // Shortcut and KDE assignment controls stay in Shortcuts/Setup.
                self.permissionRows = snapshot.rows.filter {
                    $0.kind == .accessibility || $0.kind == .portal || $0.kind == .ydotool
                }
                self.publish()
            }
        }
    }

    private func publish() {
        guard isActive else { return }
        let next = State(preferences: settings.deliveryPreferences, isReadOnly: settings.isReadOnly,
            settingsError: settings.error, delivery: status, permissionRows: permissionRows, test: test)
        guard next != state else { return }
        state = next
        onChange?()
    }

    private func detachObservers() {
        if let settingsObserver { settings.removeObserver(settingsObserver) }
        if let setupObserver { setup.removeObserver(setupObserver) }
        settingsObserver = nil
        setupObserver = nil
    }
}
