import Foundation

/// A read-only snapshot, including revisions the writer refuses to restore.
public struct PromptHistorySnapshot: Equatable, Sendable {
    public let revision: HistoryRevision
    public let byteCount: Int
    /// Undecodable or oversized revisions retain their size and typed refusal.
    public let source: String?
    public let restoreFailure: PromptWriteError?
    public var isForensic: Bool { restoreFailure != nil }

    init(revision: HistoryRevision, bytes: Data, filename: String) {
        self.revision = revision
        byteCount = bytes.count
        source = bytes.count <= Limits.maxPromptBytes ? String(data: bytes, encoding: .utf8) : nil
        let document = PromptCodec.parseFile(bytes, filename: filename)
        if document.isReadOnly { restoreFailure = .unsupportedFormat(document.frontMatter.format) }
        else if document.issues.contains(where: { $0.severity == .error }) { restoreFailure = .invalidPrompt }
        else { restoreFailure = nil }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.byteCount == rhs.byteCount
            && lhs.source.map { Data($0.utf8) } == rhs.source.map { Data($0.utf8) }
            && lhs.restoreFailure == rhs.restoreFailure
    }
}

public enum PromptHistoryOutcome: Sendable {
    case loaded([PromptHistorySnapshot])
    case failed(PromptEditingFailure)
}

/// Commands never overwrite an occupied destination or resurrect a missing
/// prompt. Guard outcomes are returned by the editor before any file work.
public enum PromptCommandOutcome: Sendable {
    case updated(LibraryEntry)
    case updatedButHistoryMaintenanceFailed(LibraryEntry)
    case deleted
    case missing
    case destinationOccupied
    case conflict(currentStamp: FileStamp)
    case forensic(PromptWriteError)
    case readOnly(PromptReadOnlyReason)
    case failed(PromptEditingFailure)
    case cancelled, inactive, noSelection

    var committedEntry: LibraryEntry? {
        switch self {
        case .updated(let entry), .updatedButHistoryMaintenanceFailed(let entry): return entry
        default: return nil
        }
    }

    init(_ save: PromptSaveOutcome) {
        switch save {
        case .saved(let entry): self = .updated(entry)
        case .savedButHistoryMaintenanceFailed(let entry): self = .updatedButHistoryMaintenanceFailed(entry)
        case .conflict(let stamp): self = .conflict(currentStamp: stamp)
        case .deleted: self = .missing
        case .invalid: self = .forensic(.invalidPrompt)
        case .readOnly(let reason): self = .readOnly(reason)
        case .failed(let failure): self = .failed(failure)
        }
    }
}
