import Foundation

public enum ImportRequest: Equatable, Sendable {
    case files([String])
    case folder(String)
}

public enum ImportFormat: String, Sendable {
    case markdown, dotprompt, prompty

    static func filename(_ filename: String) -> Self? {
        if filename.hasSuffix(".md") { return .markdown }
        if filename.hasSuffix(".prompt") { return .dotprompt }
        if filename.hasSuffix(".prompty") { return .prompty }
        return nil
    }
}

public struct ImportFieldMapping: Equatable, Sendable {
    public let sourceKey: String
    public let fieldName: String
    public let kind: FieldKind
    /// The original property supplying the default, never the field value.
    public let defaultSource: String?
}

public enum ImportWarning: Equatable, Sendable {
    case unsupportedInput(String)
    case invalidName(String)
    case reservedName(String)
    case fieldCollision(String)
    case invalidOptions(String)
    case invalidDefault(String)
    case invalidDescription(String)
    case unsupportedTemplate(ImportFormat, byteOffset: Int)
    case validation(PromptIssueCode)
    case identityReassigned
}

public enum ImportLoss: String, Sendable {
    /// Canonical YAML retains metadata values, but not comments or styling.
    case frontMatterPresentation
}

public struct ImportMappingReport: Equatable, Sendable {
    public internal(set) var mappings: [ImportFieldMapping] = []
    public internal(set) var preservedKeys: [String] = []
    public internal(set) var dropped: [ImportLoss] = []
    public internal(set) var warnings: [ImportWarning] = []

    init() {}
}

/// Content is immutable and comes only from the codec's validated YAML tree.
public struct ImportMappingResult {
    public let document: PromptDocument
    public let report: ImportMappingReport
}

public enum ImportSkipReason: Error, Equatable, Sendable {
    case unsupportedExtension
    case fileTooLarge
    case invalidUTF8
    case invalidPrompt([PromptIssueCode])
    case unsupportedFormat(PromptFormatVersion)
    case convertedTooLarge
    case invalidPath
    case symbolicLink
    case notRegularFile
    case duplicateSource
    case source(ImportSourceError)
    case fileStore(FileStoreError)
    case library(LibraryError)
    case identityGeneration(ULIDGenerationError)
    case identityLimitReached
}

public enum ImportFileOutcome: Equatable, Sendable {
    case created(path: String)
    case skipped(ImportSkipReason)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.created(let a), .created(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.skipped(let a), .skipped(let b)): return a == b
        default: return false
        }
    }
}

public struct ImportFileReport: Equatable, Sendable {
    public let sourcePath: String
    public let outcome: ImportFileOutcome
    public let mapping: ImportMappingReport

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourcePath.utf8.elementsEqual(rhs.sourcePath.utf8)
            && lhs.outcome == rhs.outcome && lhs.mapping == rhs.mapping
    }
}

public struct ImportReport: Equatable, Sendable {
    public let files: [ImportFileReport]
    /// A selection/enumeration/destination failure before any file is read.
    public let failure: ImportSkipReason?
    public var createdCount: Int {
        files.filter { if case .created = $0.outcome { return true }; return false }.count
    }
    public var skippedCount: Int { files.count - createdCount }
}

public enum ImportProgress: Equatable, Sendable {
    case enumerating
    case importing(completed: Int, total: Int)
}
