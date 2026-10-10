import Foundation

public struct LibraryEntry {
    public let relativePath: String
    /// Empty at the root; otherwise the relative subfolder path.
    public let folder: String
    public let identity: PromptIdentity
    public let document: PromptDocument
    public var issues: [PromptIssue] { document.issues }
    public let stamp: FileStamp

    init(path: String, document: PromptDocument, stamp: FileStamp) {
        relativePath = path
        folder = path.split(separator: "/").dropLast().joined(separator: "/")
        identity = PromptIdentity(path: path, id: document.frontMatter.id)
        self.document = document
        self.stamp = stamp
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
}
