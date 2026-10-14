import Foundation

/// Composition supplies the exact absolute library root and, when signed in,
/// the canonical server/user identity. No credential participates in this key.
public struct RepeatBinding: Equatable, Sendable, Codable, CustomStringConvertible, CustomReflectable {
    private let root: SyncLibraryRoot
    private let account: SyncAccountIdentity?

    public init(root: String, serverURL: String? = nil, userID: ULID? = nil) throws {
        do {
            self.root = try SyncLibraryRoot(root)
            switch (serverURL, userID) {
            case (nil, nil): account = nil
            case (.some(let url), .some(let id)): account = try SyncAccountIdentity(serverURL: url, userID: id)
            default: throw RepeatFailure.invalidBinding
            }
        } catch { throw RepeatFailure.invalidBinding }
    }

    public var description: String { "<repeat binding>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum RepeatFailure: String, Error, Sendable {
    case invalidBinding, corruptRecord, futureRecord, recordTooLarge
    case readFailed, writeFailed, invalidationFailed, inactive, ownWindow
}

public enum RepeatReviewReason: String, Sendable {
    case sourceChanged, sourceUnavailable, sessionOnlyValues
}

/// A reopening hint only. Never use the hint as an assigned identity resolver.
public struct RepeatPromptReference: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: PromptIdentity
    public let relativePath: String

    public var description: String { "<repeat prompt>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }
}

public enum RepeatAvailability: Equatable, Sendable {
    case ready
    case nothingToRepeat
    case reviewRequired(RepeatPromptReference, RepeatReviewReason)
    case unavailable(RepeatFailure)
}

public enum RepeatResult: Equatable, Sendable {
    case delivered(DeliveryOutcome, [PromptPersistenceWarning])
    case nothingToRepeat
    case reviewRequired(RepeatPromptReference, RepeatReviewReason)
    case unavailable(RepeatFailure)
    case cancelled
}

/// The disk projection deliberately cannot hold rendered text or builtins.
struct LastDeliveryRecord: Codable, CustomStringConvertible, CustomReflectable {
    let binding: RepeatBinding
    let identityKey: String
    let relativePath: String
    let sourceFingerprint: String
    let idlessStamp: FileStamp?
    let rememberedValues: [String: String]
    let requiresSessionValues: Bool
    let copyOnly: Bool

    var identity: PromptIdentity { get throws { try SyncIdentifiers.promptIdentity(identityKey) } }
    var reference: RepeatPromptReference {
        get throws { try RepeatPromptReference(identity: identity, relativePath: relativePath) }
    }

    init(binding: RepeatBinding, entry: LibraryEntry, values: [String: String], mode: DeliveryMode) throws {
        self.binding = binding
        identityKey = try entry.identity.storageKey
        relativePath = entry.relativePath
        sourceFingerprint = SHA256.hexDigest(Data(entry.document.source.utf8))
        if case .local = entry.identity { idlessStamp = entry.stamp }
        else { idlessStamp = nil }
        let fields = entry.document.effectiveFields
        let rememberedNames = Set(fields.filter(\.remember).map(\.name))
        rememberedValues = values.filter { rememberedNames.contains($0.key) }
        requiresSessionValues = fields.contains { !$0.remember }
        copyOnly = mode == .copyOnly
    }

    func validate() throws {
        try LibraryPath.validate(relativePath)
        _ = try SyncHash(sourceFingerprint)
        switch try identity {
        case .local:
            guard idlessStamp != nil, try identity == PromptIdentity(path: relativePath, id: nil) else {
                throw RepeatFailure.corruptRecord
            }
        case .assigned:
            guard idlessStamp == nil else { throw RepeatFailure.corruptRecord }
        }
        guard rememberedValues.keys.allSatisfy({ Template.isValidName($0) && !Template.isReserved($0) }) else {
            throw RepeatFailure.corruptRecord
        }
    }

    var description: String { "<last delivery record>" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A ticket predates builtin/file work; boundaries revoke it before clearing.
struct RepeatRecording: Sendable { let epoch: UInt64 }
