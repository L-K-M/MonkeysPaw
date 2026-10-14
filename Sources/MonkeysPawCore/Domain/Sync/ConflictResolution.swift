import Foundation

public enum ConflictResolutionAction: Equatable, Sendable {
    case keepServer, keepMine, keepBoth
}

public enum ConflictResolutionFailure: Error, Equatable, Sendable {
    case inactive, busy, invalidCopy, staleCopy, staleSession, staleAccess
    case originalUnavailable, accessDenied, headChanged, invalidCandidate
    case needsSignIn, offline, recoveryRequired, operationFailed
}

/// An immutable preview capability. Only the service can construct one; its
/// private baselines bind every action to the bytes and session the user saw.
public struct ConflictPreview: Equatable, CustomStringConvertible, CustomReflectable {
    public let id: UUID
    public let copy: LibraryPromptSelection
    public let originalID: ULID?
    public let serverBytes: Data?
    public let candidateBytes: Data?
    public let diff: ArtifactDiff?
    public let mineRefusal: ConflictResolutionFailure?
    public var canKeepMine: Bool { mineRefusal == nil && diff != nil }
    public var canKeepServer: Bool { serverBytes != nil }

    let baseline: SyncLibraryFile
    let head: SyncConflictHead?
    let binding: SyncLibraryIdentity
    let epoch: UInt64
    let accessGeneration: UInt64
    let role: SyncAPI.Role?
    let validity = ConflictPreviewValidity()

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public var description: String { "<conflict preview>" }
    public var customMirror: Mirror { Mirror(self, children: ["preview": description]) }
}

final class ConflictPreviewValidity {
    private let lock = NSLock()
    private var active = true
    func invalidate() { lock.lock(); active = false; lock.unlock() }
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard active else { throw ConflictResolutionFailure.staleSession }
    }
}

public enum ConflictResolutionResult {
    case resolved(ConflictResolutionAction)
    /// A changed server head requires another explicit choice on the new diff.
    case refreshed(ConflictPreview)
}

public struct ConflictState: Equatable {
    public enum Operation: Equatable { case idle, loading, resolving }
    public internal(set) var operation: Operation = .idle
    public internal(set) var preview: ConflictPreview?
    public internal(set) var error: ConflictResolutionFailure?
    public internal(set) var resolved: ConflictResolutionAction?
    public var isBusy: Bool { operation != .idle }
    public var canKeepMine: Bool {
        !isBusy && preview?.canKeepMine == true && (error == nil || error == .headChanged || error == .offline)
    }
    public var canKeepServer: Bool { !isBusy && preview?.canKeepServer == true }
    public var canKeepBoth: Bool { !isBusy && preview != nil }
}
