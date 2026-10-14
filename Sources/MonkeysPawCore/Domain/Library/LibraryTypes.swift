import Foundation

/// Immutable after initialization. The document's internal preserved YAML has
/// resolved tags from PromptCodec; callers cannot mutate it, and public reads
/// use only value types. Yams.Node lacks Sendable, so this boundary is unchecked.
public struct LibraryEntry: @unchecked Sendable {
    public let relativePath: String
    /// Empty at the root; otherwise the relative subfolder path.
    public let folder: String
    public let identity: PromptIdentity
    public let document: PromptDocument
    public var issues: [PromptIssue] { document.issues }
    public let stamp: FileStamp
    public let access: PromptAccessState
    public let favorite: Bool
    public let accessGeneration: UInt64

    init(path: String, document: PromptDocument, stamp: FileStamp,
         access: PromptAccessState = .local, favorite: Bool? = nil, accessGeneration: UInt64 = 0) {
        relativePath = path
        // A leading combining mark can extend the preceding slash grapheme.
        // Paths use slash scalars, independent of Character segmentation.
        folder = path.unicodeScalars.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        identity = PromptIdentity(path: path, id: document.frontMatter.id)
        self.document = document
        self.stamp = stamp
        self.access = access
        self.favorite = favorite ?? document.frontMatter.favorite
        self.accessGeneration = accessGeneration
    }

    func projecting(_ snapshot: GroupAccessSnapshot) -> LibraryEntry {
        LibraryEntry(path: relativePath, document: document, stamp: stamp,
            access: snapshot.access(at: relativePath, identity: identity), favorite: snapshot.favorite(for: self),
            accessGeneration: snapshot.generation)
    }
}

public struct HistoryRevision: Equatable, Sendable {
    public let identity: PromptIdentity
    /// UTC millisecond timestamp plus a six-digit same-millisecond sequence.
    public let filename: String
    public let timestamp: Date

    init(identity: PromptIdentity, filename: String, timestamp: Date) {
        self.identity = identity
        self.filename = filename
        self.timestamp = timestamp
    }
}

public enum LibraryError: String, Error, Sendable {
    case invalidPromptPath
    case invalidIdentity
    case identityMismatch
    /// Only exclusive publication to the library can produce this error;
    /// alreadyExists from keyed-state migration remains a separate failure.
    case destinationOccupied
    case conflict
    case copyLimitReached
    case invalidTimestamp
    case historyCollisionLimitReached
    case revisionNotFound
    case keyedStateConflict
    case operationFailed
    /// Recovery/maintenance errors mean some durable state may have changed;
    /// the caller must reload before retrying. No underlying error is exposed.
    case recoveryRequired
    case historyMaintenanceFailed
    case provenanceMaintenanceFailed
    case invalidProvenance
    case previewMismatch
    case accessDenied
    case syncUnavailable
}
