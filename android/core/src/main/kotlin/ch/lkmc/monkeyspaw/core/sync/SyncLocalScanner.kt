package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssue
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.Role

internal class SyncLocalPrompt(
    val file: SyncLibraryFile,
    val identity: PromptIdentity,
    val scope: SyncScopeKey,
    /** NFC wire path; file.path keeps the exact filesystem spelling. */
    val path: String,
    val canonical: CanonicalForm,
    val origin: SyncPromptOrigin?,
) {
    override fun toString(): String = "<local sync prompt>"
}

internal sealed class SyncLocalChange {
    class Create(val prompt: SyncLocalPrompt) : SyncLocalChange()
    class Update(val prompt: SyncLocalPrompt, val recorded: SyncPromptState) : SyncLocalChange()
    class Rename(val prompt: SyncLocalPrompt, val recorded: SyncPromptState) : SyncLocalChange()
    /** Send the transfer before any accompanying content edit. */
    class Move(val prompt: SyncLocalPrompt, val recorded: SyncPromptState) : SyncLocalChange()
    class Delete(val identity: PromptIdentity, val recorded: SyncPromptState) : SyncLocalChange()
    final override fun toString(): String = "<local sync change>"
}

internal class SyncLocalScan(
    val snapshot: SyncReconciliationSnapshot,
    /** Z12 journals rescues/hold migration, then scans again before matching. */
    orphanFiles: List<SyncLibraryFile>,
    issues: Map<String, SyncIssueCode>,
    /** Commit old cursors through the journal and rescan; changes are empty during preparation. */
    val preparation: SyncApplyPlan?,
    changes: List<SyncLocalChange>,
) {
    val orphanFiles = orphanFiles.syncListCopy()
    val issues = issues.syncMapCopy()
    val changes = changes.syncListCopy()
    override fun toString(): String = "<local sync scan>"
}

internal object SyncLocalScanner {
    class Location(val scope: SyncScopeKey, val path: String)

    fun scan(binding: SyncLibraryIdentity, state: SyncState?, ownership: SyncLibraryBinding? = null,
             retainedRescues: List<SyncRetainedRescue> = emptyList(),
             availability: SyncReconciliationSnapshot.Availability, accessGeneration: Long = 0,
             freshID: () -> ULID, mutations: SyncLibraryMutations): SyncLocalScan {
        if (availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        if (state != null && state.binding != binding ||
            ownership != null && (ownership.root != binding.root || ownership.owner != binding.account)) throw SyncError.BindingMismatch
        ownership?.validate()
        val old = state ?: SyncState(binding)
        old.validate()
        val files = mutations.listedFiles()
        if (files.map { it.path }.toSet().size != files.size) throw SyncError.InvalidState
        val held = mutableSetOf<String>()
        val issues = linkedMapOf<String, SyncIssueCode>()
        val orphans = mutableListOf<SyncLibraryFile>()
        val eligible = mutableListOf<Pair<SyncLibraryFile, Location>>()
        for (file in files) {
            val path = file.path
            val identity = file.identity
            if (ownership?.isHeld(identity, path, file.hash) == true) held.add(path)
            for (rescue in retainedRescues.filter { it.binding.root == binding.root }) {
                if (rescue.path == path || rescue.hash == file.hash) {
                    held.add(path)
                    issues[path] = rescue.issue
                }
            }
            val location = location(path, binding, old.groups)
            if (location == null) {
                orphans.add(file)
                held.add(path)
                continue
            }
            if (location.scope is SyncScopeKey.Group) {
                val group = old.groups[location.scope.id]
                val folder = ownership?.managedFolders?.entries?.firstOrNull { it.value.folder == group?.folder }
                if (folder != null && (folder.key != location.scope.id || folder.value.owner != binding.account)) {
                    orphans.add(file)
                    held.add(path)
                    continue
                }
            }
            if (!LibraryPath.isPrompt(path)) {
                held.add(path)
                if (identity in old.prompts || old.prompts.values.any {
                    rooted(it.path, it.scope, old.groups) == path
                }) issues[path] = SyncIssueCode.LocalVisibility
            } else {
                val issue = contentIssue(file)
                if (issue != null) {
                    held.add(path)
                    issues[path] = issue
                } else if (path !in held) eligible.add(file to location)
            }
        }
        fun snapshot() = SyncReconciliationSnapshot(binding, files, heldPaths = held)
        if (orphans.isNotEmpty()) return SyncLocalScan(snapshot(), orphans, issues, null, emptyList())

        val prompts = old.prompts.toMutableMap()
        val favorites = old.favorites.toMutableMap()
        val edits = mutableListOf<SyncLibraryEdit>()
        val used = mutableSetOf<PromptIdentity>()
        val byID = mutableMapOf<ULID, String>()
        val reserved = (old.prompts.keys + files.map { it.identity }).toMutableSet()
        fun allocate(): ULID = freshID().also {
            if (!reserved.add(PromptIdentity.Assigned(it))) throw SyncError.InvalidState
        }
        // Reserve every ID match first: an earlier idless copy cannot steal a renamed original's record.
        for ((file, _) in eligible) {
            val identity = file.identity
            if (identity is PromptIdentity.Assigned && identity.id !in byID) {
                byID[identity.id] = file.path
                if (identity in old.prompts) used.add(identity)
            }
        }
        val changes = mutableListOf<SyncLocalChange>()
        for ((file, location) in eligible) {
            val originalIdentity = file.identity
            val duplicate = originalIdentity is PromptIdentity.Assigned && byID[originalIdentity.id] != file.path
            val wire = try { SyncPathValidator.validate(location.path, location.scope.pathScope) }
            catch (issue: SyncPathIssue) {
                issues[file.path] = SyncIssueCode.Path(issue.code)
                held.add(file.path)
                continue
            }
            var identity = originalIdentity
            var recorded = if (duplicate) null else old.prompts[identity]
            var stateSource = identity
            if (!duplicate && recorded == null) {
                val candidates = old.prompts.entries.filter {
                    it.key !in used && (identity is PromptIdentity.Local || it.key is PromptIdentity.Local) &&
                        it.value.scope == location.scope && SyncNaming.pathKey(it.value.path) == wire.pathKey
                }.sortedBy { it.key.storageKey }
                if (candidates.size > 1) throw SyncError.InvalidState
                candidates.firstOrNull()?.let {
                    stateSource = it.key
                    recorded = it.value
                    used.add(it.key)
                    if (identity is PromptIdentity.Local && it.key is PromptIdentity.Assigned) identity = it.key
                }
            }
            val externalAssignment = originalIdentity !is PromptIdentity.Local && stateSource is PromptIdentity.Local && stateSource != identity
            if (externalAssignment && stateSource != PromptIdentity.at(file.path)) {
                issues[file.path] = SyncIssueCode.IDMismatch
                held.add(file.path)
                continue
            }
            val viewer = isViewer(location.scope, old.groups) || recorded?.let { isViewer(it.scope, old.groups) } == true
            if (duplicate || identity == originalIdentity && identity is PromptIdentity.Local) {
                if (viewer) {
                    issues[file.path] = if (duplicate) SyncIssueCode.IDMismatch else SyncIssueCode.Forbidden
                    if (duplicate) held.add(file.path)
                    continue
                }
                identity = PromptIdentity.Assigned(allocate())
            }
            var bytes = file.bytes
            if (identity != originalIdentity) {
                val id = (identity as? PromptIdentity.Assigned)?.id ?: throw SyncError.InvalidState
                val filename = LibraryPath.filename(file.path)
                bytes = PromptMutations.replacingIdentity(id, PromptCodec.parseFile(bytes, filename), filename)
                    .source.encodeToByteArray(throwOnInvalidSequence = true)
            }
            val canonical = canonical(bytes, location.path, location.scope)
            val origin = SyncConflictMetadata.origin(bytes, LibraryPath.filename(file.path), location.scope.pathScope)
            val transferring = recorded?.scope?.let { it != location.scope } == true
            // An acknowledged baseline stays unchanged until the push commits; only creates use the current path.
            val pending = SyncPromptState(recorded?.scope ?: location.scope, recorded?.path ?: wire.path,
                recorded?.rev ?: 0, recorded?.canonicalHash, if (transferring) recorded.origin else origin, recorded?.lastError)
            if (!duplicate && stateSource != identity) migrate(prompts, favorites, stateSource, identity)
            prompts[identity] = pending
            if (location.scope is SyncScopeKey.Group && pending.scope is SyncScopeKey.Group) {
                canonical.favorite?.let { if (it) favorites[identity] = true else favorites.remove(identity) }
            }
            if (viewer && (recorded == null || recorded.canonicalHash?.rawValue != canonical.canonicalHash ||
                    recorded.scope != location.scope || recorded.path != wire.path)) {
                issues[file.path] = SyncIssueCode.Forbidden
                // Denial recovery must retain the original bytes before group
                // canonicalization can strip the user's local metadata.
                continue
            }
            // Preserve personal keys on disk until a scope transfer acknowledges their new owner.
            if (!transferring && (externalAssignment || !bytes.contentEquals(file.bytes) ||
                    location.scope is SyncScopeKey.Group && !canonical.bytes.contentEquals(file.bytes))) {
                val kind = if (duplicate) SyncLibraryEdit.Kind.REPAIR_DUPLICATE
                    else if (identity != originalIdentity || externalAssignment) SyncLibraryEdit.Kind.ADOPT else SyncLibraryEdit.Kind.APPLY
                edits.add(mutations.publication(canonical.bytes, file.path, file,
                    SyncIdentityTransition(if (externalAssignment) stateSource else originalIdentity, identity),
                    if (isViewer(location.scope, old.groups)) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL, kind))
            }
            val prompt = SyncLocalPrompt(file, identity, location.scope, wire.path, canonical, origin)
            if (viewer) continue
            val baseline = recorded
            changes.add(when {
                baseline == null || baseline.rev == 0L -> SyncLocalChange.Create(prompt)
                baseline.scope != prompt.scope -> SyncLocalChange.Move(prompt, baseline)
                baseline.path != prompt.path -> SyncLocalChange.Rename(prompt, baseline)
                baseline.canonicalHash?.rawValue != canonical.canonicalHash -> SyncLocalChange.Update(prompt, baseline)
                else -> continue
            })
        }

        val presentPaths = files.map { it.path }.toSet()
        val presentIDs = files.map { it.identity }.toSet()
        for ((identity, recorded) in old.prompts.entries.sortedBy { it.key.storageKey }) {
            val path = rooted(recorded.path, recorded.scope, old.groups)
            if (!LibraryPath.isPrompt(path)) {
                issues[path] = SyncIssueCode.LocalVisibility
                held.add(path)
                continue
            }
            if (recorded.rev == 0L || identity in presentIDs || path in presentPaths ||
                ownership?.isHeld(identity, path, recorded.canonicalHash ?: SyncHash.of(byteArrayOf())) == true ||
                retainedRescues.any { it.binding.root == binding.root && it.path == path }) continue
            // The full listing omits symlinks; a checked probe must prove absence without following them.
            try {
                if (mutations.read(path) != null) throw LibraryError.Conflict
            } catch (error: StoreError) {
                if (error != StoreError.NotRegularFile && error != StoreError.OutsideRoot) throw error
                issues[path] = SyncIssueCode.LocalVisibility
                held.add(path)
                continue
            }
            if (isViewer(recorded.scope, old.groups)) {
                issues[path] = SyncIssueCode.Forbidden
                continue
            }
            changes.add(SyncLocalChange.Delete(identity, recorded))
        }
        for ((path, issue) in issues) {
            val file = files.firstOrNull { it.path == path }
            val location = location(path, binding, old.groups) ?: continue
            // A held invalid duplicate cannot replace the eligible owner's baseline or error.
            val key = file?.let { value ->
                if (path in held && files.any { it.path != path && it.identityKey == value.identityKey }) PromptIdentity.at(path)
                else value.identity
            } ?: old.prompts.entries.firstOrNull { rooted(it.value.path, it.value.scope, old.groups) == path }?.key ?: continue
            val existing = prompts[key]
            val error = SyncPromptError(issue, SyncInputFingerprint(file?.bytes ?: byteArrayOf(), location.path,
                location.scope, accessGeneration, SyncOperation.PUT))
            prompts[key] = SyncPromptState(existing?.scope ?: location.scope,
                existing?.path ?: location.path, existing?.rev ?: 0, existing?.canonicalHash, existing?.origin, error)
        }
        val next = old.copy(prompts = prompts, favorites = favorites)
        val preparation = if (edits.isEmpty() && next == old) null else SyncApplyPlan(state, next, edits)
        return SyncLocalScan(snapshot(), emptyList(), issues, preparation, if (preparation == null) changes else emptyList())
    }

    fun location(path: String, binding: SyncLibraryIdentity, groups: Map<ULID, SyncGroupState>): Location? {
        val parts = path.split('/')
        if (SyncPathCaseFold.fold(parts.first()) != "groups") return Location(SyncScopeKey.User(binding.account.userID), path)
        if (parts.size < 3 || parts[0] != "Groups") return null
        val group = groups.entries.firstOrNull { it.value.folder == parts[1] } ?: return null
        return Location(SyncScopeKey.Group(group.key), parts.drop(2).joinToString("/"))
    }

    fun rooted(path: String, scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): String {
        val value = if (scope is SyncScopeKey.Group) "Groups/" + (groups[scope.id]?.folder ?: throw SyncError.InvalidScope) + "/" + path else path
        StorePath.validate(value)
        return value
    }

    fun canonical(bytes: ByteArray, path: String, scope: SyncScopeKey): CanonicalForm =
        if (scope is SyncScopeKey.User) CanonicalForm.user(bytes, LibraryPath.filename(path))
        else CanonicalForm.group(bytes, LibraryPath.filename(path))

    fun migrating(state: SyncState, source: PromptIdentity, destination: PromptIdentity): SyncState {
        if (source == destination) return state
        val prompts = state.prompts.toMutableMap()
        val favorites = state.favorites.toMutableMap()
        migrate(prompts, favorites, source, destination)
        return state.copy(prompts = prompts, favorites = favorites)
    }

    private fun migrate(prompts: MutableMap<PromptIdentity, SyncPromptState>, favorites: MutableMap<PromptIdentity, Boolean>,
                        source: PromptIdentity, destination: PromptIdentity) {
        prompts.remove(source)?.let {
            if (destination in prompts) throw SyncError.InvalidState
            prompts[destination] = it
        }
        favorites.remove(source)?.let { favorites[destination] = it }
    }

    fun contentIssue(file: SyncLibraryFile): SyncIssueCode? {
        val document = PromptCodec.parseFile(file.bytes, LibraryPath.filename(file.path))
        if (document.isReadOnly) return SyncIssueCode.Content(PromptIssueCode.UNSUPPORTED_FORMAT)
        document.issues.firstOrNull { it.severity == PromptIssueSeverity.ERROR }?.let { return SyncIssueCode.Content(it.code) }
        if (SyncConflictMetadata.hasInvalidOrigin(document)) return SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE)
        return null
    }

    private fun isViewer(scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): Boolean =
        scope is SyncScopeKey.Group && groups[scope.id]?.role == Role.VIEWER
}
