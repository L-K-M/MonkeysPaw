#if os(Linux)
import Foundation
import MonkeysPawCore

enum LinuxAssistantStrings {
    static let waitingForAction = "Wait for the Assistant action, or Cancel it."
    static let fixValidationErrors = "Fix the editor's validation errors to Review or Improve."
    static let title = "Assistant"
    static let setup = "Set up a provider in Settings."
    static let busy = "Wait for the editor operation or Save / Discard / Cancel decision to finish."
    static let conflict = "Resolve the editor's disk conflict before using the Assistant."
    static let privatePrompt = "This prompt is private. Review and Improve are disabled; Write sends only your brief."
    static let noEditor = "Open a writable prompt to Review or Improve. Write needs only a brief."
    static let stale = "The source changed. Show diff again before accepting."
    static let unavailable = "The library or your access is unavailable."
    static let viewer = "You can improve a private copy; the group prompt will be kept."
    static let saved = "Saved the displayed candidate."

    static func phase(_ state: AssistantState) -> String {
        if state.isAccepting { return "Saving the displayed candidate…" }
        switch state.phase {
        case .idle: return "Choose Write, Review or Improve. Changes require Accept."
        case .working: return "Working…"
        case .draft: return state.review == nil ? "Draft. Check the issues before accepting." : "Review complete. Select findings or enter an instruction to Improve."
        case .ready: return "Check the merged diff, then Accept or Reject."
        case .saved: return saved
        case .failed: return "The Assistant action did not complete."
        }
    }

    static func footer(_ state: AssistantState) -> String {
        var parts = [state.providerHost, state.modelID].compactMap { $0 }
        if let usage = state.usage {
            parts.append("Input: \(usage.inputTokens) tokens")
            parts.append("Output: \(usage.outputTokens) tokens")
        }
        if state.phase == .working || state.elapsed > 0 { parts.append(String(format: "%.1f s", state.elapsed)) }
        return parts.joined(separator: " · ")
    }

    static func placeholder(_ change: PlaceholderChange) -> String {
        switch change {
        case .added(let name): return "Placeholder added: \(name)."
        case .removed(let name): return "Placeholder removed: \(name). Remembered values will no longer be used."
        case .renamed(let from, let to): return "Possible placeholder rename: \(from) → \(to). Remembered values will not follow the new name."
        }
    }

    static func failure(_ failure: AssistantFailure) -> String {
        switch failure {
        case .noEditor: return noEditor
        case .editorBusy: return busy
        case .editorConflict: return conflict
        case .staleContext: return "The editor, library or provider changed. Start a new action."
        case .invalid: return "Fix the validation errors before continuing."
        case .readOnly(let reason): return LinuxEditorStrings.readOnly(reason)
        case .settings(let error): return LinuxAssistantSettingsStrings.settingsError(error)
        case .write: return "The candidate could not be serialized."
        case .identity: return "Could not assign a prompt identity. Retry the action."
        case .diff: return "The candidate is too large or complex to compare."
        case .assistant(let error):
            switch error {
            case .notConfigured: return setup
            case .privatePrompt: return privatePrompt
            case .accessDenied: return unavailable
            case .authentication: return "Authentication failed. Check the profile in Settings."
            case .modelNotFound: return "The model was not found. Check its ID in Settings."
            case .rateLimited: return "The provider is rate limiting requests. Retry later."
            case .overloaded: return "The provider is overloaded. Retry later."
            case .transport(.cancelled): return "Cancelled. No candidate was applied."
            case .transport(.deadlineExceeded): return "The request timed out. Retry when ready."
            case .transport: return "Could not reach the provider. Check the connection, then retry."
            case .providerFailure, .providerState: return "The provider could not complete the action. Check Settings, then retry."
            case .truncated: return "The response was truncated. Retry with a shorter request."
            case .declined: return "The provider declined the request."
            case .emptyResponse, .unexpectedStop, .invalidOutput: return "The provider did not return a valid Assistant result. Retry with feedback."
            }
        }
    }

    static func outcome(_ outcome: AssistantAcceptanceOutcome) -> String {
        switch outcome {
        case .saved(let commit): return commit.historyMaintenanceFailed ? LinuxEditorStrings.historyWarning : saved
        case .committedWithProvenanceWarning(let commit):
            return commit.historyMaintenanceFailed ? LinuxEditorStrings.historyAndProvenanceWarning : LinuxEditorStrings.provenanceWarning
        case .conflict(.changedBuffer): return stale
        case .conflict(.modified): return LinuxEditorStrings.changed
        case .conflict(.deleted): return LinuxEditorStrings.missing
        case .failed(let failure):
            switch failure {
            case .notReady: return "Show a valid diff before accepting."
            case .cancelled: return "Cancelled. Check the editor for any save that had already started."
            case .inactive, .staleContext: return "This Assistant session ended. Start a new action in the current editor."
            case .accessDenied: return unavailable
            case .editorBusy: return busy
            case .invalid: return "Fix the candidate's validation errors before accepting."
            case .readOnly(let reason): return LinuxEditorStrings.readOnly(reason)
            case .editing(let failure): return LinuxEditorStrings.editingFailure(failure)
            }
        }
    }
}
#endif
