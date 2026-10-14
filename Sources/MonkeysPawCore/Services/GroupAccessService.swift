import Foundation

/// One per sync/library graph. Only the validated state store supplies roles.
/// State I/O stays outside the library lock; policy installation is memory-only.
public final class GroupAccessService: @unchecked Sendable {
    private let states: SyncStateStore
    private let accounts: SyncAccountStore
    private weak var library: LibraryService?
    private let root: SyncLibraryRoot
    private let lock = NSLock()
    private var observer: UUID?
    private var accountObserver: UUID?

    public init(library: LibraryService, states: SyncStateStore, accounts: SyncAccountStore, libraryRoot: String) throws {
        self.library = library
        self.states = states
        self.accounts = accounts
        root = try SyncLibraryRoot(libraryRoot)
        library.bindGroupAccess(self)
        observer = states.observeChanges { [weak self] in self?.refresh() }
        accountObserver = accounts.observeChanges { [weak self] in self?.refresh() }
        refresh()
    }

    deinit {
        if let observer { states.removeObserver(observer) }
        if let accountObserver { accounts.removeObserver(accountObserver) }
    }

    public var snapshot: GroupAccessSnapshot { library?.accessSnapshot ?? .local }

    private func refresh() {
        lock.lock()
        guard let library else { lock.unlock(); return }
        let previous = library.accessSnapshot
        let cached = states.snapshot
        let state = cached.value
        let matchesRoot = state == nil || state?.binding.root == root
        let groups = matchesRoot ? state?.groups ?? [:] : [:]
        var projected: [ULID: GroupAccessGroup] = [:]
        for (id, group) in groups {
            let role: AssistantGroupRole
            switch group.role {
            case .viewer: role = .viewer
            case .editor: role = .editor
            case .owner: role = .owner
            }
            projected[id] = GroupAccessGroup(id: id, name: group.name, folder: RelativePath(group.folder), role: role)
        }
        let prompts = matchesRoot ? state?.prompts ?? [:] : [:]
        let managesGroups = state != nil || previous.managesGroups
            || accounts.cachedBindings.contains { $0.root == root }
        let isBlocked = cached.error != nil || accounts.readOnlyError != nil || !matchesRoot
        var removed = previous.unavailableIDs
        for (id, prompt) in previous.prompts where prompts[id] == nil {
            if case .group = prompt.scope { removed.insert(id) }
        }
        for id in prompts.keys { removed.remove(id) }
        let candidate = GroupAccessSnapshot(generation: previous.generation, groups: projected,
            isBlocked: isBlocked, binding: matchesRoot ? state?.binding : nil,
            prompts: prompts, favorites: matchesRoot ? state?.favorites ?? [:] : [:],
            unavailableIDs: removed, managesGroups: managesGroups)
        let next = GroupAccessSnapshot(generation: previous.generation + (candidate.samePolicy(as: previous) ? 0 : 1),
            groups: candidate.groups, isBlocked: candidate.isBlocked, binding: candidate.binding,
            prompts: candidate.prompts, favorites: candidate.favorites,
            unavailableIDs: candidate.unavailableIDs, managesGroups: managesGroups)
        let policyChanged = !next.samePolicy(as: previous)
        let favoritesChanged = next.favorites != previous.favorites
        let unblocked = previous.isBlocked && !next.isBlocked
        let changed = library.installAccessSnapshot(next)
        lock.unlock()
        guard changed else { return }
        if policyChanged { library.publishAccessChange(.access) }
        else if favoritesChanged { library.publishAccessChange(.favorite) }
        if unblocked { library.publishAccessChange(.sync) }
    }

    /// A personal intent, including for viewers. No library bytes or modes change.
    func toggleFavorite(of entry: LibraryEntry) -> PromptFavoriteOutcome {
        guard let library else { return .inactive }
        do {
            let expected = snapshot
            guard entry.accessGeneration == expected.generation, let binding = expected.binding, !expected.isBlocked,
                  case .group(let group) = expected.access(at: entry.relativePath, identity: entry.identity) else {
                throw LibraryError.accessDenied
            }
            try states.update(for: binding) { state in
                let current = try library.checkedFavoriteEntry(entry, generation: expected.generation)
                guard state.groups[group.id] != nil else { throw LibraryError.accessDenied }
                var recorded = state.prompts[current.identity]
                if recorded == nil {
                    let prefix = "Groups/" + group.folder.string + "/"
                    guard current.relativePath.utf8.starts(with: prefix.utf8) else { throw LibraryError.accessDenied }
                    let path = RelativePath(String(decoding: current.relativePath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self))
                    recorded = try SyncPromptState(scope: .group(group.id), path: path, rev: 0)
                }
                guard let recorded, case .group(let id) = recorded.scope, state.groups[id] != nil else {
                    throw LibraryError.accessDenied
                }
                let input = try? CanonicalForm.group(Data(current.document.source.utf8),
                    filename: LibraryPath.filename(current.relativePath))
                state.prompts[current.identity] = try SyncPromptState(scope: recorded.scope, path: recorded.path,
                    rev: recorded.rev, canonicalHash: recorded.canonicalHash, origin: recorded.origin,
                    lastError: recorded.lastError, favoriteInput: SyncFavoriteInput(value: input?.favorite))
                try state.applyGroupFavorite(!current.favorite, for: current.identity)
            }
            return .saved(try library.load(at: entry.relativePath))
        } catch let error as FileStoreError { return .fileStoreFailure(error) }
        catch let error as LibraryError { return .libraryFailure(error) }
        catch { return .libraryFailure(.syncUnavailable) }
    }
}
