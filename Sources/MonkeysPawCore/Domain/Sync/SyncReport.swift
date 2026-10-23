import Foundation

public enum SyncStatus: String, Sendable {
    case idle, syncing, offline, needsSignIn, hasConflicts, syncError
}

public enum SyncPhase: String, Sendable {
    case idle, recovering, collecting, resyncing, reconciling, scanning, groupFolders, pushing
}

/// Fixed reasons only. Transport and persistence error bodies never reach UI.
public enum SyncBlockingIssue: String, Sendable {
    case rootUnavailable, invalidState, invalidProtocol, recoveryRequired, noProgress
}

public struct SyncFileDetail: Equatable, Sendable {
    public let path: RelativePath
    public let code: String
}

public struct SyncCounts: Equatable, Sendable {
    public internal(set) var pulled = 0
    public internal(set) var pushed = 0
    public internal(set) var fileErrors = 0
    public internal(set) var conflicts = 0
    public internal(set) var held = 0
    public internal(set) var pending = 0
}

/// A completed pass with outstanding input errors is not a successful sync.
/// Disabled is orthogonal to the six statuses; resync is an active phase.
public struct SyncReport: Equatable, Sendable {
    public internal(set) var enabled = false
    public internal(set) var phase: SyncPhase = .idle
    public internal(set) var lastSuccess: Date?
    public internal(set) var counts = SyncCounts()
    public internal(set) var details: [SyncFileDetail] = []
    public internal(set) var blockingIssue: SyncBlockingIssue?
    public internal(set) var needsSignIn = false
    public internal(set) var offline = false
    public internal(set) var retrying = false
    /// §26 S9: the latest pass's provider-settings step outcome, if configured.
    public internal(set) var providerSync: ProviderSyncOutcome?

    public var status: SyncStatus {
        if needsSignIn { return .needsSignIn }
        if blockingIssue != nil { return .syncError }
        if phase != .idle { return .syncing }
        if offline { return .offline }
        if counts.fileErrors > 0 || counts.pending > 0 || retrying { return .syncError }
        if counts.conflicts > 0 { return .hasConflicts }
        return .idle
    }
}

public enum SyncRootHealth: Sendable { case available, unavailable }

/// Busy means an admitted mutation is draining. Replacement must wait off UI,
/// then check again; recoveryRequired also forbids discarding the journal.
public enum SyncStopResult: Equatable, Sendable { case stopped, busy, recoveryRequired }

/// Native watchers provide the current raw-byte hash, not a canonical hash.
/// An event without a hash cannot suppress scheduling for an existing file.
public struct SyncFileChange: Sendable {
    public let path: RelativePath
    public let stamp: FileStamp?
    public let hash: String?

    public init(path: RelativePath, stamp: FileStamp?, hash: String?) {
        self.path = path
        self.stamp = stamp
        self.hash = hash
    }
}
