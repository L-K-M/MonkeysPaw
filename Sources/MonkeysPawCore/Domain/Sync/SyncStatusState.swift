import Foundation

public enum SyncFooter: Equatable, Sendable {
    case disabled, idle, syncing, resyncing, offline, needsSignIn, hasConflicts, syncError

    public var text: String {
        switch self {
        case .disabled: return "Sync off"
        case .idle: return "Sync idle"
        case .syncing: return "Syncing…"
        case .resyncing: return "Resyncing…"
        case .offline: return "Offline"
        case .needsSignIn: return "Sign in again"
        case .hasConflicts: return "Conflicts"
        case .syncError: return "Sync errors"
        }
    }
}

public enum SyncStatusAction: Equatable, Sendable { case account, syncNow, conflicts, errors, none }

public struct SyncStatusFileError: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let path: RelativePath
    public let code: String
    public let reason: String

    init(_ detail: SyncFileDetail) {
        path = detail.path
        if let content = PromptIssueCode(rawValue: detail.code) {
            code = content.rawValue
            reason = PromptIssue(content).message
        } else if let path = SyncPathIssueCode(rawValue: detail.code) {
            code = path.rawValue
            reason = path.message
        } else {
            switch detail.code {
            case "prompt.id_mismatch":
                code = detail.code; reason = "The prompt identity does not match its recorded identity."
            case "not_found":
                code = detail.code; reason = "The recorded server prompt could not be found."
            case "forbidden":
                code = detail.code; reason = "The server did not allow this change. Refresh group access."
            case "sync.path_clash":
                code = detail.code; reason = "Choose another path for this prompt."
            case "sync.local_visibility":
                code = detail.code; reason = "Move the prompt to a visible library path."
            default:
                code = "sync.unknown"; reason = "This file could not be synced."
            }
        }
    }

    public var description: String { "<sync file error redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["error": description]) }
}

/// Footer projection preserves SyncReport's precedence and last-success facts.
public struct SyncStatusState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let enabled: Bool
    public let status: SyncStatus
    public let phase: SyncPhase
    public let lastSuccess: Date?
    public let counts: SyncCounts
    public let blockingIssue: SyncBlockingIssue?
    public let retrying: Bool
    public let footer: SyncFooter
    public let fileErrors: [SyncStatusFileError]
    public let showsErrorDetails: Bool

    public var canSyncNow: Bool { enabled && status != .needsSignIn && blockingIssue == nil && phase == .idle }

    public var action: SyncStatusAction {
        switch footer {
        case .disabled, .needsSignIn: return .account
        case .hasConflicts: return .conflicts
        case .syncError: return .errors
        case .idle, .offline: return .syncNow
        case .syncing, .resyncing: return .none
        }
    }

    public var errorMessage: String? {
        if status == .needsSignIn { return "Sign in again. Local changes remain queued." }
        switch blockingIssue {
        case .rootUnavailable: return "Choose an available library folder."
        case .invalidState: return "Saved sync state could not be validated."
        case .invalidProtocol: return "The server returned invalid sync data."
        case .recoveryRequired: return "Local sync recovery must finish before syncing can continue."
        case .noProgress: return "Sync could not finish within its bounded attempt. Try again later."
        case nil:
            if retrying { return "Sync will retry after a server or connection failure." }
            if counts.pending > 0 { return "Local changes are waiting to sync." }
            return nil
        }
    }

    init(report: SyncReport, showsErrorDetails: Bool = false) {
        enabled = report.enabled
        status = report.status
        phase = report.phase
        lastSuccess = report.lastSuccess
        counts = report.counts
        blockingIssue = report.blockingIssue
        retrying = report.retrying
        fileErrors = report.details.map(SyncStatusFileError.init).sorted { $0.path < $1.path }
        self.showsErrorDetails = showsErrorDetails
        if report.needsSignIn { footer = .needsSignIn }
        else if !report.enabled { footer = .disabled }
        else {
            switch report.status {
            case .idle: footer = .idle
            case .syncing: footer = report.phase == .resyncing ? .resyncing : .syncing
            case .offline: footer = .offline
            case .needsSignIn: footer = .needsSignIn
            case .hasConflicts: footer = .hasConflicts
            case .syncError: footer = .syncError
            }
        }
    }

    public var description: String { "<sync status state redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}
