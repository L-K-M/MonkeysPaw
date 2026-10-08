#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GNOME capability selection and both portal registration phases share one id.
final class PortalHotkeyBackend: LinuxHotkeyBackend {
    private enum Selection { case probing, portal(UInt32), fallback, stopped }
    private enum Teardown { case close, alreadyClosed }
    enum Migration { case gnomeHost, none }

    // Unlike handle_token, this identity remains stable across app runs (§6.3).
    static let sessionToken = "monkeyspaw_shortcuts"
    var mechanism: HotkeyMechanism { currentRegistration.mechanism }
    var onChange: (() -> Void)?
    private(set) var currentRegistration = HotkeyRegistration(
        mechanism: .globalShortcutsPortal, status: .needsAction, detail: LinuxStrings.shortcutAllow)

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
    private var onFire: (() -> Void)?
    private var accelerator: Accelerator?
    private var activationToken: String?
    private var activationRevision = 0
    private var parentLease: PortalParent?

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

    func register(_ action: HotkeyAction, accelerator: Accelerator,
                  onFire: @escaping () -> Void) -> HotkeyRegistration {
        guard action == .togglePicker else {
            return HotkeyRegistration(mechanism: mechanism, status: .unbound, detail: SetupStrings.unboundShortcut)
        }
        close(.close)
        completeConfiguration()
        self.onFire = onFire
        self.accelerator = accelerator
        currentRegistration = HotkeyRegistration(mechanism: .globalShortcutsPortal, status: .needsAction,
                                                 detail: LinuxStrings.shortcutAllow)
        probe()
        return currentRegistration
    }

    /// Probing never binds, creates sessions or reads/writes gsettings.
    private func probe(done: (() -> Void)? = nil) {
        revision += 1
        let revision = revision
        selection = .probing
        calls.insert(transport.call(.property(.globalShortcuts, .version),
            deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] result in
                guard let self, self.revision == revision, self.onFire != nil else { return }
                switch result {
                case .property(let version) where version >= 1:
                    self.selection = .portal(version)
                    self.update(.needsAction, LinuxStrings.shortcutAllow)
                case .property, .failed(.unavailable), .failed(.busFailure), .failed(.timedOut):
                    self.selection = .fallback
                    self.registerFallback()
                default:
                    self.selection = .portal(1)
                    self.update(.failed, LinuxStrings.shortcutSessionLost)
                }
                done?()
            })
    }

    private func registerFallback() {
        guard let accelerator else { return }
        _ = fallback.register(.togglePicker, accelerator: accelerator) { [weak self] in self?.onFire?() }
        fallbackChanged()
    }

    private func fallbackChanged() {
        guard case .fallback = selection else { return }
        let registration = fallback.currentRegistration
        currentRegistration = HotkeyRegistration(id: currentRegistration.id,
            mechanism: registration.mechanism, status: registration.status, detail: registration.detail)
        onChange?()
    }

    func configure(done: @escaping () -> Void) {
        guard !configuring, onFire != nil else { done(); return }
        switch selection {
        case .probing:
            configuring = true
            configurationDone = done
            probe { [weak self] in
                guard let self else { return }
                self.configuring = false
                self.configurationDone = nil
                self.configure(done: done)
            }
        case .fallback:
            fallback.configure(done: done)
        case .portal(let version):
            configuring = true
            configurationDone = done
            let deadline = ContinuousClock.now.advanced(by: Limits.portalConsentTimeout)
            watchdog = GTK.after(Limits.portalConsentTimeout.timeInterval) { [weak self] in
                guard let self else { return }
                self.watchdog = 0
                self.failed(.timedOut)
            }
            if let sessionHandle, bindAttempted, version >= 2 {
                let revision = revision
                parent { [weak self] parent in
                    guard let self, self.revision == revision, self.configuring else { parent.close(); return }
                    self.parentLease = parent
                    self.calls.insert(self.transport.call(.configureShortcuts(session: sessionHandle, parent: parent.identifier),
                        deadline: ContinuousClock.now.advanced(by: Limits.portalCallTimeout)) { [weak self] result in
                            guard let self, self.revision == revision, self.configuring else { return }
                            if result != .success { self.update(.failed, LinuxStrings.shortcutSessionLost) }
                            self.completeConfiguration()
                        })
                }
                return
            }
            close(.close)
            // close only tears down the old session; this explicit gesture owns
            // the new consent and never automatically installs another mechanism.
            configuring = true
            configurationDone = done
            migrate(deadline: deadline, version: version)
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
                    self.completeConfiguration()
                case .unavailable:
                    self.update(.failed, LinuxStrings.shortcutMigrationFailed)
                    self.completeConfiguration()
                }
            }
        }
    }

    private func create(deadline: ContinuousClock.Instant, version: UInt32) {
        let revision = revision
        calls.insert(transport.request(interface: .globalShortcuts, method: "CreateSession",
            options: ["session_handle_token": .string(Self.sessionToken)], deadline: ipcDeadline(deadline)) { [weak self] result in
                guard let self, self.revision == revision, self.configuring else { return }
                guard case .success(let response) = result, let session = response.sessionHandle else {
                    self.failed(result)
                    return
                }
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
        guard !bindAttempted, let accelerator, let trigger = Self.trigger(accelerator) else {
            failed(.invalidArguments)
            return
        }
        var properties = ["description": "Open Monkey's Paw"]
        if let saved = previous.first(where: { $0.id == ActionName.toggle.rawValue }) {
            if let description = saved.properties["trigger_description"], !description.isEmpty {
                update(.needsAction, "Previously selected: " + description + ". " + LinuxStrings.shortcutAllow)
            }
        } else { properties["preferred_trigger"] = trigger }
        let revision = revision
        parent { [weak self] parent in
            guard let self, self.revision == revision, self.configuring else { parent.close(); return }
            self.parentLease = parent
            self.bindAttempted = true
            self.calls.insert(self.transport.request(interface: .globalShortcuts, method: "BindShortcuts",
                arguments: [.objectPath(session), .shortcuts([PortalShortcut(id: ActionName.toggle.rawValue,
                    properties: properties)]),
                    .string(parent.identifier)], deadline: deadline) { [weak self] result in
                        guard let self, self.revision == revision, self.configuring else { return }
                        guard case .success(let response) = result, let shortcuts = response.shortcuts else {
                            self.failed(result)
                            return
                        }
                        self.apply(shortcuts, version: version)
                        self.completeConfiguration()
                    })
        }
    }

    private func failed(_ result: PortalRequestOutcome) {
        let detail = result == .cancelled || result == .denied
            ? LinuxStrings.shortcutCancelled : LinuxStrings.shortcutSessionLost
        let interactionStarted = bindAttempted
        close(.close)
        if !interactionStarted, result == .unavailable || result == .busFailure {
            // Capability can vanish between the probe and session setup. Offer
            // the fallback's explicit Setup action; do not install it here.
            selection = .fallback
            registerFallback()
        } else { update(.failed, detail) }
        completeConfiguration()
    }

    private func apply(_ shortcuts: [PortalShortcut], version: UInt32) {
        let trigger = shortcuts.first { $0.id == ActionName.toggle.rawValue }?.properties["trigger_description"]
        let bound = trigger?.isEmpty == false
        update(bound ? .registered : .unbound, bound ? trigger! : SetupStrings.unboundShortcut,
               configuration: version >= 2 ? .systemSettings : nil)
    }

    private func update(_ status: RegistrationStatus, _ detail: String,
                        configuration: HotkeyConfiguration? = nil) {
        currentRegistration = HotkeyRegistration(id: currentRegistration.id,
            mechanism: .globalShortcutsPortal, status: status, detail: detail, configuration: configuration)
        onChange?()
    }

    private func signal(_ signal: PortalSignal) {
        switch signal {
        case .activated(let session, let action, _, let token):
            guard session == sessionHandle, action == ActionName.toggle.rawValue, bindAttempted,
                  currentRegistration.status == .registered else { return }
            activationToken = token
            activationRevision += 1
            let activationRevision = activationRevision
            onFire?()
            // ShortcutService marshals its callback through MainThread first.
            // Clear an unconsumed token after that hop (e.g. a debounced toggle).
            GTK.onMainLoop { [weak self] in
                guard let self, self.activationRevision == activationRevision else { return }
                self.activationToken = nil
            }
        case .shortcutsChanged(let session, let shortcuts):
            guard session == sessionHandle, bindAttempted, case .portal(let version) = selection else { return }
            apply(shortcuts, version: version)
        case .closed(let session) where session == sessionHandle:
            close(.alreadyClosed)
            update(.failed, LinuxStrings.shortcutSessionLost)
            completeConfiguration()
        case .lost:
            guard case .portal = selection else { return }
            close(.alreadyClosed)
            update(.failed, LinuxStrings.shortcutSessionLost)
            completeConfiguration()
        default: break
        }
    }

    func consumeActivationToken() -> String? {
        defer { activationToken = nil }
        return activationToken
    }

    /// A manual action opens the panel through LinuxEnvironment, but it cannot
    /// manufacture portal verification or a portal activation token.
    func fire(_ action: HotkeyAction) -> Bool {
        guard case .fallback = selection else { return false }
        return fallback.fire(action)
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard registration.id == currentRegistration.id else { return }
        onFire = nil
        revision += 1
        fallback.shutdown()
        close(.close)
        completeConfiguration()
    }

    func shutdown() {
        unregister(currentRegistration)
        selection = .stopped
        if let observation { transport.removeObserver(observation); self.observation = nil }
    }

    private func close(_ mode: Teardown) {
        // A native parent export may complete after teardown and a new gesture.
        // Invalidate that continuation before the next session can start.
        revision += 1
        let ids = calls
        calls.removeAll()
        // Disable continuations before cancelling their native waits.
        let wasConfiguring = configuring
        configuring = false
        for id in ids { transport.cancel(id) }
        configuring = wasConfiguring
        if mode == .close, let sessionHandle { transport.closeSession(sessionHandle) }
        sessionHandle = nil
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
