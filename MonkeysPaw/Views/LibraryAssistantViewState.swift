import Foundation
import MonkeysPawCore
import SwiftUI

/// A native binding for one editor session. Core owns requests, merging and saves.
final class LibraryAssistantViewState: ObservableObject, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Flow: Hashable { case write, review, improve }

    @Published private(set) var state: AssistantState
    @Published private(set) var editorState: EditorState
    @Published private(set) var libraryAvailable: Bool
    @Published var flow = Flow.write
    @Published var brief = ""
    @Published var feedback = ""
    var onHighlight: ((Range<Int>?) -> Void)?
    var onRequest: (() -> Void)?
    private var model: AssistantModel?
    private let editor: EditorModel
    private let main: MainThread
    private let scheduler: MonkeysPawCore.Scheduler
    private let onAcceptance: (AssistantAcceptanceOutcome) -> Void
    private var snapshot: AssistantEditorSnapshot?
    private var timerID: UUID?
    private var requestUsesSource = false

    init(model: AssistantModel, editor: EditorModel, available: Bool, main: MainThread,
         scheduler: MonkeysPawCore.Scheduler, onAcceptance: @escaping (AssistantAcceptanceOutcome) -> Void) {
        self.model = model
        self.editor = editor
        self.main = main
        self.scheduler = scheduler
        self.onAcceptance = onAcceptance
        state = model.state
        editorState = editor.state
        snapshot = editor.assistantSnapshot
        libraryAvailable = available
        model.onChange = { [weak self] in
            main.run { [weak self] in
                guard let self, let model = self.model else { return }
                self.state = model.state
                if self.state.isStale { self.onHighlight?(nil) }
                self.updateTimer()
            }
        }
    }

    deinit { model?.deactivate() }

    var isWorking: Bool { state.phase == .working }
    private var editorIOBusy: Bool {
        editorState.status == .loading || editorState.status == .saving || editorState.status == .commandRunning
    }

    var writeDisabledMessage: String? {
        guard model != nil, libraryAvailable else { return LibraryAssistantStrings.unavailable }
        guard state.providerHost != nil, state.modelID != nil else { return LibraryAssistantStrings.noProfile }
        if state.mutationAccess == .unavailable { return "Assistant access is unavailable for this library." }
        if editorState.conflict != nil { return LibraryAssistantStrings.conflicted }
        if editorIOBusy || editor.assistantSnapshot?.availability == .busy
            || editorState.pendingDecision != nil || !editorState.queuedActions.isEmpty {
            return LibraryAssistantStrings.busy
        }
        return nil
    }

    var sourceDisabledMessage: String? {
        if let message = writeDisabledMessage { return message }
        if let reason = editorState.readOnlyReason { return EditorStrings.readOnly(reason) }
        guard editorState.source != nil, editorState.prompt != nil else { return LibraryAssistantStrings.noEditor }
        if editorState.isPrivate { return LibraryAssistantStrings.privatePrompt }
        if editorState.issues.contains(where: { $0.severity == .error }) { return LibraryAssistantStrings.invalid }
        return nil
    }

    var canWrite: Bool { writeDisabledMessage == nil && !isWorking && !state.isAccepting && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canReview: Bool { sourceDisabledMessage == nil && !isWorking && !state.isAccepting }
    var canImprove: Bool {
        canReview && (!state.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.selectedFindings.isEmpty)
    }
    var canAccept: Bool { libraryAvailable && !editorIOBusy && editorState.conflict == nil && model?.canAccept == true }
    private var requestDisabledMessage: String? { requestUsesSource ? sourceDisabledMessage : writeDisabledMessage }
    var canRetry: Bool { requestDisabledMessage == nil && model?.canRetry == true }
    var canShowDiff: Bool { requestDisabledMessage == nil && model?.canShowDiff == true }
    var canSelectFindings: Bool { canReview && !state.isStale }
    var improveTitle: String { state.mutationAccess == .privateCopy ? "Improve a private copy" : "Improve" }

    var footer: String {
        let destination = [state.providerHost, state.modelID].compactMap { $0 }.joined(separator: " · ")
        var parts = [destination.isEmpty ? "No active provider" : destination]
        if isWorking || state.elapsed > 0 { parts.append(String(format: "%.0f s", state.elapsed)) }
        if let usage = state.usage {
            parts.append("Tokens: \(usage.inputTokens) in / \(usage.outputTokens) out")
        }
        return parts.joined(separator: " · ")
    }

    var resultMessage: String {
        if state.isAccepting { return "Saving the accepted candidate…" }
        if let failure = state.failure { return LibraryAssistantStrings.failure(failure) }
        if let outcome = state.acceptanceOutcome, case .conflict = outcome, editorState.conflict != nil {
            return LibraryAssistantStrings.acceptance(outcome)
        }
        if state.isStale { return state.review != nil ? LibraryAssistantStrings.staleReview : LibraryAssistantStrings.stale }
        if state.phase == .saved || state.phase == .failed, let outcome = state.acceptanceOutcome {
            return LibraryAssistantStrings.acceptance(outcome)
        }
        return LibraryAssistantStrings.phase(state.phase)
    }

    func write() { if canWrite { requestUsesSource = false; onRequest?(); onHighlight?(nil); model?.write(brief: brief) } }
    func review() { if canReview { requestUsesSource = true; onRequest?(); onHighlight?(nil); model?.review() } }
    func editInstruction(_ value: String) { model?.editInstruction(value) }
    func improve() { if canImprove { requestUsesSource = true; onRequest?(); onHighlight?(nil); model?.improve() } }
    func toggleFinding(_ index: Int) { if canSelectFindings { model?.toggleFinding(at: index) } }
    func highlightFinding(_ index: Int) {
        guard canSelectFindings else { onHighlight?(nil); return }
        onHighlight?(model?.highlightFinding(at: index))
    }
    func retry() { if canRetry { onRequest?(); onHighlight?(nil); model?.retryWithFeedback(feedback) } }
    func showDiff() { if canShowDiff { model?.showDiff() } }
    func reject() { model?.reject(); onHighlight?(nil) }
    func cancel() { model?.cancel(); onHighlight?(nil) }
    func close() { model?.close(); onHighlight?(nil) }
    func cancelPendingAcceptance() { model?.cancelPendingAcceptance() }

    func accept() {
        guard canAccept, let model else { return }
        // Capture the outcome sink independently of this retired view/model.
        model.accept(using: editor) { [main, onAcceptance] outcome in
            main.run { onAcceptance(outcome) }
        }
    }

    func editorChanged(available: Bool) {
        guard let model else { return }
        libraryAvailable = available
        editorState = editor.state
        let latest = editor.assistantSnapshot
        if latest?.sourceBytes != snapshot?.sourceBytes || latest?.revision != snapshot?.revision
            || latest?.session != snapshot?.session || latest?.relativePath != snapshot?.relativePath {
            onHighlight?(nil)
        }
        snapshot = latest
        model.contextChanged()
    }

    func profileChanged() {
        onHighlight?(nil)
        model?.profileChanged()
    }

    func retire() {
        timerID = nil
        onHighlight?(nil)
        model?.deactivate()
        model = nil
        brief = ""
        feedback = ""
        onHighlight = nil
        onRequest = nil
    }

    private func updateTimer() {
        guard isWorking, model != nil else { timerID = nil; return }
        guard timerID == nil else { return }
        let id = UUID()
        timerID = id
        scheduleTick(id)
    }

    private func scheduleTick(_ id: UUID) {
        scheduler.after(.seconds(1)) { [weak self] in
            self?.main.run { [weak self] in
                guard let self, self.timerID == id, self.isWorking, let model = self.model else { return }
                model.updateElapsed()
                if self.timerID == id, self.isWorking { self.scheduleTick(id) }
            }
        }
    }

    var description: String { "<library assistant view state redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
