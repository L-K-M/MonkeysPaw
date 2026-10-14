import Foundation

enum SyncAdoptionDecision: CustomStringConvertible, CustomReflectable {
    case adopt(remote: SyncReconciliationRemote, local: SyncLibraryFile)
    case conflict(remote: SyncReconciliationRemote, local: SyncLibraryFile)
    case clash(remote: SyncReconciliationRemote, occupant: SyncLibraryFile)
    case held(RelativePath)
    case localVisibility(SyncReconciliationRemote)
    case unmatched
    /// The attempted incarnation disappeared or changed identity during HTTP.
    case replan
    var description: String { "<sync adoption decision>" }
    var customMirror: Mirror { Mirror(self, children: ["decision": description]) }
}

enum SyncAdoption {
    /// ID matches precede path matches, across all currently accessible scopes.
    /// A different ID is adopted only at the same scope/path_key with B5 equality.
    static func match(_ remote: SyncReconciliationRemote, local: SyncReconciliationSnapshot,
                      groups: [ULID: SyncGroupState]) throws -> SyncAdoptionDecision {
        try validate(remote, binding: local.binding, groups: groups)
        guard case .available = local.availability else { throw SyncReconciliationError.unavailableLibrary }
        guard LibraryPath.isPrompt(remote.libraryPath.string) else { return .localVisibility(remote) }
        guard !local.files.contains(where: {
            SyncLocalScanner.location(of: RelativePath($0.path), binding: local.binding, groups: groups) == nil
        }) else { throw SyncReconciliationError.requiresPolicy }
        for file in local.files { try file.validate() }
        let targets = try local.files.filter {
            try SyncNaming.pathKey(RelativePath($0.path)) == SyncNaming.pathKey(remote.libraryPath)
        }.sorted { RelativePath($0.path) < RelativePath($1.path) }
        if let target = targets.first(where: { isHeld($0, in: local) }) { return .held(RelativePath(target.path)) }
        if targets.count > 1 { return .clash(remote: remote, occupant: targets[0]) }
        let owners = local.files.filter { $0.identityKey == remote.id.rawValue && !isHeld($0, in: local) }
        guard owners.count <= 1 else { throw SyncReconciliationError.invalidLocalSnapshot }
        if let owner = owners.first {
            if let target = targets.first, RelativePath(target.path) != RelativePath(owner.path) {
                return .clash(remote: remote, occupant: target)
            }
            return try equivalent(owner.bytes, remote: remote) ? .adopt(remote: remote, local: owner)
                : .conflict(remote: remote, local: owner)
        }
        guard let target = targets.first,
              let location = SyncLocalScanner.location(of: RelativePath(target.path), binding: local.binding, groups: groups),
              location.scope == remote.scope,
              try SyncNaming.pathKey(location.path) == SyncNaming.pathKey(remote.path) else { return .unmatched }
        return try equivalent(target.bytes, remote: remote) ? .adopt(remote: remote, local: target)
            : .clash(remote: remote, occupant: target)
    }

    /// Y8 calls this with a fresh full scan after a create's path_taken reply.
    /// Compare the exact sent version first, then the current local incarnation;
    /// a later edit is never overwritten as an acknowledgement of old bytes.
    static func pathTaken(_ existing: SyncAPI.ExistingPrompt, intent: SyncConflictIntent,
                          local: SyncReconciliationSnapshot, groups: [ULID: SyncGroupState]) throws -> SyncAdoptionDecision {
        guard intent.operation == .put, intent.baseRev == 0, let sent = intent.sentBytes else {
            throw SyncConflictPolicyError.invalidIntent
        }
        let id = try SyncIdentifiers.ulid(existing.id)
        let bytes = Data(existing.content.utf8)
        let path = try SyncLocalScanner.rooted(intent.path, scope: intent.scope, groups: groups)
        let mode: SyncFileMode
        if case .group(let group) = intent.scope, groups[group]?.role == .viewer { mode = .readOnly }
        else { mode = .normal }
        let remote = SyncReconciliationRemote(id: id, scope: intent.scope, path: intent.path, libraryPath: path,
            rev: existing.rev, bytes: bytes, hash: SyncHash(bytes: bytes), mode: mode)
        try validate(remote, binding: local.binding, groups: groups)
        guard case .available = local.availability else { throw SyncReconciliationError.unavailableLibrary }
        let owners = local.files.filter { $0.identityKey == intent.id.rawValue }
        guard owners.count <= 1 else { throw SyncReconciliationError.invalidLocalSnapshot }
        guard let file = owners.first else { return .replan }
        if isHeld(file, in: local) { return .held(RelativePath(file.path)) }
        guard let location = SyncLocalScanner.location(of: RelativePath(file.path), binding: local.binding, groups: groups),
              location.scope == intent.scope, try SyncNaming.pathKey(location.path) == SyncNaming.pathKey(intent.path) else {
            return .replan
        }
        guard try equivalent(sent, remote: remote), try equivalent(file.bytes, remote: remote) else {
            return .clash(remote: remote, occupant: file)
        }
        return try match(remote, local: local, groups: groups)
    }

    /// Preparatory adoption uses the old database/cursors. Reconcile the complete
    /// pull again after this journal commits; only then may its cursors advance.
    static func application(_ decision: SyncAdoptionDecision, state: SyncState?,
                            local: SyncReconciliationSnapshot, groups: [ULID: SyncGroupState],
                            device: String, at date: Date, freshID: () throws -> ULID,
                            mutations: SyncLibraryMutations) throws -> SyncApplyPlan {
        guard state == nil || state?.binding == local.binding else { throw SyncError.bindingMismatch }
        var next = try state ?? SyncState(binding: local.binding, groups: groups)
        // Y9 allocates folders before adoption of a newly joined group.
        next.groups = groups
        let remote: SyncReconciliationRemote
        let source: SyncLibraryFile
        let losing: Bool
        switch decision {
        case .adopt(let head, let file): remote = head; source = file; losing = false
        case .conflict(let head, let file): remote = head; source = file; losing = true
        default: throw SyncReconciliationError.requiresPolicy
        }
        // Re-evaluate the decision instead of accepting a hand-built or stale
        // alternative-ID overwrite, or an ID hidden by an account/raw hold.
        switch try match(remote, local: local, groups: groups) {
        case .adopt(_, let file) where !losing && same(file, source): break
        case .conflict(_, let file) where losing && same(file, source): break
        default: throw SyncReconciliationError.requiresPolicy
        }
        let identity = try source.identity
        let destination = PromptIdentity.assigned(remote.id)
        if identity != destination, let old = next.prompts[identity], old.rev > 0 {
            throw SyncReconciliationError.requiresPolicy
        }
        var edits: [SyncLibraryEdit] = []
        if losing {
            var occupied = Set(local.files.map { RelativePath($0.path) })
            occupied.insert(remote.libraryPath)
            let candidates = local.files.compactMap { file -> SyncConflictCopyCandidate? in
                let path = RelativePath(file.path)
                guard !isHeld(file, in: local), let location = SyncLocalScanner.location(of: path,
                    binding: local.binding, groups: groups) else { return nil }
                return SyncConflictCopyCandidate(scope: location.scope, file: file)
            }
            let id = try freshID()
            guard !local.files.contains(where: { $0.identityKey == id.rawValue }), next.prompts[.assigned(id)] == nil else {
                throw SyncError.invalidState
            }
            let location = SyncLocalScanner.location(of: RelativePath(source.path), binding: local.binding, groups: groups)
            let folder: String?
            if case .group(let group) = location?.scope { folder = groups[group]?.folder }
            else { folder = nil }
            let copy = try SyncConflictPolicy.copy(source, origin: .conflictOf(remote.id),
                userID: local.binding.account.userID, groupFolder: folder, device: device, at: date, freshID: id,
                occupiedPaths: Array(occupied), existingCopies: candidates,
                excludingPaths: [RelativePath(source.path), remote.libraryPath], mutations: mutations)
            guard copy.edit.heldIssue == nil, let bytes = copy.edit.bytes,
                  let copyID = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(copy.edit.path)).frontMatter.id else {
                throw SyncReconciliationError.requiresPolicy
            }
            let key = PromptIdentity.assigned(copyID)
            let remembered = next.prompts[key]
            next.prompts[key] = try SyncPromptState(scope: .user(local.binding.account.userID),
                path: remembered?.path ?? RelativePath(copy.edit.path), rev: remembered?.rev ?? 0,
                canonicalHash: remembered?.canonicalHash, origin: copy.origin, lastError: remembered?.lastError)
            edits.append(copy.edit)
        }
        let form = try SyncLocalScanner.canonical(source.bytes, path: remote.path, scope: remote.scope)
        next = try SyncLocalScanner.migrating(next, from: identity, to: destination)
        let markers = try SyncConflictMetadata.ingest(remote.bytes, filename: LibraryPath.filename(remote.path.string),
                                                      scope: remote.scope.pathScope)
        next.prompts[destination] = try SyncPromptState(scope: remote.scope, path: remote.path, rev: remote.rev,
            canonicalHash: remote.hash, origin: markers.origin,
            lastError: try markers.issue.map { SyncPromptError(code: $0, fingerprint: try SyncInputFingerprint(
                bytes: remote.bytes, path: remote.path, scope: remote.scope, accessGeneration: 0, operation: .put)) })
        if remote.scope.pathScope == .group {
            try next.applyGroupFavorite(SyncFavoriteInput.preferred(form.favorite, after: state?.prompts[identity]?.favoriteInput),
                for: destination)
        }
        else {
            next = try SyncState(binding: next.binding, databaseID: next.databaseID, cursors: next.cursors,
                groups: next.groups, prompts: next.prompts, favorites: next.favorites.filter { $0.key != destination })
        }

        let sourcePath = RelativePath(source.path)
        if sourcePath == remote.libraryPath {
            edits.append(try mutations.publication(remote.bytes, at: remote.libraryPath, expecting: source,
                transition: SyncIdentityTransition(from: identity, to: destination), mode: remote.mode, kind: .adopt,
                markerIssue: markers.issue))
        } else {
            let alias = try mutations.read(at: remote.libraryPath)
            guard alias == nil || (alias?.stamp == source.stamp && alias?.bytes == source.bytes) else {
                throw SyncReconciliationError.requiresPolicy
            }
            // The matching incarnation proves both spellings resolve to one
            // file. Replace that entry and never trash its old alias afterward.
            edits.append(try mutations.publication(remote.bytes, at: remote.libraryPath, expecting: alias,
                transition: SyncIdentityTransition(from: identity == destination && alias == nil ? nil : identity, to: destination),
                mode: remote.mode, kind: .adopt, markerIssue: markers.issue,
                adoptingSource: identity == destination && alias == nil ? nil : source))
            if alias == nil { edits.append(try mutations.trash(source)) }
        }
        try next.validate()
        return SyncApplyPlan(expectedState: state, nextState: next, edits: edits)
    }

    /// A wire-valid path outside local enumeration is a per-file visibility
    /// error, not an invalid protocol response or permission to discard a file.
    /// Record diagnostics without claiming its bytes/rev/cursor were applied.
    static func localVisibility(_ remote: SyncReconciliationRemote, state: SyncState?,
                                binding: SyncLibraryIdentity, groups: [ULID: SyncGroupState],
                                accessGeneration: Int64 = 0) throws -> SyncApplyPlan {
        guard state == nil || state?.binding == binding else { throw SyncError.bindingMismatch }
        try validate(remote, binding: binding, groups: groups)
        guard !LibraryPath.isPrompt(remote.libraryPath.string) else { throw SyncError.invalidState }
        var next = try state ?? SyncState(binding: binding, groups: groups)
        next.groups = groups
        let identity = PromptIdentity.assigned(remote.id)
        let previous = next.prompts[identity]
        let error = try SyncPromptError(code: .localVisibility, fingerprint: SyncInputFingerprint(bytes: remote.bytes,
            path: remote.path, scope: remote.scope, accessGeneration: accessGeneration, operation: .put))
        next.prompts[identity] = try SyncPromptState(scope: previous?.scope ?? remote.scope,
            path: previous?.path ?? remote.path, rev: previous?.rev ?? 0,
            canonicalHash: previous?.canonicalHash, origin: previous?.origin, lastError: error)
        return SyncApplyPlan(expectedState: state, nextState: next, edits: [])
    }

    private static func equivalent(_ bytes: Data, remote: SyncReconciliationRemote) throws -> Bool {
        try CanonicalForm.equivalentForAdoption(bytes, remote.bytes,
            scope: remote.scope.pathScope == .user ? .user : .group, filename: LibraryPath.filename(remote.path.string))
    }

    private static func isHeld(_ file: SyncLibraryFile, in snapshot: SyncReconciliationSnapshot) -> Bool {
        snapshot.heldPaths.contains(RelativePath(file.path)) || !LibraryPath.isPrompt(file.path)
            || SyncLocalScanner.contentIssue(file) != nil
    }

    private static func same(_ lhs: SyncLibraryFile, _ rhs: SyncLibraryFile) -> Bool {
        RelativePath(lhs.path) == RelativePath(rhs.path) && lhs.stamp == rhs.stamp
            && lhs.identityKey == rhs.identityKey && lhs.bytes == rhs.bytes && lhs.hash == rhs.hash
    }

    private static func validate(_ remote: SyncReconciliationRemote, binding: SyncLibraryIdentity,
                                 groups: [ULID: SyncGroupState]) throws {
        if case .user(let id) = remote.scope, id != binding.account.userID { throw SyncError.bindingMismatch }
        let wire = try SyncPathValidator.validate(remote.path.string, scope: remote.scope.pathScope)
        let path = try SyncLocalScanner.rooted(remote.path, scope: remote.scope, groups: groups)
        let form = try SyncLocalScanner.canonical(remote.bytes, path: remote.path, scope: remote.scope)
        let document = PromptCodec.parseFile(remote.bytes, filename: LibraryPath.filename(remote.path.string))
        let mode: SyncFileMode
        if case .group(let group) = remote.scope, groups[group]?.role == .viewer { mode = .readOnly }
        else { mode = .normal }
        guard wire.path.utf8.elementsEqual(remote.path.string.utf8), path == remote.libraryPath,
              form.bytes == remote.bytes, remote.hash == SyncHash(bytes: remote.bytes),
              document.frontMatter.id == remote.id, remote.rev > 0, remote.mode == mode else {
            throw SyncReconciliationError.invalidPull
        }
    }
}
