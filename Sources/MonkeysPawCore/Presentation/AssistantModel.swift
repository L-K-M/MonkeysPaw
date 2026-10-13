import Foundation

public enum AssistantPhase: String, Sendable { case idle, working, draft, ready, saved, failed }

public struct AssistantState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public fileprivate(set) var phase = AssistantPhase.idle
    public fileprivate(set) var artifact: LlmArtifact?
    public fileprivate(set) var review: LlmReview?
    public fileprivate(set) var issues: [PromptIssue] = []
    public fileprivate(set) var selectedFindings = Set<Int>()
    public fileprivate(set) var instruction = ""
    public fileprivate(set) var candidate: AssistantCandidate?
    public var diff: ArtifactDiff? { candidate?.diff }
    public fileprivate(set) var failure: AssistantFailure?
    public fileprivate(set) var usage: AssistantTokenUsage?
    public fileprivate(set) var elapsed: TimeInterval = 0
    public fileprivate(set) var isStale = false
    public fileprivate(set) var isAccepting = false
    public fileprivate(set) var acceptanceOutcome: AssistantAcceptanceOutcome?
    public fileprivate(set) var providerHost: String?
    public fileprivate(set) var modelID: String?
    public fileprivate(set) var mutationAccess = AssistantMutationAccess.unavailable
    public fileprivate(set) var transcript: [AssistantMessage] = []

    public var description: String { "<assistant state redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}

/// Intents and state belong to the UI thread. Composition supplies current
/// service/editor values and calls contextChanged for every context transition.
/// Network/preflight callbacks and all notifications use injected MainThread.
public final class AssistantModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var onChange: (() -> Void)?
    public private(set) var state = AssistantState()

    private struct Attempt {
        let command: AssistantCommand
        let context: AssistantContext
        let request: AssistantRequest
    }

    private let service: AssistantService
    private let main: MainThread
    private let currentContext: () -> AssistantContext
    private let now: () -> ContinuousClock.Instant
    private var context: AssistantContext
    private var attempt: Attempt?
    private var reviewContext: AssistantContext?
    private var requestID: UUID?
    private var acceptanceID: UUID?
    private var savingPermit: AssistantSavePermit?
    private var retainedID: ULID?
    private var cancelWork: (() -> Void)?
    private var started: ContinuousClock.Instant?
    private var isActive = true
    private var publication: UInt64 = 0
    private var published: UInt64 = 0
    private var isPublishing = false

    public convenience init(service: AssistantService, main: MainThread,
                            context: @escaping () -> AssistantContext) {
        self.init(service: service, main: main, context: context, now: { ContinuousClock.now })
    }

    init(service: AssistantService, main: MainThread, context: @escaping () -> AssistantContext,
         now: @escaping () -> ContinuousClock.Instant) {
        self.service = service
        self.main = main
        currentContext = context
        self.context = context()
        self.now = now
        updateFooter()
    }

    deinit { cancelWork?(); savingPermit?.invalidate(.failed(.cancelled)) }

    public var canAccept: Bool {
        guard isActive, state.phase == .ready, !state.isStale, !state.isAccepting,
              !state.issues.contains(where: { $0.severity == .error }),
              let candidate = state.candidate else { return false }
        let latest = currentContext()
        return candidate.context == latest && service.isCurrent(latest)
    }

    /// Also rechecked at every intent and callback. Notifications are necessary
    /// to invalidate a switch away and back before an already queued reply runs.
    public func contextChanged() {
        guard isActive else { return }
        let latest = currentContext()
        guard latest != context else { return }
        if savingPermit != nil, acceptanceID != nil, context.sameSession(as: latest),
           let editor = latest.editor, editor.availability == .busy,
           context.editor == AssistantEditorSnapshot(source: editor.source, relativePath: editor.relativePath,
               revision: editor.revision, session: editor.session, stamp: editor.stamp) {
            // Our editor save barrier changes availability, not the preview.
            return
        }
        if !context.sameSession(as: latest) {
            savingPermit?.invalidate(.failed(.staleContext))
            reset()
        } else {
            if savingPermit != nil {
                savingPermit?.invalidate(.conflict(.changedBuffer))
                savingPermit = nil
                state.acceptanceOutcome = .conflict(.changedBuffer)
            }
            state.candidate = nil
            state.isAccepting = false
            acceptanceID = nil
            state.selectedFindings = []
            state.isStale = true
            if state.phase == .ready || state.phase == .saved { state.phase = .draft }
        }
        context = latest
        updateFooter()
        changed()
    }

    /// Credential edits may leave the non-secret profile byte-identical.
    /// Settings composition forwards them here without exposing a key value.
    public func profileChanged() {
        guard isActive else { return }
        savingPermit?.invalidate(.failed(.staleContext))
        reset()
        context = currentContext()
        updateFooter()
        changed()
    }

    public func write(brief: String, effort: AssistantEffort? = nil) {
        begin(.write(brief: brief), effort: effort)
    }

    public func review(effort: AssistantEffort? = nil) { begin(.review, effort: effort) }

    public func editInstruction(_ instruction: String) {
        guard isActive else { return }
        state.instruction = instruction
        changed()
    }

    public func toggleFinding(at index: Int) {
        contextChanged()
        guard isActive, reviewContext == context, let review = state.review,
              review.findings.indices.contains(index), state.phase != .working else { return }
        if state.selectedFindings.contains(index) { state.selectedFindings.remove(index) }
        else { state.selectedFindings.insert(index) }
        changed()
    }

    /// Ranges belong only to the reviewed exact source. Unmatched findings
    /// remain visible and selectable, but cannot highlight unrelated text.
    public func highlightFinding(at index: Int) -> Range<Int>? {
        contextChanged()
        guard isActive, reviewContext == context, let review = state.review,
              review.findings.indices.contains(index),
              case .matched(let range) = review.findings[index].quoteMatch else { return nil }
        return range
    }

    public func improve(effort: AssistantEffort? = nil) {
        contextChanged()
        let findings = reviewContext == context ? state.selectedFindings.sorted().compactMap {
            state.review?.findings[$0]
        } : []
        begin(.improve(instruction: state.instruction, selectedFindings: findings), effort: effort)
    }

    public func retryWithFeedback(_ feedback: String) {
        contextChanged()
        guard isActive, state.phase != .working, !state.isAccepting, let attempt else { return }
        begin(attempt.command, effort: attempt.request.effort, transcript: state.transcript, feedback: feedback)
    }

    /// A fresh merge/diff is the only way to accept an artifact after edits.
    public func showDiff() {
        contextChanged()
        guard isActive, state.phase != .working, !state.isAccepting,
              let artifact = state.artifact, let attempt, !attempt.command.isReview else { return }
        invalidateWork()
        let id = UUID()
        requestID = id
        state.phase = .draft
        state.failure = nil
        state.candidate = nil
        changed()
        guard requestID == id else { return }
        prepare(artifact, command: attempt.command, context: context, id: id)
    }

    /// Pure intent: A11 must recheck session/stamp and save these exact bytes.
    @discardableResult
    public func accept() -> AssistantAcceptance? {
        contextChanged()
        guard canAccept, let candidate = state.candidate else { return nil }
        let id = UUID()
        acceptanceID = id
        state.isAccepting = true
        let acceptance = AssistantAcceptance(id: id, candidate: candidate, usage: state.usage)
        changed()
        // An inline observer may close or invalidate the candidate.
        return acceptanceID == id ? acceptance : nil
    }

    /// False means the token was retired. A11 still owns reporting any committed
    /// file or provenance failure through the editor's save-outcome contract.
    @discardableResult
    public func completeAcceptance(_ id: UUID, result: Result<Void, AssistantFailure>) -> Bool {
        contextChanged()
        guard isActive, acceptanceID == id else { return false }
        acceptanceID = nil
        state.isAccepting = false
        switch result {
        case .success: state.phase = .saved
        case .failure(let failure): state.phase = .failed; state.failure = failure
        }
        changed()
        return true
    }

    /// Native composition uses this overload for the checked Core save. Write
    /// and viewer copies follow the editor's unsaved-edit guard before opening.
    public func accept(using editor: EditorModel,
                       completion: @escaping (AssistantAcceptanceOutcome) -> Void = { _ in }) {
        guard let attempt, let acceptance = accept() else { return main.run { completion(.failed(.notReady)) } }
        let access = acceptance.candidate.mutationAccess
        guard access != .unavailable, access == acceptance.candidate.context.access.mutationAccess else {
            let outcome = AssistantAcceptanceOutcome.failed(.accessDenied)
            completeAcceptance(acceptance.id, outcome: outcome)
            return main.run { completion(outcome) }
        }
        let destination: AssistantSaveDestination
        if access == .privateCopy { destination = .privateCopy }
        else if case .write = attempt.command { destination = .newPrompt }
        else { destination = .improve }
        let permit = AssistantSavePermit()
        savingPermit = permit
        editor.acceptAssistant(acceptance, destination: destination, permit: permit, validate: { [weak self] in
            do { try permit.check() }
            catch let refusal as AssistantSaveRefusal { return refusal }
            catch { return .failed(.inactive) }
            guard let self, self.isActive, self.acceptanceID == acceptance.id else { return .failed(.cancelled) }
            let latest = self.currentContext()
            guard acceptance.candidate.context.sameSession(as: latest), self.service.isCurrent(latest) else {
                return .failed(.staleContext)
            }
            guard latest == acceptance.candidate.context else { return .conflict(.changedBuffer) }
            return nil
        }) { [weak self] outcome in
            self?.completeAcceptance(acceptance.id, outcome: outcome)
            completion(outcome)
        }
    }

    /// Editor adoption precedes this callback, and its observers follow it.
    /// Retired tokens remain retired; callers still receive the actual outcome.
    @discardableResult
    public func completeAcceptance(_ id: UUID, outcome: AssistantAcceptanceOutcome) -> Bool {
        guard isActive, acceptanceID == id else { return false }
        if outcome.committed == nil {
            contextChanged()
            guard acceptanceID == id else { return false }
        }
        acceptanceID = nil
        savingPermit = nil
        state.isAccepting = false
        state.acceptanceOutcome = outcome
        state.failure = nil
        state.candidate = nil
        switch outcome {
        case .saved, .committedWithProvenanceWarning: state.phase = .saved; state.isStale = false
        case .conflict: state.phase = .draft; state.isStale = true
        case .failed: state.phase = .failed
        }
        context = currentContext()
        updateFooter()
        changed()
        return true
    }

    public func reject() { cancel() }
    public func close() { cancel() }
    public func escape() { cancel() }

    public func cancel() {
        guard isActive else { return }
        reset()
        updateFooter()
        changed()
    }

    /// Composition retires the model before discarding its library graph.
    public func deactivate() {
        cancel()
        isActive = false
        onChange = nil
    }

    /// Native timers call this intent through GLib/AppKit, never a main actor.
    public func updateElapsed() {
        guard isActive, started != nil else { return }
        measureElapsed()
        changed()
    }

    private func begin(_ command: AssistantCommand, effort: AssistantEffort?,
                       transcript: [AssistantMessage] = [], feedback: String? = nil) {
        contextChanged()
        guard isActive, !state.isAccepting else { return }
        invalidateWork()
        if feedback == nil { retainedID = nil }
        attempt = nil
        started = nil
        state.artifact = nil
        state.review = nil
        reviewContext = nil
        state.selectedFindings = []
        state.candidate = nil
        state.issues = []
        state.failure = nil
        state.acceptanceOutcome = nil
        state.usage = nil
        state.isStale = false
        state.transcript = []
        state.elapsed = 0
        let id = UUID()
        requestID = id
        let context = self.context
        do {
            let request = AssistantRequest(action: try command.action(in: context), effort: effort,
                transcript: transcript, feedback: feedback)
            attempt = Attempt(command: command, context: context, request: request)
            state.transcript = request.messages
            started = now()
            state.phase = .working
            changed()
            guard requestID == id else { return }
            let operation = service.perform(command, context: context, effort: effort,
                transcript: transcript, feedback: feedback) { [weak self] result in
                    self?.received(result, id: id)
                }
            if requestID == id { cancelWork = { operation.cancel() } }
            else { operation.cancel() }
        } catch {
            requestID = nil
            state.phase = .failed
            state.failure = error as? AssistantFailure ?? .assistant(.invalidOutput)
            changed()
        }
    }

    private func received(_ result: Result<AssistantResponse, AssistantFailure>, id: UUID) {
        guard isActive, requestID == id else { return }
        contextChanged()
        guard isActive, requestID == id, let attempt else { return }
        guard service.isCurrent(context) else { cancel(); return }
        cancelWork = nil
        measureElapsed()
        started = nil
        switch result {
        case .failure(let failure):
            state.phase = .failed
            state.failure = failure
            changed()
        case .success(let response):
            do { state.transcript.append(try response.transcriptMessage()) }
            catch { state.phase = .failed; state.failure = .assistant(.invalidOutput); changed(); return }
            state.usage = response.usage
            state.phase = .draft
            state.isStale = attempt.context != context
            switch response.output {
            case .review(let review):
                guard attempt.command.isReview else { failOutput(); return }
                state.review = review
                reviewContext = attempt.context
                state.issues = attempt.context.editor?.document.issues ?? []
                changed()
            case .artifact(let artifact):
                guard !attempt.command.isReview else { failOutput(); return }
                state.artifact = artifact
                state.issues = artifact.issues
                changed()
                guard requestID == id, !state.isStale else { return }
                prepare(artifact, command: attempt.command, context: attempt.context, id: id)
            }
        }
    }

    private func prepare(_ artifact: LlmArtifact, command: AssistantCommand, context: AssistantContext, id: UUID) {
        let operation = service.prepare(artifact, for: command, context: context, retainingID: retainedID) { [weak self] result in
            guard let self, self.isActive, self.requestID == id else { return }
            self.contextChanged()
            guard self.isActive, self.requestID == id else { return }
            self.cancelWork = nil
            guard context == self.context, self.service.isCurrent(context) else {
                self.state.isStale = true
                self.changed()
                return
            }
            switch result {
            case .success(let candidate):
                self.retainedID = candidate.content.document.frontMatter.id
                self.state.candidate = candidate
                self.state.issues = candidate.content.document.issues
                self.state.isStale = false
                self.state.phase = .ready
            case .failure(.invalid(let issues)):
                self.state.issues = issues
                self.state.phase = .draft
            case .failure(let failure):
                self.state.failure = failure
                self.state.phase = .failed
            }
            self.changed()
        }
        if requestID == id { cancelWork = { operation.cancel() } }
        else { operation.cancel() }
    }

    private func failOutput() {
        state.phase = .failed
        state.failure = .assistant(.invalidOutput)
        changed()
    }

    private func invalidateWork() {
        requestID = nil
        let cancel = cancelWork
        cancelWork = nil
        cancel?()
    }

    private func reset() {
        savingPermit?.invalidate(.failed(.cancelled))
        savingPermit = nil
        invalidateWork()
        attempt = nil
        reviewContext = nil
        acceptanceID = nil
        retainedID = nil
        started = nil
        state = AssistantState()
    }

    private func measureElapsed() {
        guard let started else { return }
        let duration = started.duration(to: now()).components
        state.elapsed = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    private func updateFooter() {
        state.providerHost = context.profile?.baseURL.host
        state.modelID = context.profile?.modelID
        state.mutationAccess = context.access.mutationAccess
    }

    private func changed() {
        publication &+= 1
        main.run { [weak self] in
            guard let self, self.isActive, !self.isPublishing else { return }
            self.isPublishing = true
            defer { self.isPublishing = false }
            while self.isActive, self.published != self.publication {
                self.published = self.publication
                self.onChange?()
            }
        }
    }

    public var description: String { "<assistant model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
