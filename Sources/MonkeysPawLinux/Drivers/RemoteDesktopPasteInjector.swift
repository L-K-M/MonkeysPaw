#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GLib owns every transition. GDBus queues IPC without blocking the UI loop.
final class RemoteDesktopPasteInjector: PasteInjector {
    let backend = PasteBackend.remoteDesktopPortal
    var onChange: (() -> Void)?

    private enum State { case idle, starting, ready, failed(PasteFailure), stopped }
    private enum Phase { case setup, chord, cleanup, finished }
    private enum Purpose { case allow, paste(PasteChord) }
    private enum Teardown { case close, alreadyClosed }

    private final class Operation {
        let purpose: Purpose
        let setupDeadline: ContinuousClock.Instant
        let done: (PasteAttemptResult) -> Void
        var phase = Phase.setup
        var calls = Set<UUID>()
        var parent: PortalParent?
        var pressed: [Int32] = []

        init(purpose: Purpose, deadline: ContinuousClock.Instant,
             done: @escaping (PasteAttemptResult) -> Void) {
            self.purpose = purpose
            setupDeadline = deadline
            self.done = done
        }
    }

    private let transport: LinuxPortalTransport
    private let tokens: PortalTokenStore
    private let mainThread: MainThread
    private let sessionType: DesktopSession
    private let parent: PortalParentProvider
    private let callBudget: Duration
    private let consentBudget: Duration
    private var state = State.idle
    private var sessionHandle: String?
    private var operation: Operation?
    private var observation: UUID?
    private var version: UInt32?
    private var availableDevices: UInt32?
    private var probeRevision = 0
    private var tokenWriteFailed = false

    init(transport: LinuxPortalTransport, tokens: PortalTokenStore, session: DesktopSession,
         mainThread: MainThread, parent: @escaping PortalParentProvider,
         callBudget: Duration = Limits.portalCallTimeout,
         consentBudget: Duration = Limits.portalConsentTimeout) {
        self.transport = transport
        self.tokens = tokens
        sessionType = session
        self.mainThread = mainThread
        self.parent = parent
        self.callBudget = callBudget
        self.consentBudget = consentBudget
        observation = transport.observe { [weak self] in self?.signal($0) }
    }

    deinit { shutdown() }

    var status: SetupStatus {
        switch state {
        case .ready:
            return tokenWriteFailed ? .needsAction(fix: LinuxStrings.portalTokenWriteFailed) : .ok
        case .starting: return .unknown
        case .failed(let failure):
            if version == 0 || availableDevices == 0 { return .needsAction(fix: LinuxStrings.portalUnavailable) }
            return .needsAction(fix: LinuxStrings.portalFailure(failure))
        case .stopped: return .needsAction(fix: LinuxStrings.portalSessionLost)
        case .idle:
            if version == 0 || availableDevices.map({ $0 & PortalDevice.keyboard == 0 }) == true {
                return .needsAction(fix: LinuxStrings.portalUnavailable)
            }
            return .needsAction(fix: LinuxStrings.portalAllow)
        }
    }

    /// Capability probes are quiet, including when a stored restore token exists.
    func probe() {
        guard operation == nil else { return }
        probeRevision += 1
        let revision = probeRevision
        let deadline = ContinuousClock.now.advanced(by: callBudget)
        transport.call(.property(.remoteDesktop, .version), deadline: deadline) { [weak self] result in
            guard let self, self.probeRevision == revision, self.operation == nil else { return }
            guard case .property(let version) = result else {
                self.version = 0
                self.onChange?()
                return
            }
            self.version = version
            self.transport.call(.property(.remoteDesktop, .availableDeviceTypes), deadline: deadline) { [weak self] result in
                guard let self, self.probeRevision == revision, self.operation == nil else { return }
                if case .property(let devices) = result { self.availableDevices = devices }
                else { self.availableDevices = 0 }
                self.onChange?()
            }
        }
    }

    func allow(done: @escaping () -> Void) {
        mainThread.run {
            if case .ready = self.state { done(); return }
            self.begin(.allow, budget: self.consentBudget) { _ in done() }
        }
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        paste(chord: chord, consent: .existingSession, completion: completion)
    }

    func paste(chord: PasteChord, consent: PasteConsent,
               completion: @escaping (PasteAttemptResult) -> Void) {
        mainThread.run {
            if case .ready = self.state, let session = self.sessionHandle {
                guard self.operation == nil else { completion(.failed(.backendUnavailable)); return }
                let work = Operation(purpose: .paste(chord), deadline: ContinuousClock.now, done: completion)
                self.operation = work
                self.inject(chord, session: session, work: work)
                return
            }
            if case .failed(let reason) = self.state { completion(.failed(reason)); return }
            guard consent == .userInitiated else { completion(.failed(.backendUnavailable)); return }
            let budget: Duration
            switch self.sessionType {
            case .gnomeWayland, .gnomeX11, .flatpak: budget = self.consentBudget
            default: budget = self.callBudget // Preserve KDE's short lazy portal path.
            }
            self.begin(.paste(chord), budget: budget, done: completion)
        }
    }

    private func begin(_ purpose: Purpose, budget: Duration,
                       done: @escaping (PasteAttemptResult) -> Void) {
        guard operation == nil else { done(.failed(.backendUnavailable)); return }
        if case .stopped = state { done(.failed(.backendUnavailable)); return }
        probeRevision += 1
        state = .starting
        onChange?()
        let work = Operation(purpose: purpose, deadline: ContinuousClock.now.advanced(by: budget), done: done)
        operation = work
        let deadline = ipcDeadline(work)
        track(work, transport.call(.property(.remoteDesktop, .version), deadline: deadline) { [weak self] result in
            guard let self, self.active(work) else { return }
            guard case .property(let version) = result, version >= 1 else {
                self.version = 0
                self.failSetup(work, result.failure ?? .backendUnavailable)
                return
            }
            self.version = version
            self.track(work, self.transport.call(.property(.remoteDesktop, .availableDeviceTypes), deadline: deadline) { [weak self] result in
                guard let self, self.active(work) else { return }
                guard case .property(let devices) = result, devices & PortalDevice.keyboard != 0 else {
                    self.availableDevices = 0
                    self.failSetup(work, result.failure ?? .backendUnavailable)
                    return
                }
                self.availableDevices = devices
                self.create(work, version: version)
            })
        })
    }

    private func create(_ work: Operation, version: UInt32) {
        track(work, transport.request(interface: .remoteDesktop, method: "CreateSession",
            options: ["session_handle_token": .string("monkeyspaw_paste_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))],
            deadline: ipcDeadline(work)) { [weak self] result in
                guard let self, self.active(work) else { return }
                guard case .success(let response) = result, let session = response.sessionHandle else {
                    self.failSetup(work, result.pasteFailure)
                    return
                }
                self.sessionHandle = session
                var options: [String: PortalOption] = ["types": .uint32(PortalDevice.keyboard)]
                if version >= 2 {
                    options["persist_mode"] = .uint32(PortalPersistence.untilRevoked.rawValue)
                    if case .loaded(let token) = self.tokens.load() {
                        options["restore_token"] = .string(token.value)
                    }
                }
                self.track(work, self.transport.request(interface: .remoteDesktop, method: "SelectDevices",
                    arguments: [.objectPath(session)], options: options, deadline: self.ipcDeadline(work)) { [weak self] result in
                        guard let self, self.active(work) else { return }
                        guard case .success = result else { self.failSetup(work, result.pasteFailure); return }
                        self.startSession(work, session: session)
                    })
            })
    }

    private func startSession(_ work: Operation, session: String) {
        parent { [weak self] parent in
            guard let self, self.active(work) else { parent.close(); return }
            work.parent = parent
            self.track(work, self.transport.request(interface: .remoteDesktop, method: "Start",
                arguments: [.objectPath(session), .string(parent.identifier)],
                deadline: work.setupDeadline) { [weak self] result in
                    guard let self, self.active(work) else { return }
                    parent.close()
                    work.parent = nil
                    guard case .success(let response) = result else {
                        self.failSetup(work, result.pasteFailure)
                        return
                    }
                    // A returned token has already replaced the single-use old token,
                    // even if this successful Start did not grant a keyboard.
                    if let token = response.restoreToken {
                        do { try self.tokens.save(token); self.tokenWriteFailed = false }
                        catch { self.tokenWriteFailed = true }
                    }
                    guard let devices = response.devices, devices & PortalDevice.keyboard != 0 else {
                        self.failSetup(work, .portalDenied)
                        return
                    }
                    self.state = .ready
                    self.onChange?()
                    switch work.purpose {
                    case .allow: self.finish(work, .sent)
                    case .paste(let chord): self.inject(chord, session: session, work: work)
                    }
                })
        }
    }

    private func inject(_ chord: PasteChord, session: String, work: Operation) {
        work.phase = .chord
        let control = Int32(GDK_KEY_Control_L), shift = Int32(GDK_KEY_Shift_L), v = Int32(GDK_KEY_v)
        let keys = chord == .terminal ? [control, shift, v] : [control, v]
        let events = keys.map { ($0, PortalKeyState.pressed) }
            + keys.reversed().map { ($0, PortalKeyState.released) }
        send(events[...], session: session, work: work,
             deadline: ContinuousClock.now.advanced(by: callBudget))
    }

    private func send(_ events: ArraySlice<(Int32, PortalKeyState)>, session: String,
                      work: Operation, deadline: ContinuousClock.Instant) {
        guard active(work), work.phase == .chord else { return }
        guard let (key, state) = events.first else { finish(work, .sent); return }
        // A down may have reached the server even if its reply fails or times out.
        if state == .pressed { work.pressed.append(key) }
        track(work, transport.call(.notifyKeysym(session: session, keysym: key, state: state),
            deadline: deadline) { [weak self] result in
                guard let self, self.active(work), work.phase == .chord else { return }
                guard result == .success else {
                    self.cleanup(work, session: session, reason: result.failure ?? .unknown)
                    return
                }
                if state == .released { work.pressed.removeAll { $0 == key } }
                self.send(events.dropFirst(), session: session, work: work, deadline: deadline)
            })
    }

    private func cleanup(_ work: Operation, session: String, reason: PasteFailure) {
        work.phase = .cleanup
        state = .failed(reason)
        onChange?()
        let deadline = ContinuousClock.now.advanced(by: callBudget)
        // Queue all reverse releases before Close on the same connection. Waiting
        // for a stalled release reply must not prevent the remaining releases.
        for key in work.pressed.reversed() {
            track(work, transport.call(.notifyKeysym(session: session, keysym: key, state: .released),
                deadline: deadline) { _ in })
        }
        sessionHandle = nil
        track(work, transport.call(.closeSession(session), deadline: deadline) { [weak self] result in
            guard let self, self.active(work) else { return }
            if result != .success { self.transport.closeSession(session) }
            self.finish(work, .failed(reason))
        })
    }

    private func failSetup(_ work: Operation, _ reason: PasteFailure) {
        state = .failed(reason)
        close(.close)
        finish(work, .failed(reason))
        onChange?()
    }

    private func active(_ work: Operation) -> Bool { operation === work && work.phase != .finished }
    private func ipcDeadline(_ work: Operation) -> ContinuousClock.Instant {
        min(work.setupDeadline, ContinuousClock.now.advanced(by: callBudget))
    }
    private func track(_ work: Operation, _ id: UUID) { if active(work) { work.calls.insert(id) } }

    private func finish(_ work: Operation, _ result: PasteAttemptResult) {
        guard active(work) else { return }
        work.phase = .finished
        operation = nil
        for id in work.calls { transport.cancel(id) }
        work.calls.removeAll()
        work.parent?.close()
        work.parent = nil
        work.done(result)
    }

    private func close(_ mode: Teardown) {
        if mode == .close, let sessionHandle { transport.closeSession(sessionHandle) }
        sessionHandle = nil
    }

    private func signal(_ signal: PortalSignal) {
        switch signal {
        case .closed(let session) where session == sessionHandle:
            close(.alreadyClosed)
        case .lost:
            close(.alreadyClosed)
            probeRevision += 1
            version = nil
            availableDevices = nil
        default: return
        }
        if case .stopped = state { return }
        state = .failed(.backendUnavailable)
        if let operation { finish(operation, .failed(.backendUnavailable)) }
        onChange?()
    }

    func shutdown() {
        if case .stopped = state { return }
        state = .stopped
        probeRevision += 1
        if let observation { transport.removeObserver(observation); self.observation = nil }
        if let work = operation, let sessionHandle {
            // Queue only releases before Close. Connection shutdown flushes these
            // messages; no callback is allowed to continue the original chord.
            for key in work.pressed.reversed() {
                transport.call(.notifyKeysym(session: sessionHandle, keysym: key, state: .released),
                    deadline: ContinuousClock.now.advanced(by: callBudget)) { _ in }
            }
        }
        close(.close)
        if let operation { finish(operation, .failed(.backendUnavailable)) }
    }
}

extension PortalRequestOutcome {
    var pasteFailure: PasteFailure {
        switch self {
        case .cancelled, .denied: return .portalDenied
        case .timedOut: return .timeout
        case .unavailable, .busFailure, .tornDown: return .backendUnavailable
        default: return .unknown
        }
    }
}

private extension PortalCallOutcome {
    var failure: PasteFailure? {
        if case .failed(let result) = self { return result.pasteFailure }
        return nil
    }
}
#endif
