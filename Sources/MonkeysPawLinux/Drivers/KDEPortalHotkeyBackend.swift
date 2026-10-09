#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GLib owns selection, presence ordering and callback routing. The two drivers
/// share KDE's stored component, but only one may supply activation proof.
final class KDEPortalHotkeyBackend: LinuxHotkeyBackend {
    private enum Effective { case none, native, portal }
    private enum Phase { case idle, busy, stopped }
    var mechanism: HotkeyMechanism { currentRegistration.mechanism }
    private(set) var activationRevision: UUID? = UUID()
    var onChange: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(mechanism: .globalShortcutsPortal,
        status: .needsAction, detail: LinuxStrings.kdeRegistering)

    private let native: KGlobalAccelHotkeyBackend
    private let portal: PortalHotkeyBackend
    private let transport: LinuxPortalTransport
    private let choices: KDEHotkeyChoiceStore
    private let consentBudget: Duration
    private var version: UInt32?
    private var effective = Effective.none
    private var phase = Phase.idle
    private var choice = KDEHotkeyChoice.portal
    private var operation = 0
    private var timer: guint = 0
    private var completion: (() -> Void)?
    private var onFire: (() -> Void)?
    private var accelerator: Accelerator?
    private var baseline: KGlobalAccelHotkeyBackend.Snapshot?
    private var nativeLease = UUID()
    private var portalLease = UUID()
    private var tokenRevision: UUID?
    private var storageDetail: String?

    init(native: KGlobalAccelHotkeyBackend, portal: PortalHotkeyBackend,
         transport: LinuxPortalTransport, choices: KDEHotkeyChoiceStore,
         consentBudget: Duration = Limits.portalConsentTimeout) {
        self.native = native
        self.portal = portal
        self.transport = transport
        self.choices = choices
        self.consentBudget = consentBudget
        native.onChange = { [weak self] in self?.nativeChanged() }
        portal.onChange = { [weak self] in self?.portalChanged() }
        portal.beforeBind = { [weak self] previous, done in
            guard let self else { done(false); return }
            let operation = self.operation
            self.native.inspect(.setup) { [weak self] snapshot in
                guard let self, self.operation == operation, self.phase == .busy else { done(false); return }
                let safe = previous.allSatisfy { $0.id == ActionName.toggle.rawValue }
                    && self.preservesBaseline(snapshot)
                if !safe { self.storageDetail = LinuxStrings.kdeHandoffBlocked }
                done(safe)
            }
        }
    }

    deinit { shutdown() }

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker else {
            return HotkeyRegistration(mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        guard phase != .stopped else { return currentRegistration }
        self.onFire = onFire
        self.accelerator = accelerator
        let lease = UUID()
        portalLease = lease
        _ = portal.register(action, accelerator: accelerator) { [weak self] in
            guard let self, self.portalLease == lease, self.effective == .portal else { return }
            self.tokenRevision = self.activationRevision
            self.onFire?()
        }
        operation += 1
        let operation = operation
        phase = .busy
        transport.call(.property(.globalShortcuts, .version),
            deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] result in
                guard let self, self.operation == operation, self.phase != .stopped else { return }
                if case .property(let version) = result, version >= 1 { self.version = version }
                else { self.version = nil }
                let preference = self.choices.load()
                switch preference {
                case .loaded(.portal):
                    self.choice = .portal
                    self.phase = .idle
                    self.publishPortalOffer()
                case .loaded(.native):
                    self.choice = .native
                    self.activateNative()
                case .absent, .corrupt, .unreadable:
                    if preference == .corrupt || preference == .unreadable {
                        self.storageDetail = LinuxStrings.kdeChoiceUnreadable
                    }
                    self.native.inspect { [weak self] snapshot in
                        guard let self, self.operation == operation, self.phase != .stopped else { return }
                        // Even unbound native rows are deliberate saved choices.
                        if self.version == nil || snapshot == nil || snapshot?.keys != nil {
                            self.choice = .native
                            self.activateNative()
                        } else {
                            self.choice = .portal
                            self.phase = .idle
                            self.publishPortalOffer()
                        }
                    }
                }
            }
        return currentRegistration
    }

    func configure(done: @escaping () -> Void) {
        guard phase == .idle, onFire != nil else { done(); return }
        if version == nil, choice == .native { native.configure(done: done); return }
        if effective == .portal, portal.isAttached {
            // v1 Bind opened settings already. Never Bind again on this session.
            if version == 1 { done(); return }
            portal.configure(done: done)
            return
        }
        begin(done)
        let operation = operation
        let deadline = ContinuousClock.now.advanced(by: consentBudget)
        portal.quiesce { [weak self] safe in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard safe else { self.failClosed(LinuxStrings.kdeCleanupFailed); return }
            self.portal.prepareAttachment { [weak self] version in
                guard let self, self.operation == operation, self.phase == .busy else { return }
                self.version = version
                guard version != nil else { self.reportFailure(LinuxStrings.kdePortalUnavailable); return }
                self.prepareHandoff(until: deadline, operation: operation)
            }
        }
    }

    private func prepareHandoff(until deadline: ContinuousClock.Instant, operation: Int) {
        native.inspect(.setup) { [weak self] snapshot in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard let snapshot, snapshot.supportsHandoff else {
                self.reportFailure(LinuxStrings.kdeHandoffBlocked)
                return
            }
            self.baseline = snapshot
            do { try self.choices.save(.portal) }
            catch { self.reportFailure(LinuxStrings.kdeChoiceSaveFailed); return }
            self.choice = .portal
            self.storageDetail = nil
            self.select(.none)
            self.suspendNative(until: deadline, operation: operation)
        }
    }

    private func suspendNative(until deadline: ContinuousClock.Instant, operation: Int) {
        native.suspend { [weak self] suspended in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard suspended else { self.failClosed(LinuxStrings.kdeCleanupFailed); return }
            self.native.inspect(.setup) { [weak self] snapshot in
                guard let self, self.operation == operation, self.phase == .busy else { return }
                guard self.preservesBaseline(snapshot) else { self.failClosed(LinuxStrings.kdeHandoffBlocked); return }
                self.attachPortal(until: deadline, operation: operation)
            }
        }
    }

    private func attachPortal(until deadline: ContinuousClock.Instant, operation: Int) {
        portal.configure(until: deadline) { [weak self] in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            let result = self.portal.currentRegistration
            guard result.status == .registered || result.status == .unbound else {
                self.failClosed(self.storageDetail ?? result.detail)
                return
            }
            self.native.inspect(.setup) { [weak self] snapshot in
                guard let self, self.operation == operation, self.phase == .busy else { return }
                guard self.preservesBaseline(snapshot) else { self.failClosed(LinuxStrings.kdeHandoffBlocked); return }
                self.select(.portal)
                self.phase = .idle
                self.portalChanged()
                self.finish()
            }
        }
    }

    /// Setup's KDE row always offers this intent, including a healthy hotkey.
    func configureNative(done: @escaping () -> Void) { useNative(done: done) }

    func useNative(done: @escaping () -> Void) {
        guard phase == .idle, onFire != nil else { done(); return }
        let wasNative = effective == .native
        begin(done)
        select(.none)
        let operation = operation
        portal.quiesce { [weak self] safe in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard safe else { self.failClosed(LinuxStrings.kdeCleanupFailed); return }
            do { try self.choices.save(.native) }
            catch { self.reportFailure(LinuxStrings.kdeChoiceSaveFailed); return }
            self.choice = .native
            self.storageDetail = nil
            if wasNative {
                self.select(.native)
                self.native.configure { [weak self] in
                    guard let self, self.operation == operation, self.phase == .busy else { return }
                    self.phase = .idle
                    self.nativeChanged()
                    self.finish()
                }
            } else { self.activateNative() }
        }
    }

    private func preservesBaseline(_ snapshot: KGlobalAccelHotkeyBackend.Snapshot?) -> Bool {
        guard let snapshot, snapshot.supportsHandoff, let baseline, snapshot.owner == baseline.owner else { return false }
        // A new action may appear on Bind. Existing assignments must survive
        // byte-for-byte, including empty alternatives and trailing zero chords.
        return baseline.keys == nil || snapshot.keys == baseline.keys
    }

    private func activateNative() {
        let operation = operation
        // Core can unregister/re-register while an earlier Close is pending.
        // Restart recovery must obey the same ordering as the Setup fallback.
        portal.quiesce { [weak self] safe in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard safe else { self.failClosed(LinuxStrings.kdeCleanupFailed); return }
            self.registerNative()
        }
    }

    private func registerNative() {
        guard let accelerator else { finish(); return }
        let operation = operation
        let lease = UUID()
        nativeLease = lease
        select(.native)
        _ = native.register(.togglePicker, accelerator: accelerator) { [weak self] in
            guard let self, self.nativeLease == lease, self.effective == .native else { return }
            self.onFire?()
        }
        native.configure { [weak self] in
            guard let self, self.operation == operation, self.phase == .busy, self.nativeLease == lease else { return }
            self.phase = .idle
            self.nativeChanged()
            self.finish()
        }
    }

    private func nativeChanged() {
        if effective == .portal, native.currentRegistration.status == .failed {
            // KGlobalAccel loss also invalidates the portal's shared component.
            // Gate now; let the native driver's current callback finish before
            // beginning acknowledged cleanup on either connection.
            select(.none)
            phase = .busy
            let operation = operation
            GTK.onMainLoop { [weak self] in
                guard let self, self.operation == operation,
                      self.phase == .busy, self.effective == .none else { return }
                self.failClosed(LinuxStrings.kdeLost)
            }
            return
        }
        guard effective == .native else { return }
        let registration = native.currentRegistration
        publish(registration, configuration: version == nil ? .systemSettings : .attachPortal)
    }

    private func portalChanged() {
        guard effective == .portal else { return }
        publish(portal.currentRegistration, configuration: .systemSettings)
    }

    private func publishPortalOffer() {
        publish(HotkeyRegistration(mechanism: .globalShortcutsPortal,
            status: version == nil ? .failed : .needsAction,
            detail: version == nil ? LinuxStrings.kdePortalUnavailable : LinuxStrings.shortcutAllow),
            configuration: .attachPortal)
    }

    private func publish(_ registration: HotkeyRegistration, configuration: HotkeyConfiguration) {
        if currentRegistration.mechanism != registration.mechanism
            || currentRegistration.status != registration.status || currentRegistration.detail != registration.detail {
            activationRevision = UUID()
            tokenRevision = nil
        }
        currentRegistration = HotkeyRegistration(id: currentRegistration.id, mechanism: registration.mechanism,
            status: storageDetail == nil ? registration.status : .failed,
            detail: storageDetail ?? registration.detail, configuration: configuration,
            alternativeConfiguration: .nativeFallback)
        onChange?()
    }

    private func select(_ effective: Effective) {
        self.effective = effective
        activationRevision = UUID()
        tokenRevision = nil
        _ = portal.consumeActivationToken()
    }

    private func begin(_ done: @escaping () -> Void) {
        phase = .busy
        operation += 1
        completion = done
        timer = GTK.after(consentBudget.timeInterval) { [weak self] in
            guard let self else { return }
            self.timer = 0
            self.failClosed(LinuxStrings.kdeCleanupFailed)
        }
    }

    private func reportFailure(_ detail: String) {
        publishFailure(detail)
        phase = .idle
        finish()
    }

    private func publishFailure(_ detail: String) {
        currentRegistration = HotkeyRegistration(id: currentRegistration.id, mechanism: mechanism,
            status: .failed, detail: detail, configuration: .attachPortal, alternativeConfiguration: .nativeFallback)
        onChange?()
    }

    private func failClosed(_ detail: String) {
        if timer != 0 { g_source_remove(timer); timer = 0 }
        operation += 1
        let operation = operation
        select(.none)
        publishFailure(detail)
        // Gate immediately and finish only after bounded cleanup. A late native
        // registration reply must not leave presence behind or start a peer.
        native.suspend { [weak self] suspended in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            self.portal.quiesce { [weak self] closed in
                guard let self, self.operation == operation, self.phase == .busy else { return }
                self.reportFailure(suspended && closed ? detail : LinuxStrings.kdeCleanupFailed)
            }
        }
    }

    private func finish() {
        if timer != 0 { g_source_remove(timer); timer = 0 }
        let done = completion
        completion = nil
        done?()
    }

    func consumeActivationToken() -> String? {
        guard effective == .portal, tokenRevision == activationRevision else { return nil }
        tokenRevision = nil
        return portal.consumeActivationToken()
    }

    func fire(_ action: HotkeyAction) -> Bool { false }

    func unregister(_ registration: HotkeyRegistration) {
        guard registration.id == currentRegistration.id else { return }
        onFire = nil
        operation += 1
        select(.none)
        native.unregister(native.currentRegistration)
        portal.quiesce { _ in }
        phase = .idle
        finish()
    }

    func shutdown() {
        guard phase != .stopped else { return }
        unregister(currentRegistration)
        phase = .stopped
        native.shutdown()
        portal.shutdown()
        onChange = nil
    }
}
#endif
