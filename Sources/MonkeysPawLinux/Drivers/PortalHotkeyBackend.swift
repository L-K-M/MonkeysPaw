#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Both actions share a connection/session, with independent registration ids.
final class PortalHotkeyBackend: LinuxHotkeyBackend {
    let unboundActions = UnboundHotkeyActions()
    private enum Selection: Equatable { case probing, portal(UInt32), fallback, stopped }
    private enum Teardown { case close, alreadyClosed, ownerLost }
    enum Migration { case gnomeHost, none }

    // Unlike handle_token, this identity remains stable across app runs (§6.3).
    static let sessionToken = "monkeyspaw_shortcuts"
    var mechanism: HotkeyMechanism { currentRegistration.mechanism }
    private(set) var activationRevision: UUID? = UUID()
    var onChange: (() -> Void)?
    var currentRegistration: HotkeyRegistration { registration(for: .togglePicker) }
    private var registrations: [HotkeyAction: HotkeyRegistration] = [
        .togglePicker: HotkeyRegistration(mechanism: .globalShortcutsPortal,
            status: .needsAction, detail: LinuxStrings.shortcutAllow),
    ]

    private let transport: LinuxPortalTransport
    private let fallback: LinuxHotkeyBackend
    private let installer: GnomeKeybindingInstaller
    private let migration: Migration
    private let mainThread: MainThread
    private let parent: PortalParentProvider
    private let worker = DispatchQueue(label: "ch.lkmc.monkeyspaw.portal-migration")
    private var selection = Selection.probing
    private var sessionHandle: String?
    private var observation: UUID?
    private var calls = Set<UUID>()
    private var revision = 0
    private var bindAttempted = false
    private var configuring = false
    private var watchdog: guint = 0
    private var configurationDone: (() -> Void)?
    private var onFire: [HotkeyAction: () -> Void] = [:]
    private var accelerators: [HotkeyAction: Accelerator] = [:]
    private var sessionActions = Set<HotkeyAction>()
    private var sessionShortcuts: [PortalShortcut] = []
    private var activationTokens: [HotkeyAction: String] = [:]
    private var tokenRevisions: [HotkeyAction: UUID] = [:]
    private var parentLease: PortalParent?
    private var creating = false
    private var uncertainCreation = false
    private enum Cleanup { case pending, failed, ownerLost }
    private struct Retirement {
        let id = UUID()
        var state: Cleanup
    }
    private var retiring: [String: Retirement] = [:]
    private var cleanupWaiters: [(Bool) -> Void] = []
    private var lastActivation: [HotkeyAction: UInt64] = [:]
    /// KDE rechecks owned daemon state after List and immediately before Bind.
    var beforeBind: (([PortalShortcut], @escaping (Bool) -> Void) -> Void)?

    /// Invalidate all callbacks/leases first, then wait for Session.Close.
    /// A failed Create may have loaded native actions without returning a handle.
    func quiesce(done: @escaping (Bool) -> Void) {
        guard selection != .stopped else { done(false); return }
        close(.close)
        completeConfiguration()
        guard selection != .stopped else { done(false); return }
        cleanupWaiters.append(done)
        for (session, entry) in retiring where entry.state != .pending { retire(session) }
        finishCleanup()
    }

    private func retire(_ session: String) {
        let entry = Retirement(state: .pending)
        retiring[session] = entry
        transport.closeSession(session, deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] outcome in
            guard let self, self.retiring[session]?.id == entry.id else { return }
            if outcome == .success { self.retiring.removeValue(forKey: session) }
            else { self.retiring[session]?.state = .failed }
            self.finishCleanup()
        }
    }

    private func finishCleanup() {
        guard !retiring.values.contains(where: { $0.state == .pending }) else { return }
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        waiters.forEach { $0(retiring.isEmpty && !uncertainCreation) }
    }

    init(transport: LinuxPortalTransport, fallback: LinuxHotkeyBackend,
         runner: LinuxToolRunner, migration: Migration, mainThread: MainThread,
         parent: @escaping PortalParentProvider) {
        self.transport = transport
        self.fallback = fallback
        installer = GnomeKeybindingInstaller(runner: runner)
        self.migration = migration
        self.mainThread = mainThread
        self.parent = parent
        observation = transport.observe { [weak self] in self?.signal($0) }
        fallback.onChange = { [weak self] in self?.fallbackChanged() }
    }

    deinit { shutdown() }

    func register(_ action: HotkeyAction, accelerator: Accelerator?,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard selection != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
        if self.onFire[action] != nil {
            close(.close)
            completeConfiguration()
            guard selection != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
            offerRegistration()
            guard selection != .stopped else { return unboundActions.registration(for: action, mechanism: mechanism) }
        }
        unboundActions.retire(action)
        self.onFire[action] = onFire
        accelerators[action] = accelerator
        registrations[action] = HotkeyRegistration(mechanism: .globalShortcutsPortal,
            status: accelerator == nil ? .unbound : .needsAction,
            detail: accelerator == nil ? SetupStrings.unboundShortcut : LinuxStrings.shortcutAllow)
        switch selection {
        case .probing where self.onFire.count == 1: probe()
        case .fallback: registerFallback(action)
        case .portal(let version) where isAttached && sessionActions.contains(action):
            apply(sessionShortcuts, version: version)
        default: break
        }
        return registration(for: action)
    }

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        registrations[action] ?? unboundActions.registration(for: action,
            mechanism: registrations[.togglePicker]?.mechanism ?? .globalShortcutsPortal)
    }

    private func offerRegistration() {
        for action in HotkeyAction.allCases where onFire[action] != nil {
            let unbound = accelerators[action] == nil
            update(action, unbound ? .unbound : .needsAction,
                   unbound ? SetupStrings.unboundShortcut : LinuxStrings.shortcutAllow)
        }
        onChange?()
    }

    /// Probing never binds, creates sessions or reads/writes gsettings.
    private func probe(done: (() -> Void)? = nil) {
        guard selection != .stopped else { done?(); return }
        revision += 1
        let revision = revision
        selection = .probing
        calls.insert(transport.call(.property(.globalShortcuts, .version),
            deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] result in
                guard let self, self.revision == revision, !self.onFire.isEmpty else { return }
                switch result {
                case .property(let version) where version >= 1:
                    self.selection = .portal(version)
                    self.offerRegistration()
                case .property, .failed(.unavailable), .failed(.busFailure), .failed(.timedOut):
                    self.selection = .fallback
                    self.registerFallback()
                default:
                    self.selection = .portal(1)
                    self.update(.failed, LinuxStrings.shortcutSessionLost)
                }
                guard self.revision == revision, self.selection != .stopped else { return }
                done?()
            })
    }

    private func registerFallback() {
        for action in HotkeyAction.allCases where onFire[action] != nil { registerFallback(action) }
    }

    private func registerFallback(_ action: HotkeyAction) {
        _ = fallback.register(action, accelerator: accelerators[action]) { [weak self] in
            guard let self, self.selection == .fallback else { return }
            self.onFire[action]?()
        }
        fallbackChanged()
    }

    private func fallbackChanged() {
        guard case .fallback = selection else { return }
        for action in HotkeyAction.allCases where onFire[action] != nil {
            let registration = fallback.registration(for: action)
            registrations[action] = HotkeyRegistration(id: self.registration(for: action).id,
                mechanism: registration.mechanism, status: registration.status, detail: registration.detail,
                configuration: registration.configuration, alternativeConfiguration: registration.alternativeConfiguration)
        }
        onChange?()
    }

    var isAttached: Bool { sessionHandle != nil && bindAttempted }

    /// A KDE retry rechecks capability without attaching a session. The caller
    /// has already acknowledged old-session cleanup before invoking this seam.
    func prepareAttachment(done: @escaping (UInt32?) -> Void) {
        guard selection != .stopped, !configuring, !isAttached, !onFire.isEmpty else { done(nil); return }
        probe { [weak self] in
            if let self, case .portal(let version) = self.selection { done(version) }
            else { done(nil) }
        }
    }

    func configure(done: @escaping () -> Void) {
        configure(until: ContinuousClock.now.advanced(by: Limits.portalConsentTimeout), done: done)
    }

    func configure(until deadline: ContinuousClock.Instant, done: @escaping () -> Void) {
        guard selection != .stopped, !configuring, !onFire.isEmpty else { done(); return }
        switch selection {
        case .probing:
            configuring = true
            configurationDone = done
            probe { [weak self] in
                guard let self else { return }
                self.configuring = false
                self.configurationDone = nil
                self.configure(until: deadline, done: done)
            }
        case .fallback:
            fallback.configure(done: done)
        case .portal(let version):
            configuring = true
            configurationDone = done
            watchdog = GTK.after(max(0, ContinuousClock.now.duration(to: deadline).timeInterval)) { [weak self] in
                guard let self else { return }
                self.watchdog = 0
                self.failed(.timedOut)
            }
            if let sessionHandle, bindAttempted, Set(onFire.keys).isSubset(of: sessionActions) {
                // v1 already opened desktop settings. A complete attached
                // catalogue never gets another Bind or a replacement session.
                guard version >= 2 else { completeConfiguration(); return }
                let revision = revision
                parent { [weak self] parent in
                    guard let self, self.revision == revision, self.configuring else { parent.close(); return }
                    self.parentLease = parent
                    self.calls.insert(self.transport.call(.configureShortcuts(session: sessionHandle, parent: parent.identifier),
                        deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] result in
                            guard let self, self.revision == revision, self.configuring else { return }
                            if result != .success { self.update(.failed, LinuxStrings.shortcutSessionLost) }
                            guard self.revision == revision, self.configuring else { return }
                            self.completeConfiguration()
                        })
                }
                return
            }
            close(.close)
            guard selection != .stopped else { completeConfiguration(); return }
            // close only tears down the old session; this explicit gesture owns
            // the new consent and never automatically installs another mechanism.
            configuring = true
            configurationDone = done
            let revision = revision
            cleanupWaiters.append { [weak self] safe in
                guard let self, self.revision == revision, self.configuring else { return }
                // A replacement portal owner cannot close the departed owner's
                // sessions. Explicit attachment may retry; native quiescence
                // still treats those sessions as uncertain.
                guard safe || (!self.uncertainCreation && self.retiring.values.allSatisfy({ $0.state == .ownerLost }))
                else { self.failed(.methodError); return }
                self.migrate(deadline: deadline, version: version)
            }
            for (session, entry) in retiring where entry.state == .failed { retire(session) }
            finishCleanup()
        case .stopped: done()
        }
    }

    private func migrate(deadline: ContinuousClock.Instant, version: UInt32) {
        guard migration == .gnomeHost else { create(deadline: deadline, version: version); return }
        let revision = revision
        worker.async {
            let migration = self.installer.prepareForPortal(deadline: deadline)
            self.mainThread.run {
                guard self.revision == revision, self.configuring else { return }
                switch migration {
                case .ready: self.create(deadline: deadline, version: version)
                case .editedBinding:
                    self.update(.needsAction, LinuxStrings.shortcutMigrationBlocked)
                    guard self.revision == revision, self.configuring else { return }
                    self.completeConfiguration()
                case .unavailable:
                    self.update(.failed, LinuxStrings.shortcutMigrationFailed)
                    guard self.revision == revision, self.configuring else { return }
                    self.completeConfiguration()
                }
            }
        }
    }

    private func create(deadline: ContinuousClock.Instant, version: UInt32) {
        let revision = revision
        creating = true
        calls.insert(transport.request(interface: .globalShortcuts, method: "CreateSession",
            options: ["session_handle_token": .string(Self.sessionToken)], deadline: ipcDeadline(deadline)) { [weak self] result in
                guard let self, self.revision == revision, self.configuring else { return }
                guard case .success(let response) = result, let session = response.sessionHandle else {
                    // A terminal refusal confirms that no session was created;
                    // a timeout or malformed success still has uncertain effects.
                    if result == .cancelled || result == .denied { self.creating = false }
                    self.failed(result)
                    return
                }
                self.creating = false
                self.sessionHandle = session
                self.calls.insert(self.transport.request(interface: .globalShortcuts, method: "ListShortcuts",
                    arguments: [.objectPath(session)], deadline: self.ipcDeadline(deadline)) { [weak self] result in
                        guard let self, self.revision == revision, self.configuring else { return }
                        guard case .success(let response) = result, let shortcuts = response.shortcuts else {
                            self.failed(result)
                            return
                        }
                        self.bind(session: session, previous: shortcuts, deadline: deadline, version: version)
                    })
            })
    }

    private func bind(session: String, previous: [PortalShortcut],
                      deadline: ContinuousClock.Instant, version: UInt32) {
        guard !bindAttempted else {
            failed(.invalidArguments)
            return
        }
        let revision = revision
        var shortcuts: [PortalShortcut] = []
        // Include saved owned actions even if a caller has not declared their
        // callback yet: omitted actions can be deleted by a portal backend.
        for action in HotkeyAction.allCases {
            let id = Self.shortcutID(action)
            let saved = previous.first { $0.id == id }
            guard onFire[action] != nil || saved != nil else { continue }
            var properties = ["description": action == .togglePicker ? "Open Monkey's Paw" : "Repeat last prompt"]
            if let saved {
                if let description = saved.properties["trigger_description"], !description.isEmpty {
                    update(action, .needsAction, "Previously selected: " + description + ". " + LinuxStrings.shortcutAllow)
                }
            } else if action == .togglePicker, let accelerator = accelerators[action] {
                guard let trigger = Self.trigger(accelerator) else { failed(.invalidArguments); return }
                properties["preferred_trigger"] = trigger
            }
            shortcuts.append(PortalShortcut(id: id, properties: properties))
        }
        onChange?()
        guard self.revision == revision, configuring else { return }
        parent { [weak self] parent in
            guard let self, self.revision == revision, self.configuring else { parent.close(); return }
            self.parentLease = parent
            let send: (Bool) -> Void = { [weak self] allowed in
                guard let self, self.revision == revision, self.configuring, !self.bindAttempted else { return }
                guard allowed else { self.failed(.invalidArguments); return }
                self.bindAttempted = true
                self.sessionActions = Set(shortcuts.compactMap { Self.action(for: $0.id) })
                self.calls.insert(self.transport.request(interface: .globalShortcuts, method: "BindShortcuts",
                    arguments: [.objectPath(session), .shortcuts(shortcuts),
                        .string(parent.identifier)], deadline: deadline) { [weak self] result in
                            guard let self, self.revision == revision, self.configuring else { return }
                            guard case .success(let response) = result, let shortcuts = response.shortcuts else {
                                self.failed(result)
                                return
                            }
                            self.apply(shortcuts, version: version)
                            guard self.revision == revision, self.configuring else { return }
                            self.completeConfiguration()
                        })
            }
            // A Wayland export may finish much later than List. Recheck the
            // shared KDE component after that wait, immediately before Bind.
            if let beforeBind = self.beforeBind { beforeBind(previous, send) }
            else { send(true) }
        }
    }

    private func failed(_ result: PortalRequestOutcome) {
        let detail = result == .cancelled || result == .denied
            ? LinuxStrings.shortcutCancelled : LinuxStrings.shortcutSessionLost
        let interactionStarted = bindAttempted
        close(.close)
        let revision = revision
        if !interactionStarted, result == .unavailable || result == .busFailure {
            // Capability can vanish between the probe and session setup. Offer
            // the fallback's explicit Setup action; do not install it here.
            selection = .fallback
            registerFallback()
        } else { update(.failed, detail) }
        guard self.revision == revision, selection != .stopped else { return }
        completeConfiguration()
    }

    private func apply(_ shortcuts: [PortalShortcut], version: UInt32) {
        sessionShortcuts = shortcuts
        for action in HotkeyAction.allCases where onFire[action] != nil {
            let trigger = sessionActions.contains(action)
                ? shortcuts.first { $0.id == Self.shortcutID(action) }?.properties["trigger_description"] : nil
            let bound = trigger?.isEmpty == false
            update(action, bound ? .registered : .unbound, bound ? trigger! : SetupStrings.unboundShortcut,
                   configuration: version >= 2 ? .systemSettings : nil)
            if !bound { invalidateToken(action) }
        }
        onChange?()
    }

    private func update(_ status: RegistrationStatus, _ detail: String,
                        configuration: HotkeyConfiguration? = nil) {
        for action in HotkeyAction.allCases where onFire[action] != nil {
            update(action, status, detail, configuration: configuration)
        }
        onChange?()
    }

    private func update(_ action: HotkeyAction, _ status: RegistrationStatus, _ detail: String,
                        configuration: HotkeyConfiguration? = nil) {
        registrations[action] = HotkeyRegistration(id: registration(for: action).id,
            mechanism: .globalShortcutsPortal, status: status, detail: detail, configuration: configuration)
    }

    private func signal(_ signal: PortalSignal) {
        switch signal {
        case .activated(let session, let id, let timestamp, let token):
            guard session == sessionHandle, let action = Self.action(for: id), bindAttempted,
                  sessionActions.contains(action), registration(for: action).status == .registered,
                  let onFire = onFire[action], lastActivation[action] != timestamp else { return }
            lastActivation[action] = timestamp
            activationTokens[action] = token
            let tokenRevision = UUID()
            tokenRevisions[action] = tokenRevision
            onFire()
            // ShortcutService marshals its callback through MainThread first.
            // Clear an unconsumed token after that hop (e.g. a debounced toggle).
            GTK.onMainLoop { [weak self] in
                guard let self, self.tokenRevisions[action] == tokenRevision else { return }
                self.invalidateToken(action)
            }
        case .shortcutsChanged(let session, let shortcuts):
            guard session == sessionHandle, bindAttempted, case .portal(let version) = selection else { return }
            apply(shortcuts, version: version)
        case .closed(let session) where session == sessionHandle:
            close(.alreadyClosed)
            let revision = revision
            update(.failed, LinuxStrings.shortcutSessionLost)
            guard self.revision == revision, selection != .stopped else { return }
            completeConfiguration()
        case .lost:
            guard case .portal = selection else { return }
            close(.ownerLost)
            let revision = revision
            update(.failed, LinuxStrings.shortcutSessionLost)
            guard self.revision == revision, selection != .stopped else { return }
            completeConfiguration()
        default: break
        }
    }

    func consumeActivationToken() -> String? {
        consumeActivationToken(for: .togglePicker)
    }

    func consumeActivationToken(for action: HotkeyAction) -> String? {
        defer { invalidateToken(action) }
        return activationTokens[action]
    }

    private func invalidateToken(_ action: HotkeyAction) {
        activationTokens.removeValue(forKey: action)
        tokenRevisions.removeValue(forKey: action)
    }

    /// A manual action opens the panel through LinuxEnvironment, but it cannot
    /// manufacture portal verification or a portal activation token.
    func fire(_ action: HotkeyAction) -> Bool {
        guard case .fallback = selection else { return false }
        return fallback.fire(action)
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard selection != .stopped else { return }
        if unboundActions.unregister(registration) { return }
        guard let action = registrations.first(where: { $0.value.id == registration.id })?.key else { return }
        onFire.removeValue(forKey: action)
        accelerators.removeValue(forKey: action)
        lastActivation.removeValue(forKey: action)
        invalidateToken(action)
        fallback.unregister(fallback.registration(for: action))
        update(action, .unbound, SetupStrings.unboundShortcut, configuration: .unavailable)
        if onFire.isEmpty {
            close(.close)
            completeConfiguration()
        }
    }

    func shutdown() {
        guard selection != .stopped else { return }
        selection = .stopped
        onFire.removeAll()
        accelerators.removeAll()
        if let observation { transport.removeObserver(observation); self.observation = nil }
        fallback.shutdown()
        close(.close)
        completeConfiguration()
    }

    private func close(_ mode: Teardown) {
        // A native parent export may complete after teardown and a new gesture.
        // Invalidate that continuation before the next session can start.
        revision += 1
        activationRevision = UUID()
        let ids = calls
        calls.removeAll()
        // Disable continuations before cancelling their native waits.
        let wasConfiguring = configuring
        configuring = false
        for id in ids { transport.cancel(id) }
        configuring = wasConfiguring
        if creating { uncertainCreation = true; creating = false }
        if let sessionHandle {
            if mode == .close { retire(sessionHandle) }
            else if mode == .ownerLost { retiring[sessionHandle] = Retirement(state: .ownerLost) }
            else { retiring.removeValue(forKey: sessionHandle) }
        }
        sessionHandle = nil
        // Deduplication belongs to the retired session, even if its path is reused.
        lastActivation.removeAll()
        activationTokens.removeAll()
        tokenRevisions.removeAll()
        sessionActions.removeAll()
        sessionShortcuts.removeAll()
        bindAttempted = false
        parentLease?.close()
        parentLease = nil
    }

    private func completeConfiguration() {
        configuring = false
        if watchdog != 0 { g_source_remove(watchdog); watchdog = 0 }
        parentLease?.close()
        parentLease = nil
        let done = configurationDone
        configurationDone = nil
        done?()
    }

    private func ipcDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(deadline, ContinuousClock.now.advanced(by: Limits.portalCallTimeout))
    }

    private static func shortcutID(_ action: HotkeyAction) -> String {
        action == .togglePicker ? ActionName.toggle.rawValue : "repeat"
    }

    private static func action(for id: String) -> HotkeyAction? {
        HotkeyAction.allCases.first { shortcutID($0) == id }
    }

    private static func trigger(_ accelerator: Accelerator) -> String? {
        guard (try? accelerator.gtkAccelerator()) != nil else { return nil }
        var parts: [String] = []
        if accelerator.modifiers.contains(.control) || accelerator.modifiers.contains(.commandOrControl) { parts.append("CTRL") }
        if accelerator.modifiers.contains(.alt) { parts.append("ALT") }
        if accelerator.modifiers.contains(.shift) { parts.append("SHIFT") }
        if accelerator.modifiers.contains(.superKey) || accelerator.modifiers.contains(.command) { parts.append("LOGO") }
        switch accelerator.key {
        case .character(let key): parts.append(String(key))
        case .function(let number): parts.append("F\(number)")
        case .named(let key): parts.append(key.rawValue)
        }
        return parts.joined(separator: "+")
    }
}
#endif
