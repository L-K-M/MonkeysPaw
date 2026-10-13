import Foundation

enum SyncConflictPolicyError: Error, Equatable {
    case invalidIntent
    case invalidHead
    case invalidResponse
}

/// Y8 journals these exact request facts before HTTP. A later local read must
/// never replace sentBytes/sentHash when deciding whether an acknowledgement was lost.
struct SyncConflictIntent: CustomStringConvertible, CustomReflectable {
    let id: ULID
    let operation: SyncOperation
    let baseRev: Int64
    let scope: SyncScopeKey
    let path: RelativePath
    let sentBytes: Data?
    let sentHash: SyncHash?
    let fingerprint: SyncInputFingerprint
    var description: String { "<sync conflict intent>" }
    var customMirror: Mirror { Mirror(self, children: ["intent": description]) }

    /// For /move, sentBytes is the *moved server baseline*, canonicalized for
    /// the destination, or nil until known. It is not an accompanying local edit.
    init(id: ULID, operation: SyncOperation, baseRev: Int64, scope: SyncScopeKey, path: RelativePath,
         sentBytes: Data?, inputBytes: Data, accessGeneration: Int64) throws {
        guard baseRev >= 0, operation == .put || baseRev > 0,
              operation != .put || sentBytes != nil,
              operation != .delete || sentBytes == nil,
              let wire = try? SyncPathValidator.validate(path.string, scope: scope.pathScope),
              wire.path.utf8.elementsEqual(path.string.utf8) else { throw SyncConflictPolicyError.invalidIntent }
        if let sentBytes {
            let filename = LibraryPath.filename(path.string)
            let form = try scope.pathScope == .user ? CanonicalForm.user(sentBytes, filename: filename)
                : CanonicalForm.group(sentBytes, filename: filename)
            guard form.bytes == sentBytes, PromptCodec.parseFile(sentBytes, filename: filename).frontMatter.id == id else {
                throw SyncConflictPolicyError.invalidIntent
            }
            _ = try SyncConflictMetadata.origin(in: sentBytes, filename: filename, scope: scope.pathScope)
        }
        self.id = id
        self.operation = operation
        self.baseRev = baseRev
        self.scope = scope
        self.path = path
        self.sentBytes = sentBytes
        sentHash = sentBytes.map(SyncHash.init(bytes:))
        fingerprint = try SyncInputFingerprint(bytes: inputBytes, path: path, scope: scope,
                                               accessGeneration: accessGeneration, operation: operation)
    }
}

struct SyncConflictHead: CustomStringConvertible, CustomReflectable {
    let id: ULID
    let rev: Int64
    let scope: SyncScopeKey
    let path: RelativePath
    let bytes: Data
    let hash: SyncHash
    let origin: SyncPromptOrigin?
    var description: String { "<sync conflict head>" }
    var customMirror: Mirror { Mirror(self, children: ["head": description]) }

    init(_ prompt: SyncAPI.Prompt, userID: ULID) throws {
        do {
            id = try SyncIdentifiers.ulid(prompt.id)
            switch prompt.scope {
            case .user: scope = .user(userID)
            case .group(let group): scope = .group(try SyncIdentifiers.ulid(group))
            }
            let wire = try SyncPathValidator.validate(prompt.path, scope: scope.pathScope)
            guard wire.path.utf8.elementsEqual(prompt.path.utf8), prompt.rev > 0 else {
                throw SyncConflictPolicyError.invalidHead
            }
            path = RelativePath(prompt.path)
            bytes = Data(prompt.content.utf8)
            let filename = LibraryPath.filename(prompt.path)
            let form = try scope.pathScope == .user ? CanonicalForm.user(bytes, filename: filename)
                : CanonicalForm.group(bytes, filename: filename)
            guard form.bytes == bytes, PromptCodec.parseFile(bytes, filename: filename).frontMatter.id == id else {
                throw SyncConflictPolicyError.invalidHead
            }
            rev = prompt.rev
            hash = SyncHash(bytes: bytes)
            origin = try SyncConflictMetadata.origin(in: bytes, filename: filename, scope: scope.pathScope)
        } catch { throw SyncConflictPolicyError.invalidHead }
    }
}

enum SyncConflictOutcome: CustomStringConvertible, CustomReflectable {
    /// Adopt this baseline and leave any newer local edit dirty, without a copy.
    case acknowledged(SyncConflictHead)
    /// Install at the head's authoritative scope/path; preserve local if present.
    /// A nil local also covers local-delete versus remote-edit.
    case serverWins(head: SyncConflictHead, local: SyncLibraryFile?)
    case remoteDeleted(local: SyncLibraryFile?)
    case deleteSucceeded
    case clashRename(RelativePath)
    /// Create path_taken equality is identity-neutral; Y7 journals adoption.
    case adoptExisting(SyncConflictHead)
    /// Always refresh memberships. This outcome says nothing about viewer role.
    case denied(restore: SyncConflictHead?, local: SyncLibraryFile?, error: SyncPromptError)
    case fileError(SyncPromptError)
    var description: String { "<sync conflict outcome>" }
    var customMirror: Mirror { Mirror(self, children: ["outcome": description]) }
}

struct SyncConflictCopyCandidate {
    let scope: SyncScopeKey
    let file: SyncLibraryFile
}

enum SyncConflictPolicy {
    static func shouldAttempt(_ fingerprint: SyncInputFingerprint, lastError: SyncPromptError?) -> Bool {
        lastError?.fingerprint != fingerprint
    }

    /// Returns nil for transport/auth/protocol errors owned by the pass engine.
    /// All decisions are plans: Y8 applies them through Y2's checked journal.
    static func resolve(_ error: SyncHTTPClientError, intent: SyncConflictIntent, userID: ULID,
                        local: SyncLibraryFile?, recorded: SyncPromptState? = nil,
                        accessibleHead: SyncAPI.Prompt? = nil, occupiedPaths: [RelativePath] = []) throws -> SyncConflictOutcome? {
        if case .user(let owner) = intent.scope, owner != userID { throw SyncConflictPolicyError.invalidIntent }
        try local?.validate()
        if let local, try local.identity != .assigned(intent.id) { throw SyncConflictPolicyError.invalidIntent }
        switch error {
        case .conflict(let envelope):
            let head = try SyncConflictHead(SyncAPI.Prompt(id: intent.id.rawValue, rev: envelope.rev,
                scope: envelope.scope, path: envelope.path, content: envelope.content), userID: userID)
            if intent.operation != .delete, head.rev > intent.baseRev, head.scope == intent.scope,
               head.path == intent.path, head.hash == intent.sentHash, head.bytes == intent.sentBytes {
                return .acknowledged(head)
            }
            return .serverWins(head: head, local: local)
        case .pathTaken(let existing):
            guard intent.operation != .delete else { throw SyncConflictPolicyError.invalidResponse }
            if intent.operation == .put, intent.baseRev == 0, let sent = intent.sentBytes {
                let head = try SyncConflictHead(SyncAPI.Prompt(id: existing.id, rev: existing.rev,
                    scope: wireScope(intent.scope), path: intent.path.string, content: existing.content), userID: userID)
                if try CanonicalForm.equivalentForAdoption(sent, head.bytes,
                    scope: intent.scope.pathScope == .user ? .user : .group, filename: LibraryPath.filename(intent.path.string)) {
                    return .adoptExisting(head)
                }
            }
            do { return .clashRename(try SyncNaming.clash(intent.path, scope: intent.scope.pathScope, occupiedPaths: occupiedPaths)) }
            catch SyncNamingError.exhausted { return .fileError(.init(code: .pathClash, fingerprint: intent.fingerprint)) }
        case .deleted:
            return intent.operation == .delete ? .deleteSucceeded : .remoteDeleted(local: local)
        case .notFound:
            if intent.operation == .delete { return .deleteSucceeded }
            return .fileError(.init(code: .notFound, fingerprint: intent.fingerprint))
        case .forbidden:
            var restore: SyncConflictHead?
            if let recorded, recorded.rev > 0, let accessibleHead {
                let head = try SyncConflictHead(accessibleHead, userID: userID)
                // A create or a head belonging elsewhere cannot authorize rollback.
                if intent.baseRev > 0, head.id == intent.id, head.scope == recorded.scope, head.path == recorded.path {
                    restore = head
                }
            }
            return .denied(restore: restore, local: local, error: .init(code: .forbidden, fingerprint: intent.fingerprint))
        case .validation(let issues):
            guard let issue = issues.first, issue.severity == .error, let code = issueCode(issue.code) else {
                throw SyncConflictPolicyError.invalidResponse
            }
            return .fileError(.init(code: code, fingerprint: intent.fingerprint))
        default: return nil
        }
    }

    /// Choose once, before journal creation. Replays use the resulting edit,
    /// never a fresh timestamp/ID. Candidates are current private file baselines.
    static func copy(_ file: SyncLibraryFile, origin requested: SyncPromptOrigin, userID: ULID,
                     groupFolder: String? = nil, device: String, at date: Date, freshID: ULID,
                     occupiedPaths: [RelativePath], existingCopies: [SyncConflictCopyCandidate] = [],
                     mutations: SyncLibraryMutations) throws -> SyncReconciliationCopy {
        try file.validate()
        let document = PromptCodec.parseFile(file.bytes, filename: LibraryPath.filename(file.path))
        let previous = try? SyncConflictMetadata.origin(in: document)
        let origin: SyncPromptOrigin
        switch requested {
        case .rescued: origin = .rescued
        case .conflictOf: origin = previous ?? requested
        }
        for candidate in existingCopies.sorted(by: { RelativePath($0.file.path) < RelativePath($1.file.path) }) {
            let current = candidate.file
            guard candidate.scope == .user(userID), RelativePath(current.path) != RelativePath(file.path),
                  let identity = try? current.identity, case .assigned(let id) = identity,
                  id != document.frontMatter.id,
                  (try? SyncConflictMetadata.origin(in: current.bytes, filename: LibraryPath.filename(current.path))) == origin,
                  let expected = try? SyncConflictMetadata.copyBytes(file, freshID: id, origin: origin,
                                                                    filename: LibraryPath.filename(current.path)),
                  expected == current.bytes else { continue }
            try current.validate()
            let edit = try mutations.publication(current.bytes, at: RelativePath(current.path), expecting: current,
                transition: SyncIdentityTransition(from: identity, to: identity))
            return SyncReconciliationCopy(edit: edit, origin: origin)
        }
        let destination: RelativePath
        switch requested {
        case .rescued: destination = try SyncNaming.rescue(source: RelativePath(file.path), at: date, occupiedPaths: occupiedPaths)
        case .conflictOf: destination = try SyncNaming.conflict(source: RelativePath(file.path), groupFolder: groupFolder,
                                                               device: device, at: date, occupiedPaths: occupiedPaths)
        }
        let edit = try mutations.rescue(file, at: destination, freshID: freshID, origin: origin)
        return SyncReconciliationCopy(edit: edit, origin: origin)
    }

    private static func wireScope(_ scope: SyncScopeKey) -> SyncAPI.PromptScope {
        switch scope {
        case .user: return .user
        case .group(let id): return .group(groupID: id.rawValue)
        }
    }

    private static func issueCode(_ raw: String) -> SyncIssueCode? {
        if let code = PromptIssueCode(rawValue: raw) { return .content(code) }
        if let code = SyncPathIssueCode(rawValue: raw) { return .path(code) }
        return raw == "prompt.id_mismatch" ? .idMismatch : nil
    }
}
