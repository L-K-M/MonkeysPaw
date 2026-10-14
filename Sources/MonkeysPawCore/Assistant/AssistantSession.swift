import Foundation

public enum AssistantEditorAvailability: Equatable, Sendable { case available, busy, conflicted }

/// Exact editor buffer, never its rendered preview or fill-session values.
public struct AssistantEditorSnapshot: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let sourceBytes: Data
    public let relativePath: RelativePath
    public let revision: UInt64
    public let session: PromptEditingSession
    public let stamp: FileStamp
    public let availability: AssistantEditorAvailability
    public let accessGeneration: UInt64

    init(source: String, relativePath: RelativePath, revision: UInt64,
         session: PromptEditingSession, stamp: FileStamp, availability: AssistantEditorAvailability = .available,
         accessGeneration: UInt64 = 0) {
        sourceBytes = Data(source.utf8)
        self.relativePath = relativePath
        self.revision = revision
        self.session = session
        self.stamp = stamp
        self.availability = availability
        self.accessGeneration = accessGeneration
    }

    var source: String { String(decoding: sourceBytes, as: UTF8.self) }
    var document: PromptDocument { PromptCodec.parseFile(sourceBytes, filename: LibraryPath.filename(relativePath.string)) }

    /// Guard scheduling changes availability without changing the preview.
    /// The editor separately checks I/O before starting an acceptance save.
    static func matchesForAcceptance(_ lhs: Self?, _ rhs: Self?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.availability != .conflicted && rhs.availability != .conflicted
                && lhs.sourceBytes == rhs.sourceBytes && lhs.relativePath == rhs.relativePath
                && lhs.revision == rhs.revision && lhs.session == rhs.session && lhs.stamp == rhs.stamp
                && lhs.accessGeneration == rhs.accessGeneration
        default: return false
        }
    }

    public var description: String { "<assistant editor snapshot redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["snapshot": description]) }
}

/// Composition supplies a stable graph ID and forwards editor/profile/access
/// changes, including switching away and back. No secrets are carried here.
public struct AssistantContext: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let libraryID: UUID
    public let profile: ProviderProfile?
    public let editor: AssistantEditorSnapshot?
    public let access: AssistantAccessState

    public init(libraryID: UUID, profile: ProviderProfile?, editor: AssistantEditorSnapshot? = nil,
                access: AssistantAccessState = .privatePrompt) {
        self.libraryID = libraryID
        self.profile = profile
        self.editor = editor
        self.access = access
    }

    func sameSession(as other: Self) -> Bool {
        libraryID == other.libraryID && Self.sameProfile(profile, other.profile)
            && editor?.session == other.editor?.session && access == other.access
            && editor?.accessGeneration == other.editor?.accessGeneration
    }

    func matchesForAcceptance(_ other: Self) -> Bool {
        sameSession(as: other) && AssistantEditorSnapshot.matchesForAcceptance(editor, other.editor)
    }

    static func sameProfile(_ lhs: ProviderProfile?, _ rhs: ProviderProfile?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.baseURL == rhs.baseURL
                && lhs.modelID.utf8.elementsEqual(rhs.modelID.utf8)
                && lhs.secretReference == rhs.secretReference
                && lhs.displayName.utf8.elementsEqual(rhs.displayName.utf8)
        default: return false
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.sameSession(as: rhs) && lhs.editor == rhs.editor }
    public var description: String { "<assistant context redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["context": description]) }
}

public enum AssistantCommand: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case write(brief: String)
    case review
    case improve(instruction: String, selectedFindings: [LlmReview.Finding])

    var isReview: Bool { if case .review = self { return true }; return false }

    func action(in context: AssistantContext) throws -> AssistantAction {
        switch self {
        case .write(let brief): return .write(brief: brief)
        case .review:
            guard let editor = context.editor else { throw AssistantFailure.noEditor }
            return .review(source: editor.source)
        case .improve(let instruction, let findings):
            guard let editor = context.editor else { throw AssistantFailure.noEditor }
            return .improve(source: editor.source, instruction: instruction, selectedFindings: findings)
        }
    }

    public var description: String { "<assistant command redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["command": description]) }
}

/// Sanitized local failures complement the clients' body-free errors.
public enum AssistantFailure: Error, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case assistant(AssistantError)
    case settings(ProviderSettingsError)
    case invalid([PromptIssue])
    case readOnly(PromptReadOnlyReason)
    case write(PromptWriteError)
    case identity(ULIDGenerationError)
    case diff(LineDiffError)
    case noEditor
    case editorBusy
    case editorConflict
    case staleContext

    public var description: String { "<assistant failure>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["failure": description]) }
}

/// Final canonical bytes and their displayed diff. Accept must save these bytes
/// through the existing editing checks; notes/transcripts are deliberately absent.
public struct AssistantCandidate: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let content: ArtifactMergeCandidate
    public let diff: ArtifactDiff
    public let context: AssistantContext
    public let mutationAccess: AssistantMutationAccess

    public var description: String { "<assistant candidate redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["candidate": description]) }
}

/// A11 consumes this intent and reports its checked save/provenance outcome.
public struct AssistantAcceptance: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public let candidate: AssistantCandidate
    public let usage: AssistantTokenUsage?

    public var description: String { "<assistant acceptance redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["acceptance": description]) }
}

/// Completion and attached task lifetimes share one lock. Cancelling also
/// completes promptly while a native credential read cannot itself be stopped.
public final class AssistantOperation<Value>: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var completion: ((Result<Value, AssistantFailure>) -> Void)?

    init(main: MainThread, completion: @escaping (Result<Value, AssistantFailure>) -> Void) {
        self.completion = { result in main.run { completion(result) } }
    }

    public func cancel() { finish(.failure(.assistant(.transport(.cancelled)))) }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        if completion != nil { tasks.append(task); lock.unlock() }
        else { lock.unlock(); task.cancel() }
    }

    func finish(_ result: Result<Value, AssistantFailure>) {
        lock.lock()
        guard let completion else { lock.unlock(); return }
        self.completion = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        completion(result)
    }

    public var description: String { "<assistant operation>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["operation": description]) }
}
