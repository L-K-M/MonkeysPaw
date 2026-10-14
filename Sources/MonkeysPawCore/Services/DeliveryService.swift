/// §6.3 sequencing. State and UI ports are confined to the injected MainThread;
/// schedulers and injectors return immediately and own their callback threads.
public final class DeliveryService {
    /// The last picker delivery, excluding self-tests.
    /// Read only on the injected MainThread.
    public private(set) var lastDelivery: DeliveryReceipt?

    private enum Selection {
        case ladder
        case only(PasteBackend)
    }

    private enum OperationState {
        case idle, running
    }

    // Timers hold this weakly. Clearing the slot releases previous text now,
    // rather than retaining it inside a cancelled timer until its deadline.
    private final class ClipboardRestore {
        let generation: UInt64
        let captureDeadline = ContinuousClock.now.advanced(by: Limits.clipboardSnapshotBudget)
        var snapshot: ClipboardTextSnapshot?
        var ownership: ClipboardWriteOwnership?
        var read: ClipboardSnapshotRead?
        var resumeCapture: (() -> Void)?
        var wasCancelled = false

        init(generation: UInt64) { self.generation = generation }
    }

    // Continuations share the terminal state even after the next operation starts.
    private final class Request {
        let text: String
        let mode: DeliveryMode
        let target: DeliveryTarget?
        let session: DesktopSession
        let selection: Selection
        let clipboardGeneration: UInt64
        let invocation: DeliveryInvocation?
        let isValid: () -> Bool
        let validate: (@escaping (Bool) -> Void) -> Void
        let done: (DeliveryOutcome?) -> Void
        var didComplete = false

        init(
            text: String, mode: DeliveryMode, target: DeliveryTarget?,
            session: DesktopSession, selection: Selection, clipboardGeneration: UInt64,
            invocation: DeliveryInvocation? = nil, isValid: @escaping () -> Bool = { true },
            validate: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
            done: @escaping (DeliveryOutcome?) -> Void
        ) {
            self.text = text
            self.mode = mode
            self.target = target
            self.session = session
            self.selection = selection
            self.clipboardGeneration = clipboardGeneration
            self.invocation = invocation
            self.isValid = isValid
            self.validate = validate
            self.done = done
        }
    }

    private let panel: PanelWindow
    private let focus: FocusTracker
    private let clipboard: Clipboard
    private let restoringClipboard: ClipboardRestoring?
    private let injectors: [PasteInjector]
    private let notifier: Notifier
    private let session: SessionProbe
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private let failureCache: PasteFailureCache
    private var armedTarget: DeliveryTarget?
    private var presentationGeneration: UInt64 = 0
    private var pending: [() -> Void] = []
    private var operationState = OperationState.idle
    private var clipboardRestoreMode: ClipboardRestoreMode
    private var clipboardGeneration: UInt64 = 0
    private var pendingClipboardRestore: ClipboardRestore?
    private var isShutdown = false

    public init(
        panel: PanelWindow, focus: FocusTracker, clipboard: Clipboard,
        injectors: [PasteInjector], notifier: Notifier, session: SessionProbe,
        scheduler: Scheduler, mainThread: MainThread, failureCache: PasteFailureCache,
        clipboardRestore: ClipboardRestoreMode = .off
    ) {
        self.panel = panel
        self.focus = focus
        self.clipboard = clipboard
        restoringClipboard = clipboard as? ClipboardRestoring
        self.injectors = injectors
        self.notifier = notifier
        self.session = session
        self.scheduler = scheduler
        self.mainThread = mainThread
        self.failureCache = failureCache
        clipboardRestoreMode = clipboardRestore
    }

    /// Composition forwards the committed D3 preference and shared settings
    /// changes here. Read-only settings must supply .off.
    public func setClipboardRestore(_ mode: ClipboardRestoreMode) {
        mainThread.run {
            guard !self.isShutdown, self.clipboardRestoreMode != mode else { return }
            self.clipboardRestoreMode = mode
            self.invalidateClipboardRestore()
        }
    }

    /// Permanently retire clipboard restoration during application shutdown.
    public func shutdown() {
        mainThread.run {
            self.isShutdown = true
            self.invalidateClipboardRestore()
        }
    }

    public func arm() {
        mainThread.run { self.armedTarget = self.focus.captureTarget() }
    }

    /// §4.6: capture the hotkey's target before queuing panel presentation.
    public func show() {
        mainThread.run {
            let generation = self.presentationGeneration
            self.armedTarget = self.focus.captureTarget()
            self.queue {
                // Composition can retire a graph while this show is held
                // behind focus restoration or a self-test.
                guard generation == self.presentationGeneration else {
                    self.completeOperation()
                    return
                }
                self.panel.show()
                self.completeOperation()
            }
        }
    }

    /// The driver must restore only while our app is still frontmost (§4.6).
    public func dismiss() {
        mainThread.run {
            let generation = self.presentationGeneration
            let target = self.armedTarget
            self.armedTarget = nil
            self.queue {
                guard generation == self.presentationGeneration else {
                    self.completeOperation()
                    return
                }
                self.panel.hide()
                guard let target else {
                    self.completeOperation()
                    return
                }
                var didComplete = false
                self.focus.restore(target) { _ in
                    self.mainThread.run {
                        guard !didComplete else { return }
                        didComplete = true
                        self.completeOperation()
                    }
                }
            }
        }
    }

    public func deliver(
        _ text: String, mode: DeliveryMode, done: @escaping (DeliveryOutcome) -> Void
    ) {
        enqueue(text, mode: mode, done: done)
    }

    /// Capture on the UI thread, before any async work. A repeat uses the
    /// current target without changing the hidden picker's armed target/draft.
    public func captureInvocation(source: DeliveryInvocationSource,
                                  completion: @escaping (DeliveryInvocation) -> Void) {
        mainThread.run {
            let target = source == .picker ? self.armedTarget : self.focus.captureTarget()
            completion(DeliveryInvocation(target: target, session: self.session.currentSession(),
                owner: ObjectIdentifier(self), generation: self.presentationGeneration))
        }
    }

    /// Nil means revoked before completion. Validation runs in the existing
    /// queue before write/hide and again after settle/focus, before injection.
    /// Its caller owns background source/access checks; isValid is a UI gate.
    public func deliver(
        _ text: String, mode: DeliveryMode, invocation: DeliveryInvocation,
        isValid: @escaping () -> Bool = { true },
        validate: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
        done: @escaping (DeliveryOutcome?) -> Void
    ) {
        mainThread.run {
            self.invalidateClipboardRestore()
            let request = Request(text: text, mode: mode, target: invocation.target,
                session: invocation.session, selection: .ladder, clipboardGeneration: self.clipboardGeneration,
                invocation: invocation, isValid: isValid, validate: validate) { outcome in
                    done(outcome)
                    self.completeOperation()
                }
            self.queue { self.start(request) }
        }
    }

    /// Revoke queued picker window requests and their captured target before
    /// composition replaces the picker graph. Delivery queue slots are retained.
    /// A dismissal queued earlier is dropped with its panel hide, so composition
    /// hides the reused panel itself before calling this.
    public func invalidatePendingPresentation() {
        mainThread.run {
            self.presentationGeneration &+= 1
            self.armedTarget = nil
            self.invalidateClipboardRestore()
        }
    }

    public func resetFailures() {
        mainThread.run { self.failureCache.reset() }
    }

    /// Read-only UI diagnostics: no clipboard/focus access or permission action.
    public func readStatus(done: @escaping (DeliveryStatusSnapshot) -> Void) {
        mainThread.run {
            let session = self.session.currentSession()
            let ladder = PasteLadder.backends(for: session)
            let failures = ladder.compactMap { backend in
                self.failureCache.failure(for: backend).map { BackendFailure(backend: backend, reason: $0) }
            }
            done(DeliveryStatusSnapshot(session: session, pasteLadder: ladder,
                cachedFailures: failures, lastDelivery: self.lastDelivery))
        }
    }

    // Self-test has stronger evidence than exit 0; do not reuse a proven failure.
    func recordUnreceived(_ backend: PasteBackend) {
        mainThread.run { self.failureCache.record(.notReceived, for: backend) }
    }

    // Keep focus and the clipboard exclusive through every backend's readback.
    // SelfTest releases the operation only after its last target closes.
    func performSelfTest(_ start: @escaping (@escaping () -> Void) -> Void) {
        mainThread.run {
            self.invalidateClipboardRestore()
            self.queue {
                var didComplete = false
                start {
                    self.mainThread.run {
                        guard !didComplete else { return }
                        didComplete = true
                        self.completeOperation()
                    }
                }
            }
        }
    }

    /// §6.5: test one backend, including cached failures, without changing
    /// the picker target.
    /// Only SelfTest calls this, sequentially inside performSelfTest's operation.
    func deliverForSelfTest(
        _ text: String, through backend: PasteBackend, done: @escaping (DeliveryOutcome) -> Void
    ) {
        mainThread.run {
            assert(self.operationState == .running, "Self-test must hold the operation queue")
            self.start(self.request(text, mode: .paste(.standard), selection: .only(backend)) {
                if let outcome = $0 { done(outcome) }
            })
        }
    }

    private func enqueue(
        _ text: String, mode: DeliveryMode,
        done: @escaping (DeliveryOutcome) -> Void
    ) {
        mainThread.run {
            self.invalidateClipboardRestore()
            let request = self.request(text, mode: mode, selection: .ladder) { outcome in
                if let outcome { done(outcome) }
                self.completeOperation()
            }
            self.queue { self.start(request) }
        }
    }

    private func request(
        _ text: String, mode: DeliveryMode, selection: Selection,
        done: @escaping (DeliveryOutcome?) -> Void
    ) -> Request {
        let target: DeliveryTarget?
        switch selection {
        case .ladder: target = armedTarget
        case .only: target = focus.captureTarget()
        }
        return Request(text: text, mode: mode, target: target,
                       session: session.currentSession(), selection: selection,
                       clipboardGeneration: clipboardGeneration, done: done)
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
        guard current(request) else { cancel(request); return }
        guard !isShutdown, clipboardRestoreMode == .previousText,
              case .ladder = request.selection, case .paste = request.mode,
              request.clipboardGeneration == clipboardGeneration,
              let restoringClipboard else {
            writeAndHide(request)
            return
        }

        let restoration = ClipboardRestore(generation: clipboardGeneration)
        pendingClipboardRestore = restoration
        restoration.resumeCapture = { [weak self] in self?.writeAndHide(request) }
        scheduler.after(Limits.clipboardSnapshotBudget) { [weak self, weak restoration] in
            self?.mainThread.run { [weak self, weak restoration] in
                guard let self, let restoration,
                      self.pendingClipboardRestore === restoration,
                      restoration.resumeCapture != nil else { return }
                self.discardClipboardRestore()
            }
        }
        let read = restoringClipboard.snapshotText(
            budget: Limits.clipboardSnapshotBudget, byteLimit: Limits.clipboardSnapshotMaxBytes
        ) { [weak self, weak restoration] snapshot in
            self?.mainThread.run { [weak self, weak restoration] in
                guard let self, let restoration else { return }
                self.captured(snapshot, for: restoration)
            }
        }
        // Inline completion can write/hide before the read handle is returned.
        if restoration.resumeCapture != nil { restoration.read = read }
        else if restoration.wasCancelled { read.cancel() }
    }

    private func captured(_ snapshot: ClipboardTextSnapshot?, for restoration: ClipboardRestore) {
        guard pendingClipboardRestore === restoration,
              let resume = restoration.resumeCapture else { return }
        restoration.resumeCapture = nil

        // A busy UI loop may deliver a late read before its timeout callback.
        if ContinuousClock.now < restoration.captureDeadline, let snapshot,
           snapshot.withText({ $0.utf8.prefix(Limits.clipboardSnapshotMaxBytes + 1).count })
            <= Limits.clipboardSnapshotMaxBytes {
            restoration.read = nil
            restoration.snapshot = snapshot
        } else {
            discardClipboardRestore()
        }

        resume()
    }

    private func writeAndHide(_ request: Request) {
        whileCurrent(request) { self.writeValidated(request) }
    }

    private func writeValidated(_ request: Request) {
        // Wayland needs the panel's selection serial before it loses focus.
        if let restoration = pendingClipboardRestore,
           restoration.generation == request.clipboardGeneration,
           let snapshot = restoration.snapshot, let restoringClipboard {
            restoration.ownership = restoringClipboard.writeTextOwning(request.text, after: snapshot.revision)
            if restoration.ownership == nil { discardClipboardRestore() }
        } else {
            clipboard.writeText(request.text)
        }
        panel.hideForDelivery()
        let delay = request.session == .macOS ? Limits.settleDelayMacOS : Limits.settleDelayLinux
        var didSettle = false
        scheduler.after(delay) {
            self.mainThread.run {
                guard !didSettle, !request.didComplete else { return }
                didSettle = true
                self.restore(for: request)
            }
        }
    }

    private func restore(for request: Request) {
        guard current(request) else { cancel(request); return }
        guard let target = request.target else {
            beginPaste(for: request, focus: .notCaptured)
            return
        }

        var didRestore = false
        focus.restore(target) { confirmation in
            self.mainThread.run {
                guard !didRestore, !request.didComplete else { return }
                didRestore = true
                self.beginPaste(for: request, focus: confirmation)
            }
        }
    }

    private func beginPaste(for request: Request, focus: FocusConfirmation) {
        whileCurrent(request) { self.pasteValidated(request, focus: focus) }
    }

    private func pasteValidated(_ request: Request, focus: FocusConfirmation) {
        guard case .paste(let chord) = request.mode else {
            if case .ladder = request.selection { notifier.copied() }
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
        guard current(request) else { cancel(request); return }
        guard let backend = remaining.first else {
            let reason = CopyReason.backendsFailed(failures)
            // SelfTestReport is the only output of diagnostic deliveries (§6.5).
            if case .ladder = request.selection { notifier.pressPaste(chord: chord, reason: reason) }
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
        var didRespond = false
        let consent: PasteConsent
        switch request.selection {
        case .ladder: consent = .userInitiated
        case .only: consent = .existingSession
        }
        injector.paste(chord: chord, consent: consent) { result in
            self.mainThread.run {
                guard !didRespond, !request.didComplete else { return }
                didRespond = true
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
        // Keep capture through retries; the final sent/copy-only outcome decides restore.
        failureCache.record(reason, for: backend)
        attempt(remaining.dropFirst(), for: request, chord: chord, focus: focus,
                failures: failures + [BackendFailure(backend: backend, reason: reason)])
    }

    private func finish(_ request: Request, outcome: DeliveryOutcome, focus: FocusConfirmation) {
        // Every continuation entered through MainThread, including done.
        guard !request.didComplete else { return }
        guard current(request) else { cancel(request); return }
        request.didComplete = true
        if case .ladder = request.selection {
            lastDelivery = DeliveryReceipt(outcome: outcome, focus: focus)
        }
        if case .pasted = outcome { scheduleClipboardRestore(for: request) }
        else { discardClipboardRestore(for: request) }
        request.done(outcome)
    }

    private func current(_ request: Request) -> Bool {
        guard !request.didComplete else { return false }
        guard let invocation = request.invocation else { return true }
        return !isShutdown && !invocation.isCancelled && invocation.owner == ObjectIdentifier(self)
            && invocation.generation == presentationGeneration && request.isValid()
    }

    private func whileCurrent(_ request: Request, _ work: @escaping () -> Void) {
        guard current(request) else { cancel(request); return }
        var didValidate = false
        request.validate { valid in
            self.mainThread.run {
                guard !didValidate, !request.didComplete else { return }
                didValidate = true
                guard valid, self.current(request) else { self.cancel(request); return }
                work()
            }
        }
    }

    private func cancel(_ request: Request) {
        guard !request.didComplete else { return }
        request.didComplete = true
        discardClipboardRestore(for: request)
        request.done(nil)
    }

    private func scheduleClipboardRestore(for request: Request) {
        guard let restoration = pendingClipboardRestore,
              restoration.generation == request.clipboardGeneration,
              restoration.snapshot != nil, restoration.ownership != nil else { return }
        // Release the operation queue normally; this timer never owns its slot.
        scheduler.after(Limits.clipboardRestoreDelay) { [weak self, weak restoration] in
            self?.mainThread.run { [weak self, weak restoration] in
                guard let self, let restoration,
                      self.pendingClipboardRestore === restoration,
                      restoration.generation == self.clipboardGeneration,
                      !self.isShutdown, self.clipboardRestoreMode == .previousText,
                      let snapshot = restoration.snapshot, let ownership = restoration.ownership,
                      let restoringClipboard = self.restoringClipboard else { return }
                self.pendingClipboardRestore = nil
                restoration.snapshot = nil
                restoration.ownership = nil
                restoringClipboard.restore(snapshot, ifOwnedBy: ownership)
            }
        }
    }

    private func invalidateClipboardRestore() {
        clipboardGeneration &+= 1
        discardClipboardRestore()
    }

    private func discardClipboardRestore(for request: Request) {
        guard pendingClipboardRestore?.generation == request.clipboardGeneration else { return }
        discardClipboardRestore()
    }

    private func discardClipboardRestore() {
        guard let restoration = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        let resume = restoration.resumeCapture
        restoration.resumeCapture = nil
        restoration.snapshot = nil
        restoration.ownership = nil
        restoration.wasCancelled = true
        let read = restoration.read
        restoration.read = nil
        read?.cancel()
        resume?()
    }
}
