import MonkeysPawCore

enum LibraryAssistantStrings {
    static let title = "Assistant"
    static let flow = "Assistant flow"
    static let write = "Write"
    static let review = "Review"
    static let improve = "Improve"
    static let working = "Working…"
    static let writeHint = "Describe the reusable prompt you want to write."
    static let brief = "Prompt brief"
    static let reviewHint = "Review the current template against the prompt rubric."
    static let instruction = "Improvement instruction"
    static let instructionHint = "Use selected findings, an instruction, or both."
    static let showQuote = "Show quote in editor"
    static let draft = "Draft"
    static let draftNotes = "Draft notes (not saved)"
    static let cancel = "Cancel"
    static let showDiff = "Show diff"
    static let accept = "Accept"
    static let reject = "Reject"
    static let feedback = "Feedback for retry"
    static let retry = "Retry with feedback"

    static let noProfile = "Set up a provider in Settings → Assistant."
    static let unavailable = "The library is unavailable. Choose an accessible library in Settings."
    static let busy = "Wait for the editor operation or unsaved-changes decision to finish."
    static let conflicted = "Resolve the editor's disk conflict before using Assistant."
    static let noEditor = "Open a prompt to review or improve it. Write creates a new prompt from your brief."
    static let privatePrompt = "This template is private. Review and Improve are disabled. Write sends only your brief."
    static let invalid = "Fix the editor's validation errors before reviewing or improving it."
    static let viewer = "Viewer access: acceptance saves a new copy in your personal library."
    static let stale = "The source changed. Show a new diff before accepting."
    static let unmatched = "Quote does not match the reviewed source; it cannot be highlighted."
    static let staleReview = "These findings refer to an older source. Review again before selecting or highlighting them."

    static func severity(_ value: LlmReviewSeverity) -> String {
        switch value {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    static func criterion(_ value: LlmRubricCriterion) -> String {
        switch value {
        case .clarity: return "Clarity"
        case .context: return "Context"
        case .role: return "Role"
        case .delimiting: return "Delimiting"
        case .outputFormat: return "Output format"
        case .examples: return "Examples"
        case .reasoning: return "Reasoning"
        case .verifiability: return "Verifiability"
        case .decomposition: return "Decomposition"
        case .placeholders: return "Placeholders"
        }
    }

    static func placeholder(_ change: PlaceholderChange) -> String {
        switch change {
        case .added(let name): return "Added placeholder: \(name)."
        case .removed(let name): return "Removed placeholder: \(name). Remembered values will no longer be used."
        case .renamed(let from, let to):
            return "Possible placeholder rename: \(from) → \(to). Remembered values do not follow a rename."
        }
    }

    static func phase(_ phase: AssistantPhase) -> String {
        switch phase {
        case .idle: return "Choose a flow and start an explicit request."
        case .working: return "Working…"
        case .draft: return "Review the draft and validation issues."
        case .ready: return "Review the merged diff. Accept saves exactly this candidate."
        case .saved: return "Saved."
        case .failed: return "The Assistant action failed."
        }
    }

    static func failure(_ failure: AssistantFailure) -> String {
        switch failure {
        case .assistant(let error): return assistantError(error)
        case .settings(let error): return SettingsAssistantStrings.settingsError(error)
        case .invalid: return invalid
        case .readOnly(let reason): return EditorStrings.readOnly(reason)
        case .write: return "Could not prepare the prompt file. Check its metadata and retry."
        case .identity: return "Could not assign the draft an identity. Retry the request."
        case .diff(.sourceTooLarge): return "The source is too large to compare. Shorten it and show a new diff."
        case .diff(.comparisonTooComplex): return "The changes are too complex to compare. Try a smaller improvement."
        case .noEditor: return noEditor
        case .editorBusy: return busy
        case .editorConflict: return conflicted
        case .staleContext: return "The provider or editor session changed. Start a new request."
        }
    }

    private static func assistantError(_ error: AssistantError) -> String {
        switch error {
        case .notConfigured: return noProfile
        case .accessDenied: return "Assistant access is unavailable for this library."
        case .privatePrompt: return privatePrompt
        case .transport(.cancelled): return "Request cancelled."
        case .transport(.deadlineExceeded): return "The request timed out. Retry when the provider is available."
        case .transport: return "Could not reach the provider. Check its address and your network, then retry."
        case .authentication: return "Authentication failed. Check the provider's key in Settings."
        case .modelNotFound: return "The model was not found. Check the model ID in Settings."
        case .rateLimited: return "The provider rate limited this request. Retry later."
        case .overloaded: return "The provider is overloaded. Retry later."
        case .providerFailure(let status): return "The provider returned HTTP \(status). Retry later."
        case .providerState: return "Could not read or save provider capabilities. Check app-data permissions."
        case .truncated: return "The provider's output was truncated. Retry with a shorter request."
        case .declined: return "The provider declined the request. Revise it and retry."
        case .emptyResponse: return "The provider returned no output. Retry the request."
        case .unexpectedStop: return "The provider stopped unexpectedly. Retry the request."
        case .invalidOutput: return "The provider returned an invalid draft. Retry with feedback."
        }
    }

    static func acceptance(_ outcome: AssistantAcceptanceOutcome) -> String {
        switch outcome {
        case .saved(let commit):
            return commit.historyMaintenanceFailed ? "Prompt saved. History needs maintenance; do not retry the save."
                : "Prompt saved."
        case .committedWithProvenanceWarning(let commit):
            return "Prompt saved, but its Assistant provenance could not be saved. Do not retry the save."
                + (commit.historyMaintenanceFailed ? " History also needs maintenance." : "")
        case .conflict(.changedBuffer): return "The editor changed. Show a new diff before accepting. Your edits remain available."
        case .conflict(.modified): return "The file changed on disk. Resolve the editor conflict, then show a new diff."
        case .conflict(.deleted): return "The file was deleted on disk. Resolve the editor conflict before accepting."
        case .failed(let failure):
            switch failure {
            case .notReady: return "The draft is not ready. Show a valid diff before accepting."
            case .cancelled: return "Acceptance cancelled."
            case .inactive: return "The editor session closed before acceptance finished."
            case .staleContext: return "The provider or editor session changed. Start a new request."
            case .accessDenied: return "You no longer have access to save this draft."
            case .editorBusy: return busy
            case .editing(let error): return EditorStrings.editingFailure(error)
            case .invalid: return "Could not accept. Fix the draft's validation errors and show a new diff."
            case .readOnly(let reason): return EditorStrings.readOnly(reason)
            }
        }
    }
}
