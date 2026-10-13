import Foundation

public struct AssistantCommittedPrompt: Sendable {
    public let entry: LibraryEntry
    public let historyMaintenanceFailed: Bool
}

public enum AssistantAcceptanceConflict: Equatable, Sendable {
    case changedBuffer
    case modified(currentStamp: FileStamp)
    case deleted
}

public enum AssistantAcceptanceFailure: Equatable, Sendable {
    case notReady, cancelled, inactive, staleContext, accessDenied, editorBusy
    case editing(PromptEditingFailure)
    case invalid([PromptIssue])
    case readOnly(PromptReadOnlyReason)
}

/// Both committed cases must be adopted, even if a later context transition
/// retired the Assistant token. A warning never invites a second file write.
public enum AssistantAcceptanceOutcome: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    case saved(AssistantCommittedPrompt)
    case conflict(AssistantAcceptanceConflict)
    case failed(AssistantAcceptanceFailure)
    case committedWithProvenanceWarning(AssistantCommittedPrompt)

    public var committed: AssistantCommittedPrompt? {
        switch self {
        case .saved(let commit), .committedWithProvenanceWarning(let commit): return commit
        default: return nil
        }
    }

    init(_ outcome: PromptSaveOutcome) {
        switch outcome {
        case .saved(let entry): self = .saved(AssistantCommittedPrompt(entry: entry, historyMaintenanceFailed: false))
        case .savedButHistoryMaintenanceFailed(let entry):
            self = .saved(AssistantCommittedPrompt(entry: entry, historyMaintenanceFailed: true))
        case .savedButProvenanceFailed(let entry, let history):
            self = .committedWithProvenanceWarning(AssistantCommittedPrompt(entry: entry, historyMaintenanceFailed: history))
        case .conflict(let stamp): self = .conflict(.modified(currentStamp: stamp))
        case .deleted: self = .conflict(.deleted)
        case .invalid(let issues): self = .failed(.invalid(issues))
        case .readOnly(let reason): self = .failed(.readOnly(reason))
        case .failed(let failure): self = .failed(.editing(failure))
        }
    }

    public var description: String { "<assistant acceptance outcome>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["outcome": description]) }
}

enum AssistantSaveDestination { case newPrompt, improve, privateCopy }

struct AssistantSaveMetadata {
    let providerHost: String
    let model: String
    let usage: AssistantTokenUsage?
}

struct AssistantPreparedSave {
    let content: ArtifactMergeCandidate
    let metadata: AssistantSaveMetadata
    let permit: AssistantSavePermit
}

enum AssistantSaveRefusal: Error {
    case conflict(AssistantAcceptanceConflict)
    case failed(AssistantAcceptanceFailure)

    var outcome: AssistantAcceptanceOutcome {
        switch self {
        case .conflict(let conflict): return .conflict(conflict)
        case .failed(let failure): return .failed(failure)
        }
    }
}

/// UI invalidation and the worker's last publication check share this lock.
/// Once publication starts, newer edits stay in the editor, while the checked
/// commit still has an authoritative outcome. No UI reads run on the worker.
final class AssistantSavePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var refusal: AssistantSaveRefusal?

    func invalidate(_ refusal: AssistantSaveRefusal) {
        lock.lock()
        defer { lock.unlock() }
        if self.refusal == nil { self.refusal = refusal }
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if let refusal { throw refusal }
    }
}
