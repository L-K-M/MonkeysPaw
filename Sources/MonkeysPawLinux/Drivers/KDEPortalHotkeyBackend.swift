#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GLib owns selection, presence ordering and callback routing. The two drivers
/// share KDE's stored component, but only one may supply activation proof.
final class KDEPortalHotkeyBackend: LinuxHotkeyBackend {
    let unboundActions = UnboundHotkeyActions()
    private enum Effective { case none, native, portal }
    private enum Phase { case idle, busy, stopped }
    private(set) var mechanism = HotkeyMechanism.globalShortcutsPortal
    private(set) var activationRevision: UUID? = UUID()
    var onChange: (() -> Void)?
    var currentRegistration: HotkeyRegistration { registration(for: .togglePicker) }
    private var registrations: [HotkeyAction: HotkeyRegistration] = [
        .togglePicker: HotkeyRegistration(mechanism: .globalShortcutsPortal,
            status: .needsAction, detail: LinuxStrings.kdeRegistering),
    ]

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
    private var onFire: [HotkeyAction: () -> Void] = [:]
    private var accelerators: [HotkeyAction: Accelerator] = [:]
    private var baseline: KGlobalAccelHotkeyBackend.Snapshot?
    private var nativeLeases: [HotkeyAction: UUID] = [:]
    private var portalLeases: [HotkeyAction: UUID] = [:]
    private var tokenRevisions: [HotkeyAction: UUID] = [:]
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
        portal.beforeBind = { [weak self] previous, supplied, done in
            guard let self else { done(false); return }
            let operation = self.operation
            self.native.inspect(.setup) { [weak self] snapshot in
                guard let self, self.operation == operation, self.phase == .busy else { done(false); return }
                let catalogue = Set(supplied.compactMap { KGlobalAccelWire.action(for: $0.id) })
                let safe = previous.allSatisfy { KGlobalAccelWire.action(for: $0.id) != nil }
                    && self.baseline.map { Set($0.keys.keys).isSubset(of: catalogue) } == true
                    && self.preservesBaseline(snapshot)
                if !safe { self.storageDetail = LinuxStrings.kdeHandoffBlocked }
                done(safe)
            }
        }
    }

    deinit { shutdown() }

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard phase != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
        if self.onFire[action] != nil { unregister(registration(for: action)) }
        guard phase != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
        unboundActions.retire(action)
        self.onFire[action] = onFire
        accelerators[action] = accelerator
        registrations[action] = HotkeyRegistration(id: registrations[action]?.id ?? UUID(), mechanism: mechanism,
            status: .needsAction, detail: LinuxStrings.kdeRegistering)
        let lease = UUID()
        portalLeases[action] = lease
        _ = portal.register(action, accelerator: accelerator) { [weak self] in
            guard let self, self.portalLeases[action] == lease, self.effective == .portal else { return }
            self.tokenRevisions[action] = self.activationRevision
            self.onFire[action]?()
        }
        guard phase != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
        if self.onFire.count > 1 {
            if effective == .native { registerNativeAction(action) }
            else if effective == .portal { portalChanged() }
            else if phase == .idle { publishPortalOffer() }
            return registration(for: action)
        }
        startSelection()
        return registration(for: action)
    }

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        registrations[action] ?? unboundActions.registration(for: action,
            mechanism: registrations[.togglePicker]?.mechanism ?? .globalShortcutsPortal)
    }

    private func startSelection() {
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
                        if self.version == nil || snapshot == nil || snapshot?.keys.isEmpty == false {
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
    }

    func configure(done: @escaping () -> Void) {
        guard phase == .idle, !onFire.isEmpty else { done(); return }
        if version == nil, choice == .native { native.configure(done: done); return }
        if effective == .portal, portal.hasCompleteCatalogue {
            // v1 Bind opened settings already. Never Bind again on this session.
            if version == 1 { done(); return }
            portal.configure(done: done)
            return
        }
        begin(done)
        if effective == .portal { select(.none) }
        let operation = operation
        let deadline = ContinuousClock.now.advanced(by: consentBudget)
        portal.quiesce { [weak self] safe in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            guard safe || self.portal.canRecoverAfterOwnerLoss else { self.failClosed(LinuxStrings.kdeCleanupFailed); return }
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
            guard self.onFire.keys.allSatisfy({
                let status = self.portal.registration(for: $0).status
                return status == .registered || status == .unbound
            }) else {
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
        guard phase == .idle, !onFire.isEmpty else { done(); return }
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
        return baseline.keys.allSatisfy { snapshot.keys[$0.key] == $0.value }
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
        let operation = operation
        select(.native)
        for action in HotkeyAction.allCases where onFire[action] != nil && nativeLeases[action] == nil {
            guard phase == .busy, self.operation == operation else { return }
            registerNativeAction(action)
        }
        native.configure { [weak self] in
            guard let self, self.operation == operation, self.phase == .busy else { return }
            self.phase = .idle
            self.nativeChanged()
            self.finish()
        }
    }

    private func registerNativeAction(_ action: HotkeyAction) {
        let lease = UUID()
        nativeLeases[action] = lease
        _ = native.register(action, accelerator: accelerators[action]) { [weak self] in
            guard let self, self.nativeLeases[action] == lease, self.effective == .native else { return }
            self.onFire[action]?()
        }
    }

    private func nativeChanged() {
        if effective == .portal, native.currentRegistration.status == .failed
            || onFire.keys.contains(where: { native.registration(for: $0).status == .failed }) {
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
        for action in HotkeyAction.allCases where onFire[action] != nil {
            guard effective == .native else { return }
            publish(action, native.registration(for: action), configuration: version == nil ? .systemSettings : .attachPortal)
        }
    }

    private func portalChanged() {
        guard effective == .portal else { return }
        for action in HotkeyAction.allCases where onFire[action] != nil {
            guard effective == .portal else { return }
            publish(action, portal.registration(for: action), configuration: .systemSettings)
        }
    }

    private func publishPortalOffer() {
        for action in HotkeyAction.allCases where onFire[action] != nil {
            guard phase != .stopped else { return }
            publish(action, HotkeyRegistration(mechanism: .globalShortcutsPortal,
            status: version == nil ? .failed : .needsAction,
            detail: version == nil ? LinuxStrings.kdePortalUnavailable : LinuxStrings.shortcutAllow),
            configuration: .attachPortal)
        }
    }

    private func publish(_ action: HotkeyAction, _ registration: HotkeyRegistration, configuration: HotkeyConfiguration) {
        if effective == .none { mechanism = registration.mechanism }
        let previous = self.registration(for: action)
        if previous.mechanism != registration.mechanism || previous.status != registration.status || previous.detail != registration.detail {
            tokenRevisions.removeValue(forKey: action)
        }
        registrations[action] = HotkeyRegistration(id: self.registration(for: action).id, mechanism: registration.mechanism,
            status: storageDetail == nil ? registration.status : .failed,
            detail: storageDetail ?? registration.detail, configuration: configuration,
            alternativeConfiguration: .nativeFallback)
        onChange?()
    }

    private func select(_ effective: Effective) {
        self.effective = effective
        switch effective {
        case .native: mechanism = .kglobalaccel
        case .portal: mechanism = .globalShortcutsPortal
        case .none: break
        }
        activationRevision = UUID()
        tokenRevisions.removeAll()
        for action in HotkeyAction.allCases { _ = portal.consumeActivationToken(for: action) }
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
        for action in HotkeyAction.allCases where onFire[action] != nil {
            guard phase != .stopped else { return }
            registrations[action] = HotkeyRegistration(id: registration(for: action).id, mechanism: mechanism,
                status: .failed, detail: detail, configuration: .attachPortal, alternativeConfiguration: .nativeFallback)
        }
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
        consumeActivationToken(for: .togglePicker)
    }

    func consumeActivationToken(for action: HotkeyAction) -> String? {
        guard effective == .portal, tokenRevisions[action] == activationRevision else { return nil }
        tokenRevisions.removeValue(forKey: action)
        return portal.consumeActivationToken(for: action)
    }

    func fire(_ action: HotkeyAction) -> Bool { false }

    func unregister(_ registration: HotkeyRegistration) {
        guard phase != .stopped else { return }
        if unboundActions.unregister(registration) { return }
        guard let action = registrations.first(where: { $0.value.id == registration.id })?.key,
              onFire.removeValue(forKey: action) != nil else { return }
        accelerators.removeValue(forKey: action)
        nativeLeases.removeValue(forKey: action)
        portalLeases.removeValue(forKey: action)
        tokenRevisions.removeValue(forKey: action)
        native.unregister(native.registration(for: action))
        guard phase != .stopped else { return }
        portal.unregister(portal.registration(for: action))
        guard phase != .stopped else { return }
        registrations[action] = HotkeyRegistration(id: registration.id, mechanism: mechanism,
            status: .unbound, detail: SetupStrings.unboundShortcut, configuration: .unavailable)
        guard onFire.isEmpty else { return }
        operation += 1
        select(.none)
        phase = .idle
        finish()
    }

    func shutdown() {
        guard phase != .stopped else { return }
        phase = .stopped
        onFire.removeAll()
        accelerators.removeAll()
        operation += 1
        select(.none)
        onChange = nil
        native.shutdown()
        portal.shutdown()
        finish()
    }
}
#endif
