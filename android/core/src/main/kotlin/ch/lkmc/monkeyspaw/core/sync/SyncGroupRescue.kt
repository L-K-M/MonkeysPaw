package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.*
import java.time.Instant

/** A held/viewer path occupant uses the same checked rescue and hold migration as cleanup. */
internal fun SyncGroupFolders.rescueOccupant(file: SyncLibraryFile, state: SyncState?, ownership: SyncLibraryBinding?,
                                           inventory: SyncGroupFolderInventory, at: Instant, freshID: () -> ULID,
                                           mutations: SyncLibraryMutations): SyncApplyPlan {
    validate(inventory, state, ownership)
    val old = state ?: SyncState(inventory.local.binding)
    val owned = ownership ?: SyncLibraryBinding(old.binding.root, old.binding.account)
    val result = rescue(listOf(file), { false }, inventory, owned, ownership, old, HoldPolicy.MATCHING, at, freshID, mutations)
    var next = result.state
    val record = next.prompts[file.identity]
    if (record != null && record.rev > 0) {
        // Keep identity and overlay; a snapshot must restore this internal retirement before push.
        next = next.copy(prompts = next.prompts + (file.identity to SyncPromptState(record.scope, record.path, 0, origin = record.origin)),
            cursors = next.cursors + (record.scope to SyncState.snapshotResetCursor))
    }
    return SyncApplyPlan(state, next, result.edits,
        bindingChange = if (result.ownership == ownership) null else SyncBindingChange(ownership, result.ownership))
}

/** Complete-pull accessible IDs must already be installed outside removed folders before cleanup. */
internal fun SyncGroupFolders.removed(scopes: Set<SyncScopeKey>, state: SyncState, ownership: SyncLibraryBinding?,
                                     inventory: SyncGroupFolderInventory, retainingIDs: Set<PromptIdentity> = emptySet(),
                                     at: Instant, freshID: () -> ULID, mutations: SyncLibraryMutations): SyncApplyPlan {
    validate(inventory, state, ownership)
    if (ownership != null && ownership.owner != state.binding.account) throw SyncError.BindingMismatch
    val ids = scopes.map { (it as? SyncScopeKey.Group)?.id ?: throw SyncError.InvalidScope }.toSet()
    val folders = ids.flatMap { id -> listOfNotNull(state.groups[id]?.folder, ownership?.managedFolders?.get(id)?.folder) }
        .map { "Groups/$it" }.toSet()
    val files = inventory.local.files.filter { file ->
        val inFolder = folders.any { contains(file.path, it) || file.path == it }
        val recorded = state.prompts[file.identity]
        if (file.identity in retainingIDs) {
            if (inFolder || recorded?.scope in scopes) throw SyncGroupFolderError.AccessibleInstallationRequired
            false
        } else inFolder || recorded?.scope in scopes
    }
    val next = dropping(scopes, state)
    val owned = (ownership ?: SyncLibraryBinding(state.binding.root, state.binding.account)).let {
        it.copy(managedFolders = it.managedFolders - ids)
    }
    val identityCounts = inventory.local.files.groupingBy { it.identity }.eachCount()
    val clean: (SyncLibraryFile) -> Boolean = clean@{ file ->
        val record = state.prompts[file.identity]
        if (identityCounts[file.identity] != 1 || file.path in inventory.local.heldPaths ||
            ownership?.isHeld(file.identity, file.path, file.hash) == true || !LibraryPath.isPrompt(file.path) ||
            SyncLocalScanner.contentIssue(file) != null || record == null || record.rev <= 0 || record.scope !in scopes ||
            SyncLocalScanner.rooted(record.path, record.scope, state.groups) != file.path) return@clean false
        val canonical = try { SyncLocalScanner.canonical(file.bytes, record.path, record.scope) } catch (_: Exception) { return@clean false }
        canonical.canonicalHash == record.canonicalHash?.rawValue
    }
    val result = rescue(files, clean, inventory, owned, ownership, next, HoldPolicy.MATCHING, at, freshID, mutations)
    return removalPlan(state, result, ownership, folders, inventory)
}

/** Orphan and loose Groups files never enter matching/push, including unsupported regular files. */
internal fun SyncGroupFolders.stale(state: SyncState?, ownership: SyncLibraryBinding?, inventory: SyncGroupFolderInventory,
                                   at: Instant, freshID: () -> ULID, mutations: SyncLibraryMutations): SyncApplyPlan {
    validate(inventory, state, ownership)
    val binding = inventory.local.binding
    if (ownership != null && ownership.owner != binding.account) throw SyncError.BindingMismatch
    val old = state ?: SyncState(binding)
    val owned = ownership ?: SyncLibraryBinding(binding.root, binding.account)
    val legitimate = old.groups.mapNotNull { (id, group) ->
        val retained = owned.managedFolders[id]
        if (retained != null && (retained.owner != binding.account || retained.folder != group.folder) ||
            owned.managedFolders.any { it.key != id && it.value.folder == group.folder }) null
        else SyncNaming.pathKey("Groups/" + group.folder)
    }.toSet()
    val roots = inventory.directories.keys.filter { path ->
        val parts = path.split('/')
        isGroupsPath(path) && (parts.size == 2 && SyncNaming.pathKey(path) !in legitimate || parts.size == 1 && path != "Groups")
    }.toSet()
    val files = inventory.local.files.filter { file ->
        val parts = file.path.split('/')
        isGroupsPath(file.path) && (parts.size < 3 || parts[0] != "Groups" ||
            SyncNaming.pathKey(parts.take(2).joinToString("/")) !in legitimate)
    }
    val retired = files.map { it.identity }.toSet()
    val cursors = old.cursors.toMutableMap()
    old.prompts.filterKeys { it in retired }.values.forEach { cursors[it.scope] = SyncState.snapshotResetCursor }
    val next = old.copy(cursors = cursors, prompts = old.prompts - retired, favorites = old.favorites - retired)
    val nextOwned = owned.copy(managedFolders = owned.managedFolders.filterValues {
        SyncNaming.pathKey("Groups/" + it.folder) in legitimate
    })
    val result = rescue(files, { false }, inventory, nextOwned, ownership, next, HoldPolicy.MATCHING, at, freshID, mutations)
    return removalPlan(state, result, ownership, roots, inventory)
}

/** Use the previous binding after sign-out; commit rescues/holds before enabling the new account. */
internal fun SyncGroupFolders.accountChange(account: SyncAccountIdentity, state: SyncState?, ownership: SyncLibraryBinding,
                                           inventory: SyncGroupFolderInventory, at: Instant, freshID: () -> ULID,
                                           mutations: SyncLibraryMutations): SyncApplyPlan? {
    validate(inventory, state, ownership)
    if (ownership.owner != inventory.local.binding.account) throw SyncError.BindingMismatch
    if (ownership.owner == account) return null
    val old = state ?: SyncState(inventory.local.binding)
    val scopes = old.groups.keys.map { SyncScopeKey.Group(it) }.toSet()
    val next = dropping(scopes, old)
    val owned = ownership.copy(owner = account, managedFolders = emptyMap())
    val groupFiles = inventory.local.files.filter {
        isGroupsPath(it.path) || old.prompts[it.identity]?.scope is SyncScopeKey.Group
    }
    val groupPaths = groupFiles.map { it.path }.toSet()
    val roots = inventory.directories.keys.filter {
        val depth = it.split('/').size
        isGroupsPath(it) && (depth == 2 || depth == 1 && it != "Groups")
    }.toSet()
    val result = rescue(groupFiles, { false }, inventory, owned, ownership, next, HoldPolicy.ALL, at, freshID, mutations)
    val holds = result.ownership.holds.toMutableList()
    val edits = result.edits.toMutableList()
    var finalState = result.state
    val reserved = (inventory.local.files.map { it.identity } + finalState.prompts.keys + holds.map { it.identity }).toMutableSet()
    for (file in inventory.local.files.filter { it.path !in groupPaths }) {
        var identity = file.identity
        var bytes = file.bytes
        if (identity is PromptIdentity.Local && LibraryPath.isPrompt(file.path) && SyncLocalScanner.contentIssue(file) == null) {
            val id = freshID()
            val assigned = PromptIdentity.Assigned(id)
            if (!reserved.add(assigned)) throw SyncError.InvalidState
            val filename = LibraryPath.filename(file.path)
            bytes = PromptMutations.replacingIdentity(id, PromptCodec.parseFile(bytes, filename), filename).source
                .encodeToByteArray(throwOnInvalidSequence = true)
            edits.add(mutations.publication(bytes, file.path, file, SyncIdentityTransition(identity, assigned), kind = SyncLibraryEdit.Kind.ADOPT))
            finalState = SyncLocalScanner.migrating(finalState, identity, assigned)
            identity = assigned
            if (identity !in finalState.prompts) {
                finalState = finalState.copy(prompts = finalState.prompts + (identity to SyncPromptState(
                    SyncScopeKey.User(old.binding.account.userID), file.path, 0, origin = SyncConflictMetadata.origin(bytes, filename))))
            }
        }
        migrateHold(file, file.path, identity, SyncHash.of(bytes), ownership.owner, holds, HoldPolicy.ALL)
    }
    return removalPlan(state, RescueResult(finalState, result.ownership.copy(holds = holds), edits), ownership, roots, inventory)
}

private enum class HoldPolicy { MATCHING, ALL }

private class RescueResult(val state: SyncState, val ownership: SyncLibraryBinding, val edits: List<SyncLibraryEdit>)

private fun rescue(files: List<SyncLibraryFile>, clean: (SyncLibraryFile) -> Boolean, inventory: SyncGroupFolderInventory,
                   ownership: SyncLibraryBinding, previousOwnership: SyncLibraryBinding?, state: SyncState, holdPolicy: HoldPolicy,
                   at: Instant, freshID: () -> ULID, mutations: SyncLibraryMutations): RescueResult {
    val copies = mutableListOf<SyncLibraryEdit>()
    val retirements = mutableListOf<SyncLibraryEdit>()
    val occupied = (inventory.local.files.map { it.path } + inventory.directories.keys).toMutableList()
    val reserved = (inventory.local.files.map { it.identity } + state.prompts.keys + ownership.holds.map { it.identity }).toMutableSet()
    val holds = ownership.holds.toMutableList()
    val prompts = state.prompts.toMutableMap()
    for (file in files.sortedWith { a, b -> comparePaths(a.path, b.path) }) {
        if (!clean(file)) {
            val id = freshID()
            if (!reserved.add(PromptIdentity.Assigned(id))) throw SyncError.InvalidState
            val destination = SyncNaming.rescue(file.path, at, occupied)
            // An occupied regular ancestor cannot become a destination directory.
            if (inventory.local.files.any { SyncGroupFolders.contains(destination, it.path) }) throw SyncGroupFolderError.RescueRequired
            val edit = mutations.rescue(file, destination, id)
            copies.add(edit)
            occupied.add(destination)
            val held = file.path in inventory.local.heldPaths || edit.heldIssue != null
            val identity = if (edit.heldIssue == null) PromptIdentity.Assigned(id) else PromptIdentity.at(destination)
            val sourceAccount = previousOwnership?.managedFolders?.values?.firstOrNull {
                SyncGroupFolders.contains(file.path, "Groups/" + it.folder)
            }?.owner ?: inventory.local.binding.account
            migrateHold(file, destination, identity, edit.hash ?: throw SyncError.InvalidState, sourceAccount, holds,
                if (holdPolicy == HoldPolicy.ALL || held || sourceAccount != inventory.local.binding.account) HoldPolicy.ALL else HoldPolicy.MATCHING)
            if (edit.heldIssue == null) prompts[identity] = SyncPromptState(SyncScopeKey.User(state.binding.account.userID),
                destination, 0, origin = SyncPromptOrigin.Rescued)
        }
        retirements.add(mutations.trash(file))
    }
    return RescueResult(state.copy(prompts = prompts), ownership.copy(holds = holds), copies + retirements)
}

private fun migrateHold(file: SyncLibraryFile, path: String, identity: PromptIdentity, hash: SyncHash,
                        sourceAccount: SyncAccountIdentity, holds: MutableList<SyncHeldPrompt>, policy: HoldPolicy) {
    val matches = holds.filter { it.path == file.path || it.identity == file.identity || it.contentHash == file.hash }
    if (policy == HoldPolicy.MATCHING && matches.isEmpty()) return
    // Hash equality keeps moved idless bytes held, but cannot establish account provenance.
    val source = matches.firstOrNull { it.path == file.path || it.identity == file.identity }
    holds.removeAll { it.path == file.path || it.path == path || it.identity != file.identity && it.contentHash == file.hash }
    holds.add(SyncHeldPrompt(identity, path, source?.sourceAccount ?: sourceAccount, hash))
}

private fun dropping(scopes: Set<SyncScopeKey>, state: SyncState): SyncState {
    val prompts = state.prompts.filterValues { it.scope !in scopes }
    return state.copy(cursors = state.cursors - scopes, groups = state.groups.filterKeys { SyncScopeKey.Group(it) !in scopes },
        prompts = prompts, favorites = state.favorites.filterKeys { it in prompts })
}

private fun removalPlan(state: SyncState?, result: RescueResult, ownership: SyncLibraryBinding?, folders: Set<String>,
                        inventory: SyncGroupFolderInventory): SyncApplyPlan {
    val paths = inventory.directories.keys.filter { path ->
        folders.any { folder ->
            // A stray GROUPS root must never retire canonical Groups or its children.
            path.substringBefore('/') == folder.substringBefore('/') &&
                (SyncNaming.pathKey(path) == SyncNaming.pathKey(folder) || SyncGroupFolders.contains(path, folder))
        }
    }.sortedWith { left, right ->
        val byLength = right.encodeToByteArray().size.compareTo(left.encodeToByteArray().size)
        if (byLength == 0) comparePaths(right, left) else byLength
    }
    val directories = paths.map { SyncDirectoryEdit(SyncDirectoryEdit.Kind.REMOVE_EMPTY, it, inventory.directories.getValue(it))
        .also { edit -> edit.validate() } }
    return SyncApplyPlan(state, result.state, result.edits, directories,
        if (result.ownership == ownership) null else SyncBindingChange(ownership, result.ownership))
}

private fun isGroupsPath(path: String): Boolean = SyncNaming.pathKey(path.substringBefore('/')) == "groups"
