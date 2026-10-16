package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Collections
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

data class GroupAccessGroup(val id: ULID, val name: String, val folder: String, val role: Role)

sealed interface PromptAccessState {
    data object Local : PromptAccessState
    data class Group(val group: GroupAccessGroup) : PromptAccessState
    data object Unavailable : PromptAccessState

    val readOnlyReason: SourceReadOnlyReason? get() = when (this) {
        Local -> null
        is Group -> if (group.role == Role.VIEWER) SourceReadOnlyReason.GROUP_VIEWER else null
        Unavailable -> SourceReadOnlyReason.GROUP_UNAVAILABLE
    }
}

/** Committed access and favourites accompany entries; documents and canonical bytes stay intact. */
class GroupAccessSnapshot internal constructor(
    val generation: Long,
    groups: Map<ULID, GroupAccessGroup>,
    val isBlocked: Boolean,
    internal val binding: SyncLibraryIdentity?,
    internal val prompts: Map<PromptIdentity, SyncPromptState>,
    internal val favorites: Map<PromptIdentity, Boolean>,
    internal val unavailableIDs: Set<PromptIdentity>,
    internal val managesGroups: Boolean,
    internal val accessVersions: List<Long> = emptyList(),
) {
    val groups: Map<ULID, GroupAccessGroup> = groups.syncMapCopy()

    fun access(path: String, identity: PromptIdentity? = null): PromptAccessState {
        if (isBlocked) return PromptAccessState.Unavailable
        val destination = accessForPath(path)
        if (destination == PromptAccessState.Unavailable) return destination
        if (identity in unavailableIDs) return PromptAccessState.Unavailable
        val recorded = prompts[identity]?.scope as? SyncScopeKey.Group ?: return destination
        val source = groups[recorded.id] ?: return PromptAccessState.Unavailable
        // An external move must satisfy both recorded source and actual destination authority.
        if (source.role == Role.VIEWER) return PromptAccessState.Group(source)
        if (destination.readOnlyReason != null) return destination
        return PromptAccessState.Group(source)
    }

    internal fun accessForPath(path: String): PromptAccessState {
        if (isBlocked) return PromptAccessState.Unavailable
        if (!managesGroups) return PromptAccessState.Local
        val parts = path.split('/')
        if (SyncPathCaseFold.fold(parts.first()) != "groups") return PromptAccessState.Local
        if (parts.size < 3) return PromptAccessState.Unavailable
        val group = groups.values.firstOrNull { SyncPathCaseFold.fold(it.folder) == SyncPathCaseFold.fold(parts[1]) }
            ?: return PromptAccessState.Unavailable
        return PromptAccessState.Group(group)
    }

    internal fun favorite(entry: LibraryEntry): Boolean = when (access(entry.relativePath, entry.identity)) {
        PromptAccessState.Local -> entry.document.frontMatter.favorite
        is PromptAccessState.Group -> if (prompts[entry.identity]?.scope is SyncScopeKey.Group) {
            favorites[entry.identity] == true
        } else entry.document.frontMatter.favorite
        PromptAccessState.Unavailable -> false
    }

    internal fun samePolicy(other: GroupAccessSnapshot): Boolean = accessVersions == other.accessVersions && binding == other.binding && groups == other.groups &&
        isBlocked == other.isBlocked && managesGroups == other.managesGroups && unavailableIDs == other.unavailableIDs &&
        prompts.mapValues { it.value.scope } == other.prompts.mapValues { it.value.scope }

    override fun toString(): String = "<group access snapshot>"

    internal companion object {
        val local = GroupAccessSnapshot(0, emptyMap(), false, null, emptyMap(), emptyMap(), emptySet(), false)
    }
}

/** Capture before queueing an editor write or assistant acceptance; cancel when its session retires.
 * Admission and policy checks run again inside the library boundary, including after lock waits.
 */
class LibraryWritePermit internal constructor(private val owner: Any, val accessGeneration: Long, private val job: Job?) {
    private val cancelled = AtomicBoolean()
    fun cancel() { cancelled.set(true) }

    internal fun check(owner: Any, generation: Long) {
        if (cancelled.get() || job?.isActive == false || Thread.currentThread().isInterrupted) {
            throw CancellationException("Library work was cancelled.")
        }
        if (this.owner !== owner || generation != accessGeneration) throw LibraryError.AccessChanged
    }

    override fun toString(): String = "<library write permit>"
}

/** One per library graph, using the engine's existing stores. Construction performs no IO/HTTP.
 * Persistence callbacks run after its locks release; admission also samples the volatile caches so
 * a committed downgrade cannot be bypassed by a write queued ahead of its notification.
 */
class GroupAccessService(
    private val library: LibraryService,
    private val states: SyncStateStore,
    private val accounts: SyncAccountStore,
    libraryRoot: String,
) {
    private val root = SyncLibraryRoot(libraryRoot)
    private val mutableSnapshots = MutableStateFlow(GroupAccessSnapshot.local)
    val snapshots = mutableSnapshots.asStateFlow()
    val snapshot: GroupAccessSnapshot get() = library.accessSnapshot

    init {
        library.attachGroupAccess(this)
        states.observeChanges(::refresh)
        accounts.observeChanges(::refresh)
        refresh()
    }

    private fun refresh() = library.withSyncLock { refreshLocked() }

    internal fun refreshLocked() {
        val previous = library.accessSnapshot
        val cached = states.snapshot
        val state = cached.value
        val matches = state == null || state.binding.root == root &&
            (accounts.cachedAccount == null || accounts.cachedAccount?.identity == state.binding.account)
        val groups = if (matches) state?.groups.orEmpty().mapValues { (id, group) ->
            GroupAccessGroup(id, group.name, group.folder, group.role)
        } else emptyMap()
        val prompts = if (matches) state?.prompts.orEmpty() else emptyMap()
        val unavailable = previous.unavailableIDs.toMutableSet()
        previous.prompts.forEach { (id, prompt) -> if (id !in prompts && prompt.scope is SyncScopeKey.Group) unavailable.add(id) }
        unavailable.removeAll(prompts.keys)
        val candidate = GroupAccessSnapshot(previous.generation, groups,
            cached.error != null || accounts.readOnlyError != null || !matches,
            if (matches) state?.binding else null, prompts, if (matches) state?.favorites.orEmpty() else emptyMap(),
            Collections.unmodifiableSet(unavailable), state != null || previous.managesGroups || accounts.cachedBindings.any { it.root == root },
            listOf(cached.accessVersion) + accounts.accessVersions)
        val policyChanged = !candidate.samePolicy(previous)
        if (!policyChanged && candidate.favorites == previous.favorites) return
        val next = GroupAccessSnapshot(previous.generation + if (policyChanged) 1 else 0, candidate.groups,
            candidate.isBlocked, candidate.binding, candidate.prompts, candidate.favorites, candidate.unavailableIDs,
            candidate.managesGroups, candidate.accessVersions)
        library.installGroupAccess(next)
        mutableSnapshots.value = next
    }

    /** Personal state intent: no source write, mode change, history or sync scheduling. */
    internal fun toggleFavorite(entry: LibraryEntry): LibrarySaveResult {
        val expected = snapshot
        val binding = expected.binding ?: throw LibraryError.AccessDenied
        if (entry.accessGeneration != expected.generation || expected.isBlocked) throw LibraryError.AccessChanged
        states.update(binding) { state ->
            val current = library.checkedFavoriteEntry(entry, expected.generation)
            val access = expected.access(current.relativePath, current.identity) as? PromptAccessState.Group
                ?: throw LibraryError.AccessDenied
            val recorded = state.prompts[current.identity] ?: run {
                val prefix = "Groups/${access.group.folder}/"
                if (!current.relativePath.startsWith(prefix)) throw LibraryError.AccessDenied
                SyncPromptState(SyncScopeKey.Group(access.group.id), current.relativePath.removePrefix(prefix), 0)
            }
            if (recorded.scope !is SyncScopeKey.Group || recorded.scope.id !in state.groups) throw LibraryError.AccessDenied
            // Preserve the observed key even while unrelated source errors prevent canonicalization.
            val input = current.document.preservedHeader?.entries
                ?.firstOrNull { PortableYaml.string(it.key) == "favorite" }?.let { PortableYaml.boolean(it.value) }
            state.copy(prompts = state.prompts + (current.identity to recorded.copy(favoriteInput = SyncFavoriteInput(input))))
                .applyGroupFavorite(!current.favorite, current.identity)
        }
        return LibrarySaveResult(library.load(entry.relativePath))
    }
}
