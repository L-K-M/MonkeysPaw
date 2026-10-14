import Foundation

extension SyncGroupFolders {
    /// Y10 resolves a held/viewer incoming-path occupant through the same
    /// checked rescue/hold migration as folder cleanup, without dropping scopes.
    static func rescueOccupant(_ file: SyncLibraryFile, state: SyncState?, ownership: SyncLibraryBinding?,
                               inventory: SyncGroupFolderInventory, at date: Date, freshID: () throws -> ULID,
                               mutations: SyncLibraryMutations) throws -> SyncApplyPlan {
        try validate(inventory, state: state, ownership: ownership)
        var next = try state ?? SyncState(binding: inventory.local.binding)
        var owned = try ownership ?? SyncLibraryBinding(root: next.binding.root, owner: next.binding.account)
        let edits = try rescue([file], clean: { _ in false }, inventory: inventory, ownership: &owned,
            previousOwnership: ownership, state: &next, holdAll: false, at: date, freshID: freshID, mutations: mutations)
        // Keep acknowledged baselines for a distinct occupant: a fresh complete
        // snapshot, rather than inferred local DELETE, must restore its head.
        if let record = next.prompts[try file.identity], record.rev > 0 {
            var cursors = next.cursors
            cursors[record.scope] = SyncState.snapshotResetCursor
            next = try SyncState(binding: next.binding, databaseID: next.databaseID, cursors: cursors,
                groups: next.groups, prompts: next.prompts, favorites: next.favorites)
        }
        return SyncApplyPlan(expectedState: state, nextState: next, edits: edits,
            bindingChange: owned == ownership ? nil : SyncBindingChange(expected: ownership, next: owned))
    }

    /// Resolve accessible move/install outcomes first. A live ID owned by an
    /// accessible scope must never become a fresh rescue merely because its old
    /// folder was removed. The caller supplies the complete pull's final IDs.
    static func removed(_ scopes: Set<SyncScopeKey>, state: SyncState, ownership: SyncLibraryBinding?,
                        inventory: SyncGroupFolderInventory, retainingIDs: Set<PromptIdentity> = [],
                        at date: Date, freshID: () throws -> ULID,
                        mutations: SyncLibraryMutations) throws -> SyncApplyPlan {
        try validate(inventory, state: state, ownership: ownership)
        guard ownership == nil || ownership?.owner == state.binding.account else { throw SyncError.bindingMismatch }
        var ids = Set<ULID>()
        for scope in scopes {
            guard case .group(let id) = scope else { throw SyncError.invalidScope }
            ids.insert(id)
        }
        let folders = Set(ids.flatMap { id -> [RelativePath] in
            [state.groups[id]?.folder, ownership?.managedFolders[id]?.folder].compactMap { $0 }.map { RelativePath("Groups/" + $0) }
        })
        let files = try inventory.local.files.filter { file in
            let identity = try file.identity
            let inFolder = folders.contains { contains(RelativePath(file.path), in: $0) || RelativePath(file.path) == $0 }
            let recorded = state.prompts[identity]
            if retainingIDs.contains(identity) {
                guard !inFolder, recorded.map({ !scopes.contains($0.scope) }) ?? true else {
                    throw SyncGroupFolderError.accessibleInstallationRequired
                }
                return false
            }
            return inFolder || recorded.map { scopes.contains($0.scope) } == true
        }
        var next = try dropping(scopes, from: state)
        var owned = try ownership ?? SyncLibraryBinding(root: state.binding.root, owner: state.binding.account)
        for id in ids { owned.managedFolders[id] = nil }
        let identityCounts = try Dictionary(grouping: inventory.local.files, by: { try $0.identity }).mapValues(\.count)
        let clean: (SyncLibraryFile) throws -> Bool = { file in
            let identity = try file.identity
            guard identityCounts[identity] == 1, !inventory.local.heldPaths.contains(RelativePath(file.path)),
                  ownership?.isHeld(identity: identity, path: RelativePath(file.path), contentHash: file.hash) != true,
                  LibraryPath.isPrompt(file.path), SyncLocalScanner.contentIssue(file) == nil,
                  let recorded = state.prompts[identity], recorded.rev > 0, scopes.contains(recorded.scope),
                  try SyncLocalScanner.rooted(recorded.path, scope: recorded.scope, groups: state.groups) == RelativePath(file.path),
                  let canonical = try? SyncLocalScanner.canonical(file.bytes, path: recorded.path, scope: recorded.scope) else { return false }
            return canonical.canonicalHash == recorded.canonicalHash?.rawValue
        }
        let edits = try rescue(files, clean: clean, inventory: inventory, ownership: &owned,
            previousOwnership: ownership, state: &next, holdAll: false, at: date, freshID: freshID, mutations: mutations)
        return try removalPlan(state: state, next: next, ownership: ownership, nextOwnership: owned,
            folders: folders, inventory: inventory, edits: edits)
    }

    /// Orphan folders (including empty ones) and loose Groups files never enter
    /// ID matching or push. Preserve every regular file, regardless of its parser.
    static func stale(state: SyncState?, ownership: SyncLibraryBinding?, inventory: SyncGroupFolderInventory,
                      at date: Date, freshID: () throws -> ULID,
                      mutations: SyncLibraryMutations) throws -> SyncApplyPlan {
        try validate(inventory, state: state, ownership: ownership)
        let binding = inventory.local.binding
        guard ownership == nil || ownership?.owner == binding.account else { throw SyncError.bindingMismatch }
        let old = try state ?? SyncState(binding: binding)
        var next = old
        var owned = try ownership ?? SyncLibraryBinding(root: binding.root, owner: binding.account)
        let legitimate = Set(old.groups.compactMap { id, group -> RelativePath? in
            if let retained = owned.managedFolders[id], retained.owner != binding.account || retained.folder != group.folder { return nil }
            if owned.managedFolders.contains(where: { $0.key != id && $0.value.folder == group.folder }) { return nil }
            return RelativePath("Groups/" + group.folder)
        })
        let roots = Set(inventory.directories.keys.filter { path in
            let parts = path.string.utf8.split(separator: 47)
            guard let first = parts.first, SyncPathCaseFold.fold(String(decoding: first, as: UTF8.self)) == "groups" else { return false }
            return (parts.count == 2 && !legitimate.contains(path)) || (parts.count == 1 && path.string != "Groups")
        })
        let files = inventory.local.files.filter { file in
            let parts = file.path.utf8.split(separator: 47)
            guard let first = parts.first, SyncPathCaseFold.fold(String(decoding: first, as: UTF8.self)) == "groups" else { return false }
            if parts.count >= 3, parts[0].elementsEqual("Groups".utf8) {
                return !legitimate.contains(RelativePath(parts.prefix(2).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")))
            }
            return true
        }
        let retired = Set(try files.map { try $0.identity })
        var cursors = old.cursors
        for (identity, record) in old.prompts where retired.contains(identity) {
            // A cleanup is not a user deletion. Refetch the accessible original
            // instead of letting its internal retirement produce a DELETE.
            cursors[record.scope] = SyncState.snapshotResetCursor
        }
        next = try SyncState(binding: old.binding, databaseID: old.databaseID, cursors: cursors,
            groups: old.groups, prompts: old.prompts.filter { !retired.contains($0.key) },
            favorites: old.favorites.filter { !retired.contains($0.key) })
        for (id, folder) in owned.managedFolders where !legitimate.contains(RelativePath("Groups/" + folder.folder)) {
            owned.managedFolders[id] = nil
        }
        let edits = try rescue(files, clean: { _ in false }, inventory: inventory, ownership: &owned,
            previousOwnership: ownership, state: &next, holdAll: false, at: date, freshID: freshID, mutations: mutations)
        return try removalPlan(state: state, next: next, ownership: ownership, nextOwnership: owned,
            folders: roots, inventory: inventory, edits: edits)
    }

    /// Use the previous account's binding even after sign-out cleared state.
    /// Journal all group rescues and all old private holds before Y11 clears the
    /// old active state/enables the new account. Same-account auth needs no work.
    static func accountChange(to account: SyncAccountIdentity, state: SyncState?, ownership: SyncLibraryBinding,
                              inventory: SyncGroupFolderInventory, at date: Date, freshID: () throws -> ULID,
                              mutations: SyncLibraryMutations) throws -> SyncApplyPlan? {
        try validate(inventory, state: state, ownership: ownership)
        guard ownership.owner == inventory.local.binding.account else { throw SyncError.bindingMismatch }
        guard ownership.owner != account else { return nil }
        let old = try state ?? SyncState(binding: inventory.local.binding)
        let scopes = Set(old.groups.keys.map { SyncScopeKey.group($0) })
        var next = try dropping(scopes, from: old)
        var owned = ownership
        owned.owner = account
        owned.managedFolders = [:]
        let groupFiles = try inventory.local.files.filter { file in
            if isGroupsPath(RelativePath(file.path)) { return true }
            if let recorded = old.prompts[try file.identity], case .group = recorded.scope { return true }
            return false
        }
        let groupPaths = Set(groupFiles.map { RelativePath($0.path) })
        let roots = Set(inventory.directories.keys.filter {
            let count = $0.string.utf8.split(separator: 47).count
            return isGroupsPath($0) && (count == 2 || (count == 1 && $0.string != "Groups"))
        })
        var edits = try rescue(groupFiles, clean: { _ in false }, inventory: inventory, ownership: &owned,
            previousOwnership: ownership, state: &next, holdAll: true, at: date, freshID: freshID, mutations: mutations)
        var reserved = Set(try inventory.local.files.map { try $0.identity }).union(next.prompts.keys)
        reserved.formUnion(owned.holds.map(\.identity))
        for file in inventory.local.files where !groupPaths.contains(RelativePath(file.path)) {
            var identity = try file.identity
            var bytes = file.bytes
            // Idless valid private files need a durable identity to keep a
            // rename plus edit held. Use ordinary adoption/keyed migration.
            if case .local = identity, LibraryPath.isPrompt(file.path), SyncLocalScanner.contentIssue(file) == nil {
                let id = try freshID()
                guard reserved.insert(.assigned(id)).inserted else { throw SyncError.invalidState }
                let document = PromptCodec.parseFile(file.bytes, filename: LibraryPath.filename(file.path))
                bytes = PromptUTF8.encode(try ImportMapper.replacingIdentity(id, in: document,
                    filename: LibraryPath.filename(file.path)).document.source)
                edits.append(try mutations.publication(bytes, at: RelativePath(file.path), expecting: file,
                    transition: SyncIdentityTransition(from: identity, to: .assigned(id)), kind: .adopt))
                next = try SyncLocalScanner.migrating(next, from: identity, to: .assigned(id))
                identity = .assigned(id)
                if next.prompts[identity] == nil {
                    next.prompts[identity] = try SyncPromptState(scope: .user(old.binding.account.userID),
                        path: RelativePath(file.path), rev: 0,
                        origin: SyncConflictMetadata.origin(in: bytes, filename: LibraryPath.filename(file.path)))
                }
            }
            try migrateHold(from: file, to: RelativePath(file.path), identity: identity, hash: SyncHash(bytes: bytes),
                sourceAccount: ownership.owner, ownership: &owned, alwaysHold: true)
        }
        return try removalPlan(state: state, next: next, ownership: ownership, nextOwnership: owned,
            folders: roots, inventory: inventory, edits: edits)
    }

    private static func rescue(_ files: [SyncLibraryFile], clean: (SyncLibraryFile) throws -> Bool,
                               inventory: SyncGroupFolderInventory, ownership: inout SyncLibraryBinding,
                               previousOwnership: SyncLibraryBinding?, state: inout SyncState, holdAll: Bool,
                               at date: Date, freshID: () throws -> ULID,
                               mutations: SyncLibraryMutations) throws -> [SyncLibraryEdit] {
        var copies: [SyncLibraryEdit] = []
        var retirements: [SyncLibraryEdit] = []
        var occupied = inventory.local.files.map { RelativePath($0.path) } + Array(inventory.directories.keys)
        var reserved = Set(try inventory.local.files.map { try $0.identity }).union(state.prompts.keys)
        reserved.formUnion(ownership.holds.map(\.identity))
        for file in files.sorted(by: { RelativePath($0.path) < RelativePath($1.path) }) {
            if try !clean(file) {
                let id = try freshID()
                guard reserved.insert(.assigned(id)).inserted else { throw SyncError.invalidState }
                let destination = try SyncNaming.rescue(source: RelativePath(file.path), at: date, occupiedPaths: occupied)
                // An occupied ancestor cannot become a directory. Fail before
                // source retirement rather than partly applying an impossible plan.
                guard !inventory.local.files.contains(where: { contains(destination, in: RelativePath($0.path)) }) else {
                    throw SyncGroupFolderError.rescueRequired
                }
                let edit = try mutations.rescue(file, at: destination, freshID: id)
                copies.append(edit)
                occupied.append(destination)
                let held = inventory.local.heldPaths.contains(RelativePath(file.path)) || edit.heldIssue != nil
                let identity = edit.heldIssue == nil ? PromptIdentity.assigned(id) : PromptIdentity(path: destination.string, id: nil)
                let sourceAccount = previousOwnership?.managedFolders.values.first(where: {
                    contains(RelativePath(file.path), in: RelativePath("Groups/" + $0.folder))
                })?.owner ?? inventory.local.binding.account
                try migrateHold(from: file, to: destination, identity: identity, hash: edit.hash!,
                    sourceAccount: sourceAccount, ownership: &ownership,
                    alwaysHold: holdAll || held || sourceAccount != inventory.local.binding.account)
                if edit.heldIssue == nil {
                    state.prompts[.assigned(id)] = try SyncPromptState(scope: .user(state.binding.account.userID),
                        path: destination, rev: 0, origin: .rescued)
                }
            }
            retirements.append(try mutations.trash(file))
        }
        return copies + retirements
    }

    private static func migrateHold(from file: SyncLibraryFile, to path: RelativePath, identity: PromptIdentity,
                                    hash: SyncHash, sourceAccount: SyncAccountIdentity,
                                    ownership: inout SyncLibraryBinding, alwaysHold: Bool) throws {
        let originalIdentity = try file.identity
        let matches = ownership.holds.filter {
            $0.path == RelativePath(file.path) || $0.identity == originalIdentity || $0.contentHash == file.hash
        }
        guard alwaysHold || !matches.isEmpty else { return }
        ownership.holds.removeAll { $0.path == RelativePath(file.path) || $0.path == path }
        ownership.holds.append(try SyncHeldPrompt(identity: identity, path: path,
            sourceAccount: matches.first?.sourceAccount ?? sourceAccount, contentHash: hash))
    }

    private static func dropping(_ scopes: Set<SyncScopeKey>, from state: SyncState) throws -> SyncState {
        let prompts = state.prompts.filter { !scopes.contains($0.value.scope) }
        let favorites = state.favorites.filter { prompts[$0.key] != nil }
        let groups = state.groups.filter { !scopes.contains(.group($0.key)) }
        return try SyncState(binding: state.binding, databaseID: state.databaseID,
            cursors: state.cursors.filter { !scopes.contains($0.key) }, groups: groups, prompts: prompts, favorites: favorites)
    }

    private static func removalPlan(state: SyncState?, next: SyncState, ownership: SyncLibraryBinding?,
                                    nextOwnership: SyncLibraryBinding, folders: Set<RelativePath>,
                                    inventory: SyncGroupFolderInventory, edits: [SyncLibraryEdit]) throws -> SyncApplyPlan {
        let paths = inventory.directories.keys.filter { path in folders.contains(path) || folders.contains { contains(path, in: $0) } }
            .sorted { $0.string.utf8.count == $1.string.utf8.count ? $1 < $0 : $0.string.utf8.count > $1.string.utf8.count }
        let directories = try paths.map { try SyncDirectoryEdit(removing: $0, identity: inventory.directories[$0]!) }
        try next.validate()
        try nextOwnership.validate()
        return SyncApplyPlan(expectedState: state, nextState: next, edits: edits, directories: directories,
            bindingChange: nextOwnership == ownership ? nil : SyncBindingChange(expected: ownership, next: nextOwnership))
    }

    private static func isGroupsPath(_ path: RelativePath) -> Bool {
        let first = path.string.utf8.split(separator: 47).first
        return first.map { SyncPathCaseFold.fold(String(decoding: $0, as: UTF8.self)) == "groups" } ?? false
    }
}
