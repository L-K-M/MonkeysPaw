package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*

/** Planning never writes or acknowledges cursors. Resolve policy outcomes, then replan fresh baselines. */
internal object SyncReconciler {
    private enum class Missing { DELTA, SNAPSHOT, REMOVED_SCOPE }
    private sealed interface Head {
        val scope: SyncScopeKey
        val mode: Mode
        class Recorded(override val scope: SyncScopeKey) : Head { override val mode = Mode.DELTA }
        class Remote(val remote: SyncReconciliationRemote, override val mode: Mode) : Head {
            override val scope get() = remote.scope
        }
        class Absent(override val scope: SyncScopeKey, val reason: Missing, override val mode: Mode) : Head
    }

    fun plan(pull: SyncCollectedPull, state: SyncState?, local: SyncReconciliationSnapshot,
             groupFolders: Map<ULID, String> = emptyMap()): SyncReconciliationPlan {
        if (local.availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        if (state != null && state.binding != local.binding) throw SyncReconciliationError.BindingMismatch
        val old = state ?: SyncState(local.binding)
        old.validate()
        // Compare once with the pre-pass UUID, never a partly adopted state.
        val mode = when (old.databaseID) {
            null -> SyncReconciliationPlan.Mode.FIRST_SYNC
            pull.databaseID -> SyncReconciliationPlan.Mode.NORMAL
            else -> SyncReconciliationPlan.Mode.RESTORE
        }
        val groups = groups(pull, old, groupFolders)
        if (mode == SyncReconciliationPlan.Mode.NORMAL) {
            for (scope in pull.scopes.keys.sortedBy { it.rawValue }) {
                if (old.cursors[scope] == SyncState.snapshotResetCursor && pull.scopes[scope]?.snapshotHead == null) {
                    throw SyncReconciliationError.SnapshotRequired(scope)
                }
            }
        }
        val files = index(local.files, local.heldPaths)
        val heads = linkedMapOf<ULID, Head>()
        for ((identity, prompt) in old.prompts) {
            if (identity !is PromptIdentity.Assigned) continue
            heads[identity.id] = if (prompt.scope in pull.removed) Head.Absent(prompt.scope, Missing.REMOVED_SCOPE,
                if (mode == SyncReconciliationPlan.Mode.RESTORE) Mode.SNAPSHOT else Mode.DELTA) else Head.Recorded(prompt.scope)
        }

        val snapshots = mutableMapOf<ULID, SyncReconciliationRemote>()
        val snapshotIDs = mutableMapOf<SyncScopeKey, MutableSet<ULID>>()
        pull.forEachPage(Mode.SNAPSHOT) { page ->
            if (pull.scopes[page.scope]?.snapshotHead == null) throw SyncReconciliationError.InvalidPull
            for (item in page.items) {
                val upsert = item.item as? FeedItem.Upsert ?: throw SyncReconciliationError.InvalidPull
                val remote = remote(upsert.prompt, page.scope, groups)
                if (!snapshotIDs.getOrPut(page.scope) { mutableSetOf() }.add(remote.id)) throw SyncReconciliationError.InvalidPull
                val previous = snapshots[remote.id]
                if (previous != null) {
                    // Captured scopes can straddle a move; compare their revs, never the old client rev.
                    if (previous.rev == remote.rev) throw SyncReconciliationError.InvalidPull
                    if (previous.rev > remote.rev) continue
                }
                snapshots[remote.id] = remote
            }
        }
        for ((identity, prompt) in old.prompts) {
            if (identity !is PromptIdentity.Assigned || pull.scopes[prompt.scope]?.snapshotHead == null ||
                snapshotIDs[prompt.scope]?.contains(identity.id) == true) continue
            heads[identity.id] = Head.Absent(prompt.scope, Missing.SNAPSHOT, Mode.SNAPSHOT)
        }
        for ((id, remote) in snapshots) heads[id] = Head.Remote(remote, Mode.SNAPSHOT)

        val deltas = mutableListOf<SyncCollectedItem>()
        pull.forEachPage(Mode.DELTA) { deltas.addAll(it.items) }
        deltas.sortBy { it.seq }
        var lastSeq = 0L
        for (event in deltas) {
            if (event.seq <= lastSeq) throw SyncReconciliationError.InvalidPull
            lastSeq = event.seq
            when (val item = event.item) {
                is FeedItem.Upsert -> {
                    val remote = remote(item.prompt, event.scope, groups)
                    val head = heads[remote.id]
                    if (head != null && head.scope != event.scope && head !is Head.Absent) continue
                    heads[remote.id] = Head.Remote(remote, head?.mode ?: Mode.DELTA)
                }
                is FeedItem.Delete, is FeedItem.MoveOut -> {
                    val id = identifier(if (item is FeedItem.Delete) item.id else (item as FeedItem.MoveOut).id)
                    val head = heads[id] ?: continue
                    if (head.scope != event.scope) continue
                    heads[id] = Head.Absent(event.scope, Missing.DELTA, head.mode)
                }
            }
        }

        val prompts = old.prompts.toMutableMap()
        val operations = mutableListOf<SyncReconciliationOperation>()
        val favorites = old.favorites.toMutableMap()
        for (id in heads.keys.sortedBy { it.rawValue }) {
            val identity = PromptIdentity.Assigned(id)
            val previous = old.prompts[identity]
            val file = files.byID[id]
            when (val head = heads.getValue(id)) {
                is Head.Recorded -> continue
                is Head.Absent -> {
                    if (previous == null || previous.rev == 0L || head.reason == Missing.REMOVED_SCOPE) continue
                    prompts.remove(identity)
                    favorites.remove(identity)
                    if (file == null) continue // A replacement at the old path stays intact.
                    val reason = when {
                        mode == SyncReconciliationPlan.Mode.RESTORE -> SyncReconciliationPreservation.Reason.RESTORE_MISSING
                        clean(file, previous, old.groups) -> null
                        else -> SyncReconciliationPreservation.Reason.DIRTY_REMOVAL
                    }
                    operations.add(if (reason == null) SyncReconciliationOperation.Remove(file) else
                        SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(id, reason, file, null)))
                }
                is Head.Remote -> {
                    val remote = head.remote
                    val markers = ingest(remote.bytes, LibraryPath.filename(remote.path), remote.scope)
                    // Final ownership precedes the rev shortcut, including echoed move-back chains.
                    if (mode != SyncReconciliationPlan.Mode.RESTORE && head.mode == Mode.DELTA &&
                        previous != null && remote.rev <= previous.rev) {
                        if (markers.issue != null && remote.hash == previous.canonicalHash) {
                            prompts[identity] = previous.copy(lastError = markerError(markers.issue, remote))
                        }
                        continue
                    }
                    prompts[identity] = SyncPromptState(remote.scope, remote.path, remote.rev, remote.hash,
                        markers.origin, markers.issue?.let { markerError(it, remote) })
                    if (remote.scope is SyncScopeKey.User) favorites.remove(identity)
                    if (!LibraryPath.isPrompt(remote.libraryPath)) {
                        operations.add(SyncReconciliationOperation.LocalVisibility(remote))
                        continue
                    }
                    val occupants = files.byFoldedPath[folded(remote.libraryPath)].orEmpty()
                    if (occupants.size > 1) {
                        occupants.forEach { operations.add(SyncReconciliationOperation.PathClash(remote, it)) }
                        continue
                    }
                    val target = occupants.firstOrNull()
                    if (target != null && target.path in local.heldPaths) {
                        operations.add(SyncReconciliationOperation.PathClash(remote, target))
                        continue
                    }
                    if (target != null && (target.path != remote.libraryPath || target.identity != identity)) {
                        operations.add(if (mode == SyncReconciliationPlan.Mode.FIRST_SYNC && previous == null)
                            SyncReconciliationOperation.Adoption(remote, target) else SyncReconciliationOperation.PathClash(remote, target))
                        continue
                    }
                    val installation = SyncReconciliationInstall(remote, file, target)
                    val canonical = file?.let { canonical(it, remote.scope) }
                    if (remote.scope is SyncScopeKey.Group && canonical?.favorite != null) {
                        if (canonical.favorite == true) favorites[identity] = true else favorites.remove(identity)
                    }
                    if (file != null && canonical?.canonicalHash != remote.hash.rawValue) {
                        if (mode == SyncReconciliationPlan.Mode.RESTORE) {
                            operations.add(if (remote.mode == SyncFileMode.READ_ONLY) SyncReconciliationOperation.Preserve(
                                SyncReconciliationPreservation(id, SyncReconciliationPreservation.Reason.RESTORE_VIEWER, file, installation))
                                else SyncReconciliationOperation.RestoreUpdate(SyncReconciliationRestoreUpdate(remote, file)))
                            continue
                        }
                        if (previous == null || previous.rev == 0L) {
                            operations.add(SyncReconciliationOperation.Adoption(remote, file))
                            continue
                        }
                        if (!clean(file, previous, old.groups)) {
                            operations.add(SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(id,
                                SyncReconciliationPreservation.Reason.DIRTY_UPSERT, file, installation)))
                            continue
                        }
                    }
                    if (file != null && file.bytes.contentEquals(remote.bytes) && file.path == remote.libraryPath) continue
                    operations.add(SyncReconciliationOperation.Install(installation))
                }
            }
        }
        for (scope in pull.removed.sortedBy { it.rawValue }) {
            if (scope is SyncScopeKey.Group && scope.id in old.groups) operations.add(SyncReconciliationOperation.RemovedScope(scope))
            for (identity in prompts.filterValues { it.scope == scope }.keys) {
                prompts.remove(identity)
                favorites.remove(identity)
            }
        }
        val next = SyncState(local.binding, pull.databaseID, pull.cursors, groups, prompts,
            favorites.filterKeys { prompts[it]?.scope is SyncScopeKey.Group })
        return SyncReconciliationPlan(mode, state, next, operations, files.byPath.keys, local.files.map { it.identity }.toSet())
    }

    private class Files {
        val byPath = linkedMapOf<String, SyncLibraryFile>()
        val byFoldedPath = mutableMapOf<String, MutableList<SyncLibraryFile>>()
        val byID = mutableMapOf<ULID, SyncLibraryFile>()
    }

    private fun index(snapshot: List<SyncLibraryFile>, heldPaths: Set<String>): Files {
        val files = Files()
        for (file in snapshot) {
            try { file.validate() } catch (_: Exception) { throw SyncReconciliationError.InvalidLocalSnapshot }
            if (files.byPath.put(file.path, file) != null) throw SyncReconciliationError.InvalidLocalSnapshot
            files.byFoldedPath.getOrPut(folded(file.path)) { mutableListOf() }.add(file)
            val identity = file.identity
            if (file.path !in heldPaths && identity is PromptIdentity.Assigned && files.byID.put(identity.id, file) != null) {
                throw SyncReconciliationError.InvalidLocalSnapshot // Z10 repairs duplicate eligible identities.
            }
        }
        return files
    }

    private fun groups(pull: SyncCollectedPull, old: SyncState, folders: Map<ULID, String>): Map<ULID, SyncGroupState> {
        val user = SyncScopeKey.User(old.binding.account.userID)
        if (user !in pull.scopes || pull.scopes.keys.count { it is SyncScopeKey.User } != 1 ||
            pull.removed.any { it !is SyncScopeKey.Group || it in pull.scopes }) throw SyncReconciliationError.InvalidPull
        if (old.databaseID != pull.databaseID && pull.scopes.values.any { it.snapshotHead == null }) throw SyncReconciliationError.InvalidPull
        val result = old.groups.filterKeys { SyncScopeKey.Group(it) !in pull.removed }.toMutableMap()
        for ((scope, collected) in pull.scopes) {
            if (scope != SyncScopeKey.parse(collected.identity.key)) throw SyncReconciliationError.InvalidPull
            val group = collected.identity as? ScopeIdentity.Group ?: continue
            val id = identifier(group.groupID)
            val folder = old.groups[id]?.folder ?: folders[id] ?: throw SyncReconciliationError.GroupFolderRequired(id)
            result[id] = SyncGroupState(group.name, folder, group.role)
        }
        return result
    }

    private fun remote(prompt: FeedPrompt, scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): SyncReconciliationRemote = try {
        val id = identifier(prompt.id)
        val path = prompt.path
        if (SyncPathValidator.validate(path, scope.pathScope).path != path || prompt.rev <= 0) throw SyncReconciliationError.InvalidPull
        val libraryPath = rooted(path, scope, groups)
        val bytes = prompt.content.encodeToByteArray(throwOnInvalidSequence = true)
        val filename = LibraryPath.filename(path)
        val form = if (scope is SyncScopeKey.User) CanonicalForm.user(bytes, filename) else CanonicalForm.group(bytes, filename)
        val document = PromptCodec.parseFile(bytes, filename)
        if (document.frontMatter.id != id || !form.bytes.contentEquals(bytes)) throw SyncReconciliationError.InvalidPull
        val mode = if (scope is SyncScopeKey.Group && groups[scope.id]?.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL
        SyncReconciliationRemote(id, scope, path, libraryPath, prompt.rev, bytes, SyncHash.of(bytes), mode)
    } catch (_: Exception) { throw SyncReconciliationError.InvalidPull }

    private fun identifier(raw: String): ULID = try { SyncIdentifiers.ulid(raw) }
        catch (_: Exception) { throw SyncReconciliationError.InvalidPull }

    private fun rooted(path: String, scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): String {
        val value = if (scope is SyncScopeKey.Group) "Groups/${groups[scope.id]?.folder ?: throw SyncReconciliationError.InvalidPull}/$path" else path
        StorePath.validate(value)
        return value
    }

    private fun clean(file: SyncLibraryFile, prompt: SyncPromptState, groups: Map<ULID, SyncGroupState>): Boolean =
        file.path == rooted(prompt.path, prompt.scope, groups) && canonical(file, prompt.scope)?.canonicalHash == prompt.canonicalHash?.rawValue

    private fun canonical(file: SyncLibraryFile, scope: SyncScopeKey): CanonicalForm? = try {
        val filename = LibraryPath.filename(file.path)
        if (scope is SyncScopeKey.User) CanonicalForm.user(file.bytes, filename) else CanonicalForm.group(file.bytes, filename)
    } catch (_: Exception) { null }

    internal class Markers(val origin: SyncPromptOrigin?, val issue: SyncIssueCode?)
    internal fun ingest(bytes: ByteArray, filename: String, scope: SyncScopeKey): Markers {
        val document = PromptCodec.parseFile(bytes, filename)
        if (SyncMutationOrigin.hasInvalidOrigin(document)) return Markers(null, SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE))
        val origin = SyncMutationOrigin.origin(document)
        return Markers(if (scope is SyncScopeKey.User) origin else null, null)
    }

    private fun markerError(issue: SyncIssueCode, remote: SyncReconciliationRemote) = SyncPromptError(issue,
        SyncInputFingerprint(remote.bytes, remote.path, remote.scope, 0, SyncOperation.PUT))

    fun folded(path: String): String = try { syncPathKey(path) }
        catch (_: Exception) { throw SyncReconciliationError.InvalidLocalSnapshot }
}
