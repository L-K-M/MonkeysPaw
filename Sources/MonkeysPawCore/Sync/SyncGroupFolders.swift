import Foundation

enum SyncGroupFolderError: Error, Equatable {
    case reservedFolders([RelativePath])
    case invalidInventory
    case rescueRequired
    case accessibleInstallationRequired
}

struct SyncGroupFolderInventory {
    let local: SyncReconciliationSnapshot
    /// Full rooted tree, including empty and hidden directories.
    let directories: [RelativePath: FileStamp]
}

/// Preparatory folder policy. Renames retain the old UUID/cursors; cleanup can
/// drop/reset scope cursors. Y10 finishes collection after these plans commit.
enum SyncGroupFolders {
    static func inventory(binding: SyncLibraryIdentity, availability: SyncReconciliationSnapshot.Availability,
                          heldPaths: Set<RelativePath> = [], mutations: SyncLibraryMutations) throws -> SyncGroupFolderInventory {
        guard case .available = availability else { throw SyncReconciliationError.unavailableLibrary }
        return SyncGroupFolderInventory(local: SyncReconciliationSnapshot(binding: binding,
            files: try mutations.listedFiles(), heldPaths: heldPaths), directories: try mutations.directoryIdentities())
    }

    /// Setup must ask for a rename, including for empty reserved folders and
    /// loose regular files with their names. A retained binding owns the roots
    /// across sign-out/account changes; child ownership is checked separately.
    static func preflight(_ inventory: SyncGroupFolderInventory, ownership: SyncLibraryBinding?) throws {
        try validate(inventory, state: nil, ownership: ownership)
        guard ownership == nil else { return }
        let paths = inventory.local.files.map { RelativePath($0.path) } + Array(inventory.directories.keys)
        let occupied = try paths.filter {
            guard !$0.string.utf8.contains(47) else { return false }
            return try ["groups", "conflicts"].contains(SyncNaming.pathKey($0))
        }.sorted()
        guard occupied.isEmpty else { throw SyncGroupFolderError.reservedFolders(occupied) }
    }

    static func update(_ memberships: [SyncAPI.GroupMembership], state: SyncState?, ownership: SyncLibraryBinding?,
                       inventory: SyncGroupFolderInventory, mutations: SyncLibraryMutations) throws -> SyncApplyPlan {
        try validate(inventory, state: state, ownership: ownership)
        let binding = inventory.local.binding
        guard ownership == nil || ownership?.owner == binding.account else { throw SyncError.bindingMismatch }
        if state == nil { try preflight(inventory, ownership: ownership) }
        let old = try state ?? SyncState(binding: binding)
        var next = old
        var owned = try ownership ?? SyncLibraryBinding(root: binding.root, owner: binding.account)
        var directories: [SyncDirectoryEdit] = []
        var edits: [SyncLibraryEdit] = []
        var seen = Set<ULID>()
        var occupied = Array(inventory.directories.keys) + inventory.local.files.map { RelativePath($0.path) }
        occupied += old.groups.values.map { RelativePath("Groups/" + $0.folder) }
        occupied += owned.managedFolders.values.map { RelativePath("Groups/" + $0.folder) }

        for membership in memberships.sorted(by: { $0.groupID < $1.groupID }) {
            let id = try SyncIdentifiers.ulid(membership.groupID)
            guard seen.insert(id).inserted else { throw SyncError.invalidState }
            let previous = old.groups[id]
            let retained = owned.managedFolders[id]
            guard retained == nil || retained?.owner == binding.account else { throw SyncGroupFolderError.rescueRequired }
            let priorFolder = previous?.folder ?? retained?.folder
            if let previous, let retained, previous.folder != retained.folder { throw SyncGroupFolderError.rescueRequired }
            let canonicalSource = priorFolder.map { RelativePath("Groups/" + $0) }
            let existingDirectory = try canonicalSource.flatMap { source -> (key: RelativePath, value: FileStamp)? in
                let key = try SyncNaming.pathKey(source)
                let matches = try inventory.directories.filter { try SyncNaming.pathKey($0.key) == key }
                guard matches.count <= 1 else { throw SyncGroupFolderError.invalidInventory }
                return matches.first
            }
            // State keeps its allocation; mutations use the actual disk spelling.
            let source = existingDirectory?.key ?? canonicalSource
            if let source, try inventory.local.files.contains(where: {
                try SyncNaming.pathKey(RelativePath($0.path)) == SyncNaming.pathKey(source)
            }) {
                throw SyncGroupFolderError.rescueRequired
            }
            let folder: String
            // Persisted allocations survive restart and same-account sign-in.
            if let priorFolder, previous == nil || previous?.name.utf8.elementsEqual(membership.name.utf8) == true {
                folder = priorFolder
            } else {
                let otherNames = try occupied.filter {
                    guard let source else { return true }
                    return try SyncNaming.pathKey($0) != SyncNaming.pathKey(source)
                }.compactMap(childFolder)
                folder = try SyncNaming.groupFolder(membership.name, occupied: otherNames)
            }
            let group = try SyncGroupState(name: membership.name, folder: folder, role: membership.role)
            let destination = RelativePath("Groups/" + folder)
            try FileStorePath.validate(destination.string)
            if let source, source != destination, let identity = existingDirectory?.value {
                let intermediate: RelativePath?
                if try SyncNaming.pathKey(source) == SyncNaming.pathKey(destination) {
                    let candidate = RelativePath("Groups/_sync-" + UUID().uuidString.lowercased())
                    guard try !occupied.contains(where: { try SyncNaming.pathKey($0) == SyncNaming.pathKey(candidate) }) else {
                        throw SyncGroupFolderError.invalidInventory
                    }
                    intermediate = candidate
                } else { intermediate = nil }
                for path in occupied where try contains(path, in: source) {
                    try FileStorePath.validate(relocated(path, from: source, to: destination).string)
                    if let intermediate { try FileStorePath.validate(relocated(path, from: source, to: intermediate).string) }
                }
                let localFiles = try inventory.local.files.filter {
                    guard try contains(RelativePath($0.path), in: source) else { return false }
                    if case .local = try $0.identity { return true }
                    return false
                }
                let rename = try SyncDirectoryEdit(renaming: source, identity: identity,
                    to: destination, intermediate: intermediate, localFiles: localFiles)
                directories.append(rename)
                for transition in try rename.identityTransitions() {
                    guard let source = transition.source else { throw SyncError.invalidState }
                    next = try SyncLocalScanner.migrating(next, from: SyncIdentifiers.promptIdentity(source),
                        to: SyncIdentifiers.promptIdentity(transition.destination))
                }
                owned.holds = try owned.holds.map { hold in
                    guard try contains(hold.path, in: source) else { return hold }
                    let path = relocated(hold.path, from: source, to: destination)
                    let identity: PromptIdentity
                    if case .local = hold.identity { identity = PromptIdentity(path: path.string, id: nil) }
                    else { identity = hold.identity }
                    return try SyncHeldPrompt(identity: identity, path: path, sourceAccount: hold.sourceAccount,
                        contentHash: hold.contentHash)
                }
            } else if priorFolder == nil || source != destination {
                directories.append(try SyncDirectoryEdit(reserving: destination))
            }
            if let source, previous?.role != membership.role || membership.role == .viewer {
                for file in inventory.local.files where try contains(RelativePath(file.path), in: source) {
                    let path = relocated(RelativePath(file.path), from: source, to: destination)
                    let moved = try SyncLibraryFile(path: path.string, stamp: file.stamp, bytes: file.bytes)
                    edits.append(try mutations.mode(membership.role == .viewer ? .readOnly : .normal, for: moved))
                }
            }
            next.groups[id] = group
            owned.managedFolders[id] = try SyncManagedFolder(owner: binding.account, folder: folder)
            occupied.append(destination)
            // Empty new groups reserve the mapping; the first checked file
            // publication creates their folder. No existing directory is adopted.
        }
        try next.validate()
        try owned.validate()
        return SyncApplyPlan(expectedState: state, nextState: next, edits: edits, directories: directories,
            bindingChange: owned == ownership ? nil : SyncBindingChange(expected: ownership, next: owned))
    }

    static func mode(for scope: SyncScopeKey, groups: [ULID: SyncGroupState]) throws -> SyncFileMode {
        guard case .group(let id) = scope else { return .normal }
        guard let group = groups[id] else { throw SyncError.invalidScope }
        return group.role == .viewer ? .readOnly : .normal
    }

    static func validate(_ inventory: SyncGroupFolderInventory, state: SyncState?, ownership: SyncLibraryBinding?) throws {
        guard case .available = inventory.local.availability else { throw SyncReconciliationError.unavailableLibrary }
        guard state == nil || state?.binding == inventory.local.binding,
              ownership == nil || ownership?.root == inventory.local.binding.root else { throw SyncError.bindingMismatch }
        try state?.validate()
        try ownership?.validate()
        guard Set(inventory.local.files.map { RelativePath($0.path) }).count == inventory.local.files.count else {
            throw SyncGroupFolderError.invalidInventory
        }
        for file in inventory.local.files { try file.validate() }
        for path in inventory.directories.keys { try FileStorePath.validate(path.string) }
    }

    static func contains(_ path: RelativePath, in directory: RelativePath) throws -> Bool {
        try SyncNaming.pathKey(path).utf8.starts(with: (SyncNaming.pathKey(directory) + "/").utf8)
    }

    static func relocated(_ path: RelativePath, from source: RelativePath, to destination: RelativePath) -> RelativePath {
        let depth = source.string.utf8.split(separator: 47).count
        let suffix = path.string.utf8.split(separator: 47).dropFirst(depth).joined(separator: [47])
        return RelativePath(destination.string + "/" + String(decoding: Array(suffix), as: UTF8.self))
    }

    static func childFolder(_ path: RelativePath) throws -> String? {
        let parts = path.string.utf8.split(separator: 47)
        guard parts.count == 2,
              try SyncNaming.pathKey(RelativePath(String(decoding: parts[0], as: UTF8.self))) == "groups" else { return nil }
        return String(decoding: parts[1], as: UTF8.self)
    }
}
