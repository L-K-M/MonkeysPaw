import Foundation

/// Opaque lifetime of one editor path, separate from its eventual prompt id.
public struct PromptEditingSession: Hashable, Sendable {
    let token: UUID
    let isInactive: Bool
    /// Checked editor-load hint for assistant preflight, not token membership.
    let loadedID: ULID?

    init(token: UUID, isInactive: Bool = false, loadedID: ULID? = nil) {
        self.token = token
        self.isInactive = isInactive
        self.loadedID = loadedID
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token == rhs.token && lhs.isInactive == rhs.isInactive
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(token)
        hasher.combine(isInactive)
    }
}

public enum PromptReadOnlyReason: Equatable, Sendable {
    case groupViewer, groupUnavailable
    case unsupportedFormat(PromptFormatVersion)
    case invalidUTF8
    case sourceTooLarge
}

/// Bytes, decoding and stamp come from the same checked library read. Invalid
/// YAML retains editable text and issues; undecodable bytes never become text.
public struct LoadedPrompt: Sendable {
    public let sourceBytes: Data
    public let source: String?
    public let entry: LibraryEntry
    public let readOnlyReason: PromptReadOnlyReason?
    public var document: PromptDocument { entry.document }
    public var stamp: FileStamp { entry.stamp }

    init(bytes: Data, entry: LibraryEntry) {
        sourceBytes = bytes
        self.entry = entry
        if bytes.count > Limits.maxPromptBytes {
            source = nil
            readOnlyReason = .sourceTooLarge
        } else if let text = String(data: bytes, encoding: .utf8) {
            source = text
            readOnlyReason = Self.readOnlyReason(for: entry.document) ?? entry.access.readOnlyReason
        } else {
            source = nil
            readOnlyReason = .invalidUTF8
        }
    }

    static func readOnlyReason(for document: PromptDocument) -> PromptReadOnlyReason? {
        if document.isReadOnly { return .unsupportedFormat(document.frontMatter.format) }
        if document.decodingIssues.contains(where: { $0.code == .sourceTooLarge }) { return .sourceTooLarge }
        if document.decodingIssues.contains(where: { $0.code == .invalidUTF8 }) { return .invalidUTF8 }
        return nil
    }
}

/// Sanitized failures carry no OS, YAML or prompt-content error bodies.
public enum PromptEditingFailure: Equatable, Sendable {
    case fileStore(FileStoreError)
    case library(LibraryError)
    case write(PromptWriteError)
    case identity(ULIDGenerationError)
}

public enum PromptLoadOutcome: Sendable {
    case loaded(LoadedPrompt)
    case deleted
    case failed(PromptEditingFailure)
}

/// Both committed cases carry canonical source, identity and the new stamp in
/// their entry. History maintenance failure is a committed save, not a retry.
public enum PromptSaveOutcome: Sendable {
    case saved(LibraryEntry)
    case savedButHistoryMaintenanceFailed(LibraryEntry)
    case savedButProvenanceFailed(LibraryEntry, historyMaintenanceFailed: Bool)
    case conflict(currentStamp: FileStamp)
    case deleted
    case invalid([PromptIssue])
    case readOnly(PromptReadOnlyReason)
    case failed(PromptEditingFailure)

    var committedEntry: LibraryEntry? {
        switch self {
        case .saved(let entry), .savedButHistoryMaintenanceFailed(let entry),
             .savedButProvenanceFailed(let entry, _): return entry
        default: return nil
        }
    }
}

public struct PromptExternalChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case modified, deleted, recreated, accessChanged
    }

    public let kind: Kind
    /// Nil only for a deleted path.
    public let newStamp: FileStamp?
    public var origin: PromptChangeOrigin = .external
    public var renamedTo: LibraryPromptSelection? = nil
}

/// Captured with index publication, before callbacks can reenter or a newer
/// publication replaces the cache. Stamps also cover cached rename destinations.
struct PromptIndexChange: Sendable {
    let changes: LibraryChangeSet
    let stamps: [RelativePath: FileStamp]
    let version: UInt64
    var origin: PromptChangeOrigin = .external
    var selections: [PromptIdentity: [LibraryPromptSelection]] = [:]
}
