import Foundation

struct ConflictResolutionContext {
    let binding: SyncLibraryIdentity
    let permit: SyncWorkPermit
    let client: SyncHTTPClient
    let states: SyncStateStore
    let accounts: SyncAccountStore
    let mutations: SyncLibraryMutations
    let journal: SyncApplyJournal
}

/// Explicit decisions use SyncService's single writer and durable apply journal.
/// No editor buffer or Assistant artifact participates in resolution.
public final class ConflictResolutionService {
    private let sync: SyncService

    public init(sync: SyncService) { self.sync = sync }

    public func preview(_ copy: LibraryPromptSelection) async throws -> ConflictPreview {
        try await sync.resolvingConflict { context in
            let file = try Self.copy(copy, in: context)
            return try await Self.preview(file, in: context)
        }
    }

    public func resolve(_ action: ConflictResolutionAction, preview: ConflictPreview) async throws -> ConflictResolutionResult {
        try await sync.resolvingConflict(epoch: preview.epoch) { [self] context in
            guard context.binding == preview.binding else { throw ConflictResolutionFailure.staleSession }
            try Self.check(preview, in: context)
            switch action {
            case .keepBoth:
                let bytes = try SyncConflictMetadata.settingOrigin(nil, in: preview.baseline.bytes,
                    filename: LibraryPath.filename(preview.baseline.path))
                try Self.commit(preview, bytes: bytes, in: context)
            case .keepServer:
                guard preview.canKeepServer else { throw ConflictResolutionFailure.originalUnavailable }
                // Discard only against the head the user actually inspected.
                let current = try await Self.preview(preview.baseline, in: context)
                if !Self.sameHead(preview.head, current.head) { return .refreshed(current) }
                try Self.check(preview, in: context)
                try Self.commit(preview, bytes: nil, in: context)
            case .keepMine:
                let current = try await Self.preview(preview.baseline, in: context)
                try Self.check(preview, in: context)
                if !Self.sameHead(preview.head, current.head) || preview.candidateBytes != current.candidateBytes {
                    return .refreshed(current)
                }
                guard preview.role == current.role else { throw ConflictResolutionFailure.staleAccess }
                if let refusal = current.mineRefusal { throw refusal }
                guard let head = current.head, let bytes = current.candidateBytes else {
                    throw ConflictResolutionFailure.invalidCandidate
                }
                // Durable sent facts are retained, but never automatically
                // retried. On an uncertain response the marked copy stays put.
                let attempt = Attempt(version: 1, account: context.binding.account, root: context.binding.root,
                    originalID: head.id.rawValue, scope: head.scope, path: head.path.string, baseRev: head.rev,
                    serverBytes: head.bytes, candidateBytes: bytes, copy: preview.baseline)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try context.permit.mutate { try context.journal.retainResolution(encoder.encode(attempt)) }
                try Self.check(preview, in: context)
                do {
                    let response = try await context.client.putPrompt(id: head.id, request: .init(baseRev: head.rev,
                        scope: Self.wireScope(head.scope), path: head.path.string,
                        content: String(decoding: bytes, as: UTF8.self)))
                    guard response.rev > head.rev else { throw SyncHTTPClientError.malformedResponse }
                } catch SyncHTTPClientError.conflict {
                    return .refreshed(try await Self.preview(preview.baseline, in: context))
                }
                // A changed copy/access/session can never be discarded by a
                // late acknowledgement. The server change is still committed.
                try Self.check(preview, in: context)
                try Self.commit(preview, bytes: nil, in: context)
            }
            sync.localSave()
            return .resolved(action)
        }
    }

    private struct Attempt: Encodable {
        let version: Int
        let account: SyncAccountIdentity
        let root: SyncLibraryRoot
        let originalID: String
        let scope: SyncScopeKey
        let path: String
        let baseRev: Int64
        let serverBytes: Data
        let candidateBytes: Data
        let copy: SyncLibraryFile
    }

    private static func state(_ context: ConflictResolutionContext) throws -> SyncState {
        try context.permit.check()
        guard let state = try context.states.load(for: context.binding) else { throw ConflictResolutionFailure.inactive }
        let access = context.mutations.accessSnapshot
        guard !access.isBlocked, access.binding == nil || access.binding == context.binding else {
            throw ConflictResolutionFailure.staleAccess
        }
        return state
    }

    private static func copy(_ selection: LibraryPromptSelection, in context: ConflictResolutionContext) throws -> SyncLibraryFile {
        let state = try state(context)
        guard case .assigned = selection.identity else { throw ConflictResolutionFailure.invalidCopy }
        let matches = try context.mutations.listedFiles().filter { try $0.identity == selection.identity }
        guard matches.count == 1, let file = matches.first,
              let location = SyncLocalScanner.location(of: RelativePath(file.path), binding: context.binding, groups: state.groups),
              location.scope == .user(context.binding.account.userID),
              state.prompts[selection.identity].map({ $0.scope == location.scope }) ?? true,
              try SyncConflictMetadata.origin(in: file.bytes, filename: LibraryPath.filename(file.path)) != nil else {
            throw ConflictResolutionFailure.invalidCopy
        }
        if let owned = try context.accounts.binding(for: context.binding.root),
           owned.owner != context.binding.account || owned.isHeld(identity: selection.identity,
                path: RelativePath(file.path), contentHash: file.hash) { throw ConflictResolutionFailure.accessDenied }
        return file
    }

    private static func check(_ preview: ConflictPreview, in context: ConflictResolutionContext) throws {
        try preview.validity.check()
        _ = try state(context)
        guard context.mutations.accessSnapshot.generation == preview.accessGeneration else {
            throw ConflictResolutionFailure.staleAccess
        }
        let file = try copy(preview.copy, in: context)
        guard RelativePath(file.path) == RelativePath(preview.baseline.path), file.stamp == preview.baseline.stamp,
              file.bytes == preview.baseline.bytes else { throw ConflictResolutionFailure.staleCopy }
    }

    private static func preview(_ file: SyncLibraryFile, in context: ConflictResolutionContext) async throws -> ConflictPreview {
        let state = try state(context)
        guard let origin = try SyncConflictMetadata.origin(in: file.bytes,
            filename: LibraryPath.filename(file.path)) else { throw ConflictResolutionFailure.invalidCopy }
        let original: ULID?
        if case .conflictOf(let id) = origin { original = id } else { original = nil }
        let access = context.mutations.accessSnapshot
        var head: SyncConflictHead?
        var role: SyncAPI.Role?
        var refusal: ConflictResolutionFailure? = original == nil ? .originalUnavailable : nil
        if let original {
            do {
                let value = try await context.client.prompt(id: original)
                let checked = try SyncConflictHead(value, userID: context.binding.account.userID)
                guard checked.id == original else { throw SyncHTTPClientError.malformedResponse }
                head = checked
                if case .group(let id) = checked.scope {
                    let me = try await context.client.me()
                    guard me.user.id == context.binding.account.userID.rawValue else { throw SyncHTTPClientError.malformedResponse }
                    role = me.groups.first { $0.groupID == id.rawValue }?.role
                    if role == nil || role == .viewer || state.groups[id] == nil || state.groups[id]?.role == .viewer {
                        refusal = .accessDenied
                    }
                }
            } catch SyncHTTPClientError.notFound { refusal = .originalUnavailable }
            catch SyncHTTPClientError.deleted { refusal = .originalUnavailable }
            catch SyncHTTPClientError.forbidden { refusal = .accessDenied }
        }

        var candidate: Data?
        var diff: ArtifactDiff?
        if let head {
            do {
                let filename = LibraryPath.filename(head.path.string)
                let unmarked = try SyncConflictMetadata.settingOrigin(nil, in: file.bytes, filename: filename)
                let document = PromptCodec.parseFile(unmarked, filename: filename)
                let replaced = try ImportMapper.replacingIdentity(head.id, in: document, filename: filename).document
                let bytes = Data(replaced.source.utf8)
                let validated = try SyncLocalScanner.canonical(bytes, path: head.path, scope: head.scope).bytes
                candidate = validated
                diff = try ArtifactDiff.compare(originalBytes: head.bytes, candidateBytes: validated)
            } catch { refusal = .invalidCandidate }
        }
        let result = ConflictPreview(id: UUID(), copy: LibraryPromptSelection(identity: try file.identity,
            relativePath: RelativePath(file.path)), originalID: original, serverBytes: head?.bytes,
            candidateBytes: candidate, diff: diff, mineRefusal: refusal, baseline: file, head: head,
            binding: context.binding, epoch: context.permit.epoch, accessGeneration: access.generation, role: role)
        try check(result, in: context)
        return result
    }

    private static func commit(_ preview: ConflictPreview, bytes: Data?, in context: ConflictResolutionContext) throws {
        try check(preview, in: context)
        let state = try state(context)
        var next = state
        let edit: SyncLibraryEdit
        if let bytes {
            let identity = try preview.baseline.identity
            edit = try context.mutations.publication(bytes, at: preview.copy.relativePath, expecting: preview.baseline,
                transition: SyncIdentityTransition(from: identity, to: identity))
            if let record = next.prompts[identity] {
                // Keep the acknowledged hash/rev, so personal sync sends this edit.
                next.prompts[identity] = try SyncPromptState(scope: record.scope, path: record.path,
                    rev: record.rev, canonicalHash: record.canonicalHash, origin: nil)
            }
        } else {
            edit = try context.mutations.trash(preview.baseline)
            // Retain its acknowledged record until personal DELETE succeeds.
        }
        let result = try context.journal.apply(.init(expectedState: state, nextState: next, edits: [edit]), permit: context.permit)
        guard result == .committed else { throw ConflictResolutionFailure.recoveryRequired }
    }

    private static func sameHead(_ lhs: SyncConflictHead?, _ rhs: SyncConflictHead?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.id == rhs.id && lhs.rev == rhs.rev && lhs.scope == rhs.scope && lhs.path == rhs.path && lhs.bytes == rhs.bytes
    }

    private static func wireScope(_ scope: SyncScopeKey) -> SyncAPI.PromptScope {
        switch scope { case .user: return .user; case .group(let id): return .group(groupID: id.rawValue) }
    }

    static func failure(_ error: Error) -> ConflictResolutionFailure {
        if let error = error as? ConflictResolutionFailure { return error }
        switch error {
        case SyncHTTPClientError.unauthorized: return .needsSignIn
        case SyncHTTPClientError.forbidden: return .accessDenied
        case SyncHTTPClientError.notFound, SyncHTTPClientError.deleted: return .originalUnavailable
        case SyncHTTPClientError.transport(.cancelled), is CancellationError: return .inactive
        case SyncHTTPClientError.transport, SyncHTTPClientError.serverFailure, SyncHTTPClientError.rateLimited: return .offline
        case is SyncError, is SyncFileOperationError: return .recoveryRequired
        default: return .operationFailed
        }
    }
}
