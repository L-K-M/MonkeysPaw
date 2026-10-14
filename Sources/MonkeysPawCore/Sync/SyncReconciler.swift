import Foundation

/// Planning never writes the library or acknowledges a cursor. Y6/Y7/Y9 may
/// perform journaled preparatory work for deferred operations, then replan
/// against fresh state and file baselines using the same complete collection.
enum SyncReconciler {
    private enum Missing { case delta, snapshot, removedScope }
    private enum Head {
        case recorded(SyncScopeKey)
        case remote(SyncReconciliationRemote, mode: SyncAPI.Mode)
        case missing(SyncScopeKey, Missing, mode: SyncAPI.Mode)

        var scope: SyncScopeKey {
            switch self {
            case .recorded(let scope), .missing(let scope, _, _): return scope
            case .remote(let remote, _): return remote.scope
            }
        }

        var mode: SyncAPI.Mode {
            switch self {
            case .recorded: return .delta
            case .remote(_, let mode), .missing(_, _, let mode): return mode
            }
        }
    }

    static func plan(_ pull: SyncCollectedPull, state: SyncState?, local: SyncReconciliationSnapshot,
                     groupFolders: [ULID: String] = [:]) throws -> SyncReconciliationPlan {
        guard case .available = local.availability else { throw SyncReconciliationError.unavailableLibrary }
        guard state == nil || state?.binding == local.binding else { throw SyncReconciliationError.bindingMismatch }
        let old = try state ?? SyncState(binding: local.binding)
        try old.validate()
        // Compare once with the pre-pass UUID, never with partially adopted state.
        let mode: SyncReconciliationPlan.Mode = old.databaseID == nil ? .firstSync
            : old.databaseID == pull.databaseID ? .normal : .restore
        let groups = try groups(for: pull, old: old, folders: groupFolders)
        let files = try index(local.files, heldPaths: local.heldPaths)
        var heads = Dictionary(uniqueKeysWithValues: old.prompts.compactMap { identity, prompt -> (ULID, Head)? in
            guard case .assigned(let id) = identity else { return nil }
            return (id, .recorded(prompt.scope))
        })
        for (id, head) in heads where pull.removed.contains(head.scope) {
            heads[id] = .missing(head.scope, .removedScope, mode: mode == .restore ? .snapshot : .delta)
        }

        var snapshots: [ULID: SyncReconciliationRemote] = [:]
        var snapshotIDs: [SyncScopeKey: Set<ULID>] = [:]
        try pull.forEachPage(mode: .snapshot) { page in
            guard pull.scopes[page.scope]?.snapshotHead != nil else { throw SyncReconciliationError.invalidPull }
            for item in page.items {
                guard case .upsert(_, let prompt) = item.item else { throw SyncReconciliationError.invalidPull }
                let remote = try remote(prompt, scope: page.scope, groups: groups)
                guard snapshotIDs[page.scope, default: []].insert(remote.id).inserted else {
                    throw SyncReconciliationError.invalidPull
                }
                if let previous = snapshots[remote.id] {
                    // Separately captured scopes can straddle a move. Within one
                    // UUID its higher mutation rev identifies the later owner;
                    // neither rev is compared with the client's old baseline.
                    guard previous.rev != remote.rev else { throw SyncReconciliationError.invalidPull }
                    if previous.rev > remote.rev { continue }
                }
                snapshots[remote.id] = remote
            }
        }
        for (identity, prompt) in old.prompts {
            guard case .assigned(let id) = identity, pull.scopes[prompt.scope]?.snapshotHead != nil,
                  snapshotIDs[prompt.scope]?.contains(id) != true else { continue }
            heads[id] = .missing(prompt.scope, .snapshot, mode: .snapshot)
        }
        for (id, remote) in snapshots { heads[id] = .remote(remote, mode: .snapshot) }

        var deltas: [SyncCollectedItem] = []
        try pull.forEachPage(mode: .delta) { deltas.append(contentsOf: $0.items) }
        deltas.sort { $0.seq < $1.seq }
        var lastSeq: Int64 = 0
        for event in deltas {
            guard event.seq > lastSeq else { throw SyncReconciliationError.invalidPull }
            lastSeq = event.seq
            switch event.item {
            case .upsert(_, let prompt):
                let remote = try remote(prompt, scope: event.scope, groups: groups)
                if let head = heads[remote.id], head.scope != event.scope {
                    guard case .missing = head else { continue }
                }
                heads[remote.id] = .remote(remote, mode: heads[remote.id]?.mode ?? .delta)
            case .delete(_, let rawID), .moveOut(_, let rawID):
                let id = try identifier(rawID)
                guard let head = heads[id], head.scope == event.scope else { continue }
                heads[id] = .missing(event.scope, .delta, mode: head.mode)
            }
        }

        var prompts = old.prompts
        var operations: [SyncReconciliationOperation] = []
        var favorites = old.favorites
        for id in heads.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let identity = PromptIdentity.assigned(id)
            let previous = old.prompts[identity]
            let file = files.byID[id]
            switch heads[id]! {
            case .recorded: continue
            case .missing(_, let reason, _):
                guard let previous, previous.rev > 0 else { continue }
                if reason == .removedScope { continue }
                prompts[identity] = nil
                favorites[identity] = nil
                guard let file else { continue } // A replacement at the old path stays intact.
                if mode == .restore {
                    operations.append(.preserve(.init(id: id, reason: .restoreMissing, local: file, installation: nil)))
                } else if try clean(file, against: previous, groups: old.groups) {
                    operations.append(.remove(file))
                } else {
                    operations.append(.preserve(.init(id: id, reason: .dirtyRemoval, local: file, installation: nil)))
                }
            case .remote(let remote, let headMode):
                // Folding ownership precedes this shortcut, so an old move_out
                // cannot turn an echoed move-back upsert into a deletion.
                let markers = try SyncConflictMetadata.ingest(remote.bytes, filename: LibraryPath.filename(remote.path.string), scope: remote.scope.pathScope)
                if mode != .restore, headMode == .delta, let previous, remote.rev <= previous.rev {
                    if let issue = markers.issue, remote.hash == previous.canonicalHash {
                        prompts[identity] = try SyncPromptState(scope: previous.scope, path: previous.path, rev: previous.rev,
                            canonicalHash: previous.canonicalHash, origin: nil, lastError: SyncPromptError(code: issue,
                                fingerprint: SyncInputFingerprint(bytes: remote.bytes, path: remote.path, scope: remote.scope,
                                                                  accessGeneration: 0, operation: .put)))
                    }
                    continue
                }
                prompts[identity] = try SyncPromptState(scope: remote.scope, path: remote.path, rev: remote.rev,
                    canonicalHash: remote.hash, origin: markers.origin,
                    lastError: try markers.issue.map { SyncPromptError(code: $0,
                        fingerprint: try SyncInputFingerprint(bytes: remote.bytes, path: remote.path, scope: remote.scope,
                                                               accessGeneration: 0, operation: .put)) })
                if remote.scope.pathScope == .user { favorites[identity] = nil }
                if !LibraryPath.isPrompt(remote.libraryPath.string) {
                    operations.append(.localVisibility(remote))
                    continue
                }
                let occupants = files.byFoldedPath[try folded(remote.libraryPath)] ?? []
                if occupants.count > 1 {
                    for occupant in occupants { operations.append(.pathClash(remote: remote, occupant: occupant)) }
                    continue
                }
                let target = occupants.first
                if let target, local.heldPaths.contains(RelativePath(target.path)) {
                    operations.append(.pathClash(remote: remote, occupant: target))
                    continue
                }
                if let target, try RelativePath(target.path) != remote.libraryPath || target.identity != identity {
                    if mode == .firstSync, previous == nil {
                        operations.append(.adoption(remote: remote, local: target))
                    } else {
                        operations.append(.pathClash(remote: remote, occupant: target))
                    }
                    continue
                }
                let installation = SyncReconciliationInstall(remote: remote, source: file, target: target)
                let hash = file.flatMap { canonical($0, scope: remote.scope)?.canonicalHash }
                if remote.scope.pathScope == .group, let file,
                   let favorite = canonical(file, scope: remote.scope)?.favorite {
                    favorites[identity] = favorite ? true : nil
                }
                if let file, hash != remote.hash.rawValue {
                    if mode == .restore {
                        if remote.mode == .readOnly {
                            operations.append(.preserve(.init(id: id, reason: .restoreViewer,
                                local: file, installation: installation)))
                        } else {
                            operations.append(.restoreUpdate(.init(remote: remote, local: file)))
                        }
                        continue
                    }
                    guard let previous, previous.rev > 0 else {
                        operations.append(.adoption(remote: remote, local: file))
                        continue
                    }
                    if try !clean(file, against: previous, groups: old.groups) {
                        operations.append(.preserve(.init(id: id, reason: .dirtyUpsert,
                            local: file, installation: installation)))
                        continue
                    }
                }
                if let file, file.bytes == remote.bytes, RelativePath(file.path) == remote.libraryPath { continue }
                operations.append(.install(installation))
            }
        }
        for scope in pull.removed.sorted(by: { $0.rawValue < $1.rawValue }) {
            if case .group(let id) = scope, old.groups[id] != nil { operations.append(.removedScope(scope)) }
            for (identity, prompt) in prompts where prompt.scope == scope {
                prompts[identity] = nil
                favorites[identity] = nil
            }
        }
        favorites = favorites.filter { prompts[$0.key]?.scope.pathScope == .group }
        let next = try SyncState(binding: local.binding, databaseID: pull.databaseID, cursors: pull.cursors,
            groups: groups, prompts: prompts, favorites: favorites)
        return SyncReconciliationPlan(mode: mode, expectedState: state, nextState: next, operations: operations,
            occupiedPaths: Set(files.byPath.keys), localIdentities: Set(try local.files.map { try $0.identity }))
    }

    private struct Files {
        var byPath: [RelativePath: SyncLibraryFile] = [:]
        var byFoldedPath: [String: [SyncLibraryFile]] = [:]
        var byID: [ULID: SyncLibraryFile] = [:]
    }

    private static func index(_ snapshot: [SyncLibraryFile], heldPaths: Set<RelativePath>) throws -> Files {
        var files = Files()
        for file in snapshot {
            do { try file.validate() } catch { throw SyncReconciliationError.invalidLocalSnapshot }
            let path = RelativePath(file.path)
            guard files.byPath.updateValue(file, forKey: path) == nil else {
                throw SyncReconciliationError.invalidLocalSnapshot
            }
            files.byFoldedPath[try folded(path), default: []].append(file)
            if !heldPaths.contains(path), case .assigned(let id) = try file.identity {
                guard files.byID.updateValue(file, forKey: id) == nil else {
                    throw SyncReconciliationError.invalidLocalSnapshot // Y7 repairs duplicate identities.
                }
            }
        }
        return files
    }

    private static func groups(for pull: SyncCollectedPull, old: SyncState,
                               folders: [ULID: String]) throws -> [ULID: SyncGroupState] {
        let user = SyncScopeKey.user(old.binding.account.userID)
        guard pull.scopes[user] != nil, pull.scopes.keys.filter({ $0.pathScope == .user }).count == 1,
              pull.removed.allSatisfy({ $0.pathScope == .group }),
              pull.removed.isDisjoint(with: pull.scopes.keys) else { throw SyncReconciliationError.invalidPull }
        if old.databaseID != pull.databaseID {
            guard pull.scopes.values.allSatisfy({ $0.snapshotHead != nil }) else {
                throw SyncReconciliationError.invalidPull
            }
        }
        var result = old.groups.filter { !pull.removed.contains(.group($0.key)) }
        for (scope, collected) in pull.scopes {
            guard try SyncScopeKey(collected.identity) == scope else { throw SyncReconciliationError.invalidPull }
            guard case .group(let id, let name, let role) = collected.identity else { continue }
            let key = try identifier(id)
            guard let folder = old.groups[key]?.folder ?? folders[key] else {
                throw SyncReconciliationError.groupFolderRequired(key)
            }
            result[key] = try SyncGroupState(name: name, folder: folder, role: role)
        }
        return result
    }

    private static func remote(_ prompt: SyncAPI.FeedPrompt, scope: SyncScopeKey,
                               groups: [ULID: SyncGroupState]) throws -> SyncReconciliationRemote {
        let id = try identifier(prompt.id)
        let path = RelativePath(prompt.path)
        do {
            let wire = try SyncPathValidator.validate(path.string, scope: scope.pathScope)
            guard wire.path.utf8.elementsEqual(path.string.utf8), prompt.rev > 0 else {
                throw SyncReconciliationError.invalidPull
            }
            let libraryPath = try rooted(path, scope: scope, groups: groups)
            let bytes = Data(prompt.content.utf8)
            let form = try scope.pathScope == .user ? CanonicalForm.user(bytes, filename: LibraryPath.filename(path.string))
                : CanonicalForm.group(bytes, filename: LibraryPath.filename(path.string))
            let document = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(path.string))
            guard document.frontMatter.id == id, form.bytes == bytes else { throw SyncReconciliationError.invalidPull }
            let mode: SyncFileMode
            if case .group(let group) = scope, groups[group]?.role == .viewer { mode = .readOnly }
            else { mode = .normal }
            return SyncReconciliationRemote(id: id, scope: scope, path: path, libraryPath: libraryPath,
                rev: prompt.rev, bytes: bytes, hash: SyncHash(bytes: bytes), mode: mode)
        } catch { throw SyncReconciliationError.invalidPull }
    }

    private static func identifier(_ raw: String) throws -> ULID {
        guard let id = try? SyncIdentifiers.ulid(raw) else { throw SyncReconciliationError.invalidPull }
        return id
    }

    private static func rooted(_ path: RelativePath, scope: SyncScopeKey,
                               groups: [ULID: SyncGroupState]) throws -> RelativePath {
        var value = path.string
        if case .group(let id) = scope {
            guard let group = groups[id] else { throw SyncReconciliationError.invalidPull }
            value = "Groups/" + group.folder + "/" + value
        }
        try FileStorePath.validate(value)
        return RelativePath(value)
    }

    private static func clean(_ file: SyncLibraryFile, against prompt: SyncPromptState,
                              groups: [ULID: SyncGroupState]) throws -> Bool {
        let path = try rooted(prompt.path, scope: prompt.scope, groups: groups)
        return RelativePath(file.path) == path && canonical(file, scope: prompt.scope)?.canonicalHash == prompt.canonicalHash?.rawValue
    }

    private static func canonical(_ file: SyncLibraryFile, scope: SyncScopeKey) -> CanonicalForm? {
        let filename = LibraryPath.filename(file.path)
        return try? scope.pathScope == .user ? CanonicalForm.user(file.bytes, filename: filename)
            : CanonicalForm.group(file.bytes, filename: filename)
    }

    static func folded(_ path: RelativePath) throws -> String {
        guard let nfc = path.string.applyingTransform(StringTransform("Any-NFC"), reverse: false),
              let key = SyncPathCaseFold.fold(nfc).applyingTransform(StringTransform("Any-NFC"), reverse: false) else {
            throw SyncReconciliationError.invalidLocalSnapshot
        }
        return key
    }
}
