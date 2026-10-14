import Foundation

struct SyncLocalPrompt: CustomStringConvertible, CustomReflectable {
    let file: SyncLibraryFile
    let identity: PromptIdentity
    let scope: SyncScopeKey
    /// NFC wire path; file.path keeps the exact rooted filesystem spelling.
    let path: RelativePath
    let canonical: CanonicalForm
    let origin: SyncPromptOrigin?
    var description: String { "<local sync prompt>" }
    var customMirror: Mirror { Mirror(self, children: ["prompt": description]) }
}

enum SyncLocalChange {
    case create(SyncLocalPrompt)
    case update(SyncLocalPrompt, recorded: SyncPromptState)
    case rename(SyncLocalPrompt, recorded: SyncPromptState)
    /// Y8 sends the transfer before any accompanying content edit.
    case move(SyncLocalPrompt, recorded: SyncPromptState)
    case delete(PromptIdentity, recorded: SyncPromptState)
}

struct SyncLocalScan {
    let snapshot: SyncReconciliationSnapshot
    /// Y9 must journal these rescues, migrate any holds, and scan again before
    /// matching paths. No upload/deletion decisions accompany orphan files.
    let orphanFiles: [SyncLibraryFile]
    let issues: [RelativePath: SyncIssueCode]
    /// Commit through Y2, then scan again. Changes are empty while preparing.
    /// This never adopts a database UUID or advances pull cursors.
    let preparation: SyncApplyPlan?
    let changes: [SyncLocalChange]
}

enum SyncLocalScanner {
    struct Location {
        let scope: SyncScopeKey
        let path: RelativePath
    }

    static func scan(binding: SyncLibraryIdentity, state: SyncState?, ownership: SyncLibraryBinding? = nil,
                     retainedRescues: [SyncRetainedRescue] = [],
                     availability: SyncReconciliationSnapshot.Availability,
                     accessGeneration: Int64 = 0, freshID: () throws -> ULID,
                     mutations: SyncLibraryMutations) throws -> SyncLocalScan {
        guard case .available = availability else { throw SyncReconciliationError.unavailableLibrary }
        guard state == nil || state?.binding == binding,
              ownership == nil || (ownership?.root == binding.root && ownership?.owner == binding.account) else {
            throw SyncError.bindingMismatch
        }
        try ownership?.validate()
        let old = try state ?? SyncState(binding: binding)
        try old.validate()
        let files = try mutations.listedFiles()
        guard Set(files.map { RelativePath($0.path) }).count == files.count else { throw SyncError.invalidState }
        var held = Set<RelativePath>()
        var issues: [RelativePath: SyncIssueCode] = [:]
        var orphans: [SyncLibraryFile] = []
        var eligible: [(SyncLibraryFile, Location)] = []
        for file in files {
            let path = RelativePath(file.path)
            let identity = try file.identity
            if ownership?.isHeld(identity: identity, path: path, contentHash: file.hash) == true {
                held.insert(path)
            }
            for rescue in retainedRescues where rescue.binding.root == binding.root {
                if rescue.path == path || rescue.hash == file.hash {
                    held.insert(path)
                    issues[path] = rescue.issue
                }
            }
            guard let location = location(of: path, binding: binding, groups: old.groups) else {
                orphans.append(file)
                held.insert(path)
                continue
            }
            if case .group(let id) = location.scope, let group = old.groups[id],
               let folder = ownership?.managedFolders.first(where: { $0.value.folder.utf8.elementsEqual(group.folder.utf8) }),
               folder.key != id || folder.value.owner != binding.account {
                orphans.append(file)
                held.insert(path)
                continue
            }
            if !LibraryPath.isPrompt(file.path) {
                held.insert(path)
                if old.prompts[identity] != nil || old.prompts.contains(where: {
                    (try? rooted($0.value.path, scope: $0.value.scope, groups: old.groups)) == path
                }) { issues[path] = .localVisibility }
            } else if let issue = contentIssue(file) {
                held.insert(path)
                issues[path] = issue
            } else if !held.contains(path) {
                eligible.append((file, location))
            }
        }
        var snapshot = SyncReconciliationSnapshot(binding: binding, files: files, heldPaths: held)
        if !orphans.isEmpty {
            return SyncLocalScan(snapshot: snapshot, orphanFiles: orphans, issues: issues, preparation: nil, changes: [])
        }

        var next = old
        var edits: [SyncLibraryEdit] = []
        var used = Set<PromptIdentity>()
        var byID: [ULID: RelativePath] = [:]
        var reserved = Set(old.prompts.keys)
        reserved.formUnion(try files.map { try $0.identity })
        func allocate() throws -> ULID {
            let id = try freshID()
            guard reserved.insert(.assigned(id)).inserted else { throw SyncError.invalidState }
            return id
        }
        // Reserve identity matches before path fallback, even if their file
        // sorts later. A copied file cannot steal a renamed original's record.
        for (file, _) in eligible {
            if case .assigned(let id) = try file.identity, byID[id] == nil {
                byID[id] = RelativePath(file.path)
                if old.prompts[.assigned(id)] != nil { used.insert(.assigned(id)) }
            }
        }
        var changes: [SyncLocalChange] = []
        for (file, location) in eligible {
            let localPath = RelativePath(file.path)
            let originalIdentity = try file.identity
            let duplicate: Bool
            if case .assigned(let id) = originalIdentity { duplicate = byID[id] != localPath }
            else { duplicate = false }
            let wire: SyncPath
            do { wire = try SyncPathValidator.validate(location.path.string, scope: location.scope.pathScope) }
            catch let issue as SyncPathIssue {
                issues[localPath] = .path(issue.code)
                held.insert(localPath)
                continue
            }
            var identity = originalIdentity
            var recorded = duplicate ? nil : old.prompts[identity]
            var stateSource = identity
            if !duplicate, recorded == nil {
                let candidates = try old.prompts.filter {
                    !used.contains($0.key) && (isLocal(identity) || isLocal($0.key)) && $0.value.scope == location.scope
                        && (try? SyncNaming.pathKey($0.value.path)) == wire.pathKey
                }.sorted { try $0.key.storageKey < $1.key.storageKey }
                guard candidates.count <= 1 else { throw SyncError.invalidState }
                if let match = candidates.first {
                    stateSource = match.key
                    recorded = match.value
                    used.insert(match.key)
                    if isLocal(identity), case .assigned = match.key { identity = match.key }
                }
            }
            let externalAssignment = !isLocal(originalIdentity) && isLocal(stateSource) && stateSource != identity
            if externalAssignment, stateSource != PromptIdentity(path: file.path, id: nil) {
                issues[localPath] = .idMismatch
                held.insert(localPath)
                continue
            }
            let viewer = isViewer(location.scope, groups: old.groups)
                || (recorded.map { isViewer($0.scope, groups: old.groups) } ?? false)
            if duplicate || (identity == originalIdentity && isLocal(identity)) {
                if viewer {
                    issues[localPath] = duplicate ? .idMismatch : .forbidden
                    if duplicate { held.insert(localPath) }
                    continue
                }
                identity = .assigned(try allocate())
            }
            var bytes = file.bytes
            if identity != originalIdentity {
                guard case .assigned(let id) = identity else { throw SyncError.invalidState }
                let document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(file.path))
                bytes = PromptUTF8.encode(try ImportMapper.replacingIdentity(id, in: document,
                    filename: LibraryPath.filename(file.path)).document.source)
            }
            let canonical = try canonical(bytes, path: location.path, scope: location.scope)
            let origin = try SyncConflictMetadata.origin(in: bytes, filename: LibraryPath.filename(file.path),
                                                        scope: location.scope.pathScope)
            let transferring = recorded.map { $0.scope != location.scope } ?? false
            // Keep an acknowledged baseline's scope/path/hash until Y8 commits
            // its rename/move/update. Only pending creates use the current path.
            let pending = try SyncPromptState(scope: recorded?.scope ?? location.scope,
                path: recorded?.path ?? RelativePath(wire.path), rev: recorded?.rev ?? 0,
                canonicalHash: recorded?.canonicalHash, origin: transferring ? recorded?.origin : origin,
                lastError: recorded?.lastError)
            if !duplicate, stateSource != identity {
                next = try migrating(next, from: stateSource, to: identity)
            }
            next.prompts[identity] = pending
            if location.scope.pathScope == .group, pending.scope.pathScope == .group {
                try next.applyGroupFavorite(canonical.favorite, for: identity)
            }
            // Until /move commits, the overlay still belongs to the old scope.
            // Keep extracted personal keys on disk for ingest after that ack.
            if !transferring && (externalAssignment || bytes != file.bytes
                || (location.scope.pathScope == .group && canonical.bytes != file.bytes)) {
                edits.append(try mutations.publication(canonical.bytes, at: localPath, expecting: file,
                    transition: SyncIdentityTransition(from: externalAssignment ? stateSource : originalIdentity, to: identity),
                    mode: isViewer(location.scope, groups: old.groups) ? .readOnly : .normal,
                    kind: duplicate ? .repairDuplicate : identity != originalIdentity || externalAssignment ? .adopt : .apply))
            }
            let prompt = SyncLocalPrompt(file: file, identity: identity, scope: location.scope,
                path: RelativePath(wire.path), canonical: canonical, origin: origin)
            if viewer {
                if recorded == nil || recorded?.canonicalHash?.rawValue != canonical.canonicalHash
                    || recorded?.scope != prompt.scope || recorded?.path != prompt.path {
                    issues[localPath] = .forbidden
                }
                continue
            }
            guard let recorded, recorded.rev > 0 else { changes.append(.create(prompt)); continue }
            if recorded.scope != prompt.scope { changes.append(.move(prompt, recorded: recorded)) }
            else if recorded.path != prompt.path { changes.append(.rename(prompt, recorded: recorded)) }
            else if recorded.canonicalHash?.rawValue != canonical.canonicalHash { changes.append(.update(prompt, recorded: recorded)) }
        }

        let presentPaths = Set(files.map { RelativePath($0.path) })
        let presentIDs = Set(try files.map { try $0.identity })
        for (identity, recorded) in try old.prompts.sorted(by: { try $0.key.storageKey < $1.key.storageKey }) {
            let path = try rooted(recorded.path, scope: recorded.scope, groups: old.groups)
            if !LibraryPath.isPrompt(path.string) {
                issues[path] = .localVisibility
                held.insert(path)
                continue
            }
            guard recorded.rev > 0, !presentIDs.contains(identity), !presentPaths.contains(path),
                  ownership?.isHeld(identity: identity, path: path,
                                    contentHash: recorded.canonicalHash ?? SyncHash(bytes: Data())) != true,
                  !retainedRescues.contains(where: { $0.binding.root == binding.root && $0.path == path }) else { continue }
            // Listing omits symlinks. Probe the recorded location without
            // following it before declaring a genuine absence.
            do {
                guard try mutations.read(at: path) == nil else { throw LibraryError.conflict }
            } catch let error as FileStoreError where error == .notRegularFile || error == .outsideRoot {
                issues[path] = .localVisibility
                held.insert(path)
                continue
            }
            if isViewer(recorded.scope, groups: old.groups) { issues[path] = .forbidden; continue }
            changes.append(.delete(identity, recorded: recorded))
        }
        // Errors are fixed codes/fingerprints, never parser or tool messages.
        for (path, issue) in issues {
            let file = files.first { RelativePath($0.path) == path }
            guard let location = location(of: path, binding: binding, groups: next.groups) else { continue }
            // An invalid duplicate cannot claim the valid owner's ID/state.
            let key = try file.map { value -> PromptIdentity in
                let id = try value.identity
                if held.contains(path), files.contains(where: { RelativePath($0.path) != path && $0.identityKey == value.identityKey }) {
                    return PromptIdentity(path: value.path, id: nil)
                }
                return id
            } ?? old.prompts.first(where: { (try? rooted($0.value.path, scope: $0.value.scope, groups: old.groups)) == path })?.key
            guard let key else { continue }
            let existing = next.prompts[key]
            let error = try SyncPromptError(code: issue, fingerprint: SyncInputFingerprint(bytes: file?.bytes ?? Data(),
                path: location.path, scope: location.scope, accessGeneration: accessGeneration, operation: .put))
            next.prompts[key] = try SyncPromptState(scope: existing?.scope ?? location.scope,
                path: existing?.path ?? location.path, rev: existing?.rev ?? 0, canonicalHash: existing?.canonicalHash,
                origin: existing?.origin, lastError: error)
        }
        snapshot = SyncReconciliationSnapshot(binding: binding, files: files, heldPaths: held)
        try next.validate()
        let preparation = edits.isEmpty && next == old ? nil : SyncApplyPlan(expectedState: state, nextState: next, edits: edits)
        return SyncLocalScan(snapshot: snapshot, orphanFiles: [], issues: issues, preparation: preparation,
                             changes: preparation == nil ? changes : [])
    }

    static func location(of path: RelativePath, binding: SyncLibraryIdentity,
                         groups: [ULID: SyncGroupState]) -> Location? {
        let parts = path.string.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
        guard parts.first.map(SyncPathCaseFold.fold) == "groups" else {
            return Location(scope: .user(binding.account.userID), path: path)
        }
        guard parts.count >= 3, parts[0] == "Groups",
              let group = groups.first(where: { $0.value.folder.utf8.elementsEqual(parts[1].utf8) }) else { return nil }
        return Location(scope: .group(group.key), path: RelativePath(parts.dropFirst(2).joined(separator: "/")))
    }

    static func rooted(_ path: RelativePath, scope: SyncScopeKey, groups: [ULID: SyncGroupState]) throws -> RelativePath {
        var value = path.string
        if case .group(let id) = scope {
            guard let group = groups[id] else { throw SyncError.invalidScope }
            value = "Groups/" + group.folder + "/" + value
        }
        try FileStorePath.validate(value)
        return RelativePath(value)
    }

    static func canonical(_ bytes: Data, path: RelativePath, scope: SyncScopeKey) throws -> CanonicalForm {
        let filename = LibraryPath.filename(path.string)
        return try scope.pathScope == .user ? CanonicalForm.user(bytes, filename: filename)
            : CanonicalForm.group(bytes, filename: filename)
    }

    static func migrating(_ state: SyncState, from source: PromptIdentity, to destination: PromptIdentity) throws -> SyncState {
        guard source != destination else { return state }
        var prompts = state.prompts
        var favorites = state.favorites
        if let record = prompts.removeValue(forKey: source) {
            guard prompts[destination] == nil else { throw SyncError.invalidState }
            prompts[destination] = record
        }
        if let favorite = favorites.removeValue(forKey: source) { favorites[destination] = favorite }
        return try SyncState(binding: state.binding, databaseID: state.databaseID, cursors: state.cursors,
            groups: state.groups, prompts: prompts, favorites: favorites)
    }

    static func contentIssue(_ file: SyncLibraryFile) -> SyncIssueCode? {
        let document = PromptCodec.parseFile(file.bytes, filename: LibraryPath.filename(file.path))
        if document.isReadOnly { return .content(.unsupportedFormat) }
        if let issue = document.issues.first(where: { $0.severity == .error }) { return .content(issue.code) }
        if SyncConflictMetadata.hasInvalidOrigin(in: document) { return .content(.invalidMetadataType) }
        return nil
    }

    private static func isLocal(_ identity: PromptIdentity) -> Bool {
        if case .local = identity { return true }; return false
    }

    private static func isViewer(_ scope: SyncScopeKey, groups: [ULID: SyncGroupState]) -> Bool {
        if case .group(let id) = scope { return groups[id]?.role == .viewer }; return false
    }

}
