import Foundation

public enum LibrarySectionID: Hashable, Sendable {
    case all, favourites, recent, conflicts
    /// Exact relative path bytes, including each ancestor of a nested folder.
    case folder(RelativePath)
    /// Normalized like the picker's exact #tag filter.
    case tag(String)
    case group(ULID)
}

public struct LibraryBrowserSection: Equatable, Sendable {
    public let id: LibrarySectionID
    public let title: String
    public let count: Int
    public let parent: LibrarySectionID?
    public let depth: Int
    public var role: AssistantGroupRole? = nil
}

/// Identity follows assigned prompts across renames. The path disambiguates
/// duplicate ids and canonically equivalent but byte-distinct filenames.
public struct LibraryPromptSelection: Equatable, Sendable {
    public let identity: PromptIdentity
    public let relativePath: RelativePath

    public init(identity: PromptIdentity, relativePath: RelativePath) {
        self.identity = identity
        self.relativePath = relativePath
    }
}

public struct LibraryBrowserRow: Equatable, Sendable {
    public let selection: LibraryPromptSelection
    public var identity: PromptIdentity { selection.identity }
    public var relativePath: RelativePath { selection.relativePath }
    public let title: String
    public let folder: RelativePath
    public let tags: [String]
    public let favorite: Bool
    public let previewLine: String?
    public let issues: [PromptIssue]
    public let isReadOnly: Bool
    public let canRender: Bool
    public let stamp: FileStamp
    public let lastUsedAt: Date?
    public let access: PromptAccessState
    public let conflictOrigin: SyncPromptOrigin?
    public var conflictOf: ULID? {
        if case .conflictOf(let id) = conflictOrigin { return id }
        return nil
    }

    init(_ entry: LibraryEntry, lastUsedAt: Date?) {
        let front = entry.document.frontMatter
        selection = LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(entry.relativePath))
        title = front.title
        folder = RelativePath(entry.folder)
        tags = front.tags
        favorite = entry.favorite
        previewLine = front.description
        issues = entry.issues
        isReadOnly = entry.access.readOnlyReason != nil || entry.document.isReadOnly
            || issues.contains { $0.code == .invalidUTF8 || $0.code == .sourceTooLarge }
        canRender = !entry.document.isReadOnly && !issues.contains { $0.severity == .error }
        stamp = entry.stamp
        self.lastUsedAt = lastUsedAt
        access = entry.access
        conflictOrigin = entry.access == .local ? try? SyncConflictMetadata.origin(in: entry.document) : nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.title.utf8.elementsEqual(rhs.title.utf8)
            && lhs.folder == rhs.folder && lhs.tags == rhs.tags && lhs.favorite == rhs.favorite
            && lhs.previewLine == rhs.previewLine && lhs.issues == rhs.issues
            && lhs.isReadOnly == rhs.isReadOnly && lhs.canRender == rhs.canRender
            && lhs.stamp == rhs.stamp && lhs.lastUsedAt == rhs.lastUsedAt && lhs.access == rhs.access
            && lhs.conflictOrigin == rhs.conflictOrigin
    }
}

public struct LibraryBrowserState: Equatable, Sendable {
    public let sections: [LibraryBrowserSection]
    public let selectedSection: LibrarySectionID
    public let filter: String
    public let rows: [LibraryBrowserRow]
    public let selection: LibraryPromptSelection?
    /// Retained even when the section/filter hides its row. Browsing never
    /// silently chooses a different prompt for a future open editor.
    public let selectedPrompt: LibraryBrowserRow?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sections == rhs.sections && lhs.selectedSection == rhs.selectedSection
            && lhs.filter.utf8.elementsEqual(rhs.filter.utf8) && lhs.rows == rhs.rows
            && lhs.selection == rhs.selection && lhs.selectedPrompt == rhs.selectedPrompt
    }
}

public enum PromptFavoriteOutcome: Sendable {
    case saved(LibraryEntry)
    /// The open editor retains the toggle in its unsaved source.
    case editedBuffer
    /// The clean open editor owns the asynchronous save and its typed status.
    case savePending
    case noSelection
    case inactive
    case fileStoreFailure(FileStoreError)
    case libraryFailure(LibraryError)
    case writeFailure(PromptWriteError)
}
