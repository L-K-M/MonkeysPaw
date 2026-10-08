/// §6.3 sequencing. State and UI ports are confined to the injected MainThread;
/// schedulers and injectors return immediately and own their callback threads.
public final class DeliveryService {
    public private(set) var lastDelivery: DeliveryReceipt?

    private enum Selection {
        case ladder
        case only(PasteBackend)
    }

    private enum OperationState {
        case idle, running
    }

    private struct Request {
        let text: String
        let mode: DeliveryMode
        let target: DeliveryTarget?
        let session: DesktopSession
        let selection: Selection
        let done: (DeliveryOutcome) -> Void
    }

    private let panel: PanelWindow
    private let focus: FocusTracker
    private let clipboard: Clipboard
    private let injectors: [PasteInjector]
    private let notifier: Notifier
    private let session: SessionProbe
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private let failureCache: PasteFailureCache
    private var armedTarget: DeliveryTarget?
    private var pending: [() -> Void] = []
    private var operationState = OperationState.idle

    public init(
        panel: PanelWindow, focus: FocusTracker, clipboard: Clipboard,
        injectors: [PasteInjector], notifier: Notifier, session: SessionProbe,
        scheduler: Scheduler, mainThread: MainThread, failureCache: PasteFailureCache
    ) {
        self.panel = panel
        self.focus = focus
        self.clipboard = clipboard
        self.injectors = injectors
        self.notifier = notifier
        self.session = session
        self.scheduler = scheduler
        self.mainThread = mainThread
        self.failureCache = failureCache
    }

    public func arm() {
        mainThread.run { self.armedTarget = self.focus.captureTarget() }
    }

    /// Capture and present in one UI hop so the picker cannot become the target.
    public func show() {
        mainThread.run {
            self.queue {
                self.armedTarget = self.focus.captureTarget()
                self.panel.show()
                self.completeOperation()
            }
        }
    }

    /// The driver must restore only while our app is still frontmost (§4.6).
    public func dismiss() {
        mainThread.run {
            self.queue {
                let target = self.armedTarget
                self.armedTarget = nil
                self.panel.hide()
                guard let target else {
                    self.completeOperation()
                    return
                }
                self.focus.restore(target) { _ in
                    self.mainThread.run { self.completeOperation() }
                }
            }
        }
    }

    public func deliver(
        _ text: String, mode: DeliveryMode, done: @escaping (DeliveryOutcome) -> Void
    ) {
        enqueue(text, mode: mode, selection: .ladder, done: done)
    }

    /// §6.5: test exactly one backend, even when it previously failed.
    /// Capture the focused test field without changing the picker's armed target.
    public func deliver(
        _ text: String, through backend: PasteBackend, done: @escaping (DeliveryOutcome) -> Void
    ) {
        enqueue(text, mode: .paste(.standard), selection: .only(backend), done: done)
    }

    public func resetFailures() {
        mainThread.run { self.failureCache.reset() }
    }

    // Self-test has stronger evidence than exit 0; do not reuse a proven failure.
    func recordUnreceived(_ backend: PasteBackend) {
        failureCache.record(.notReceived, for: backend)
    }

    // Keep focus and the clipboard exclusive through every backend's readback.
    // SelfTest releases the operation only after its last target closes.
    func performSelfTest(_ start: @escaping (@escaping () -> Void) -> Void) {
        mainThread.run {
            self.queue {
                start { self.mainThread.run { self.completeOperation() } }
            }
        }
    }

    /// Only SelfTest calls this, sequentially inside performSelfTest's operation.
    func deliverForSelfTest(
        _ text: String, through backend: PasteBackend, done: @escaping (DeliveryOutcome) -> Void
    ) {
        mainThread.run {
            self.start(self.request(text, mode: .paste(.standard), selection: .only(backend), done: done))
        }
    }

    private func enqueue(
        _ text: String, mode: DeliveryMode, selection: Selection,
        done: @escaping (DeliveryOutcome) -> Void
    ) {
        mainThread.run {
            let request = self.request(text, mode: mode, selection: selection) { outcome in
                done(outcome)
                self.completeOperation()
            }
            self.queue { self.start(request) }
        }
    }

    private func request(
        _ text: String, mode: DeliveryMode, selection: Selection,
        done: @escaping (DeliveryOutcome) -> Void
    ) -> Request {
        let target: DeliveryTarget?
        switch selection {
        case .ladder: target = armedTarget
        case .only: target = focus.captureTarget()
        }
        return Request(text: text, mode: mode, target: target,
                       session: session.currentSession(), selection: selection, done: done)
    }

    private func queue(_ work: @escaping () -> Void) {
        pending.append(work)
        startNext()
    }

    private func startNext() {
        guard operationState == .idle, !pending.isEmpty else { return }
        operationState = .running
        pending.removeFirst()()
    }

    private func completeOperation() {
        operationState = .idle
        startNext()
    }

    private func start(_ request: Request) {
        // Wayland needs the panel's selection serial before it loses focus.
        clipboard.writeText(request.text)
        panel.hideForDelivery()
        let delay = request.session == .macOS ? Limits.settleDelayMacOS : Limits.settleDelayLinux
        scheduler.after(delay) {
            self.mainThread.run { self.restore(for: request) }
        }
    }

    private func restore(for request: Request) {
        guard let target = request.target else {
            beginPaste(for: request, focus: .notCaptured)
            return
        }

        focus.restore(target) { confirmation in
            self.mainThread.run { self.beginPaste(for: request, focus: confirmation) }
        }
    }

    private func beginPaste(for request: Request, focus: FocusConfirmation) {
        guard case .paste(let chord) = request.mode else {
            notifier.copied(chord: .standard)
            finish(request, outcome: .copiedOnly(.requested), focus: focus)
            return
        }

        let backends: [PasteBackend]
        switch request.selection {
        case .ladder: backends = PasteLadder.backends(for: request.session)
        case .only(let backend): backends = [backend]
        }
        attempt(backends[...], for: request, chord: chord, focus: focus, failures: [])
    }

    private func attempt(
        _ remaining: ArraySlice<PasteBackend>, for request: Request,
        chord: PasteChord, focus: FocusConfirmation, failures: [BackendFailure]
    ) {
        guard let backend = remaining.first else {
            let reason = CopyReason.backendsFailed(failures)
            notifier.pressPaste(chord: chord, reason: reason)
            finish(request, outcome: .copiedOnly(reason), focus: focus)
            return
        }

        if case .ladder = request.selection, let reason = failureCache.failure(for: backend) {
            attempt(remaining.dropFirst(), for: request, chord: chord, focus: focus,
                    failures: failures + [BackendFailure(backend: backend, reason: reason)])
            return
        }

        guard let injector = injectors.first(where: { $0.backend == backend }) else {
            failed(.backendUnavailable, backend: backend, remaining: remaining,
                   request: request, chord: chord, focus: focus, failures: failures)
            return
        }

        // The port enqueues work on its worker; Core never waits on injection.
        injector.paste(chord: chord) { result in
            self.mainThread.run {
                switch result {
                case .sent:
                    self.finish(request, outcome: .pasted(backend), focus: focus)
                case .failed(let reason):
                    self.failed(reason, backend: backend, remaining: remaining,
                                request: request, chord: chord, focus: focus, failures: failures)
                }
            }
        }
    }

    private func failed(
        _ reason: PasteFailure, backend: PasteBackend, remaining: ArraySlice<PasteBackend>,
        request: Request, chord: PasteChord, focus: FocusConfirmation, failures: [BackendFailure]
    ) {
        failureCache.record(reason, for: backend)
        attempt(remaining.dropFirst(), for: request, chord: chord, focus: focus,
                failures: failures + [BackendFailure(backend: backend, reason: reason)])
    }

    private func finish(_ request: Request, outcome: DeliveryOutcome, focus: FocusConfirmation) {
        // Every continuation entered through MainThread, including done.
        lastDelivery = DeliveryReceipt(outcome: outcome, focus: focus)
        request.done(outcome)
    }
}
