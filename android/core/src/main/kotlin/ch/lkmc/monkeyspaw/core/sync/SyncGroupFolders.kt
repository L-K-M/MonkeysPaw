package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.GroupMembership
import ch.lkmc.monkeyspaw.core.syncapi.Role
import java.util.UUID

internal sealed class SyncGroupFolderError private constructor() : Exception("Sync folder planning failed.", null, false, true) {
    class ReservedFolders(paths: List<String>) : SyncGroupFolderError() { val paths = paths.syncListCopy() }
    data object InvalidInventory : SyncGroupFolderError()
    data object RescueRequired : SyncGroupFolderError()
    data object AccessibleInstallationRequired : SyncGroupFolderError()
    final override fun toString(): String = "<sync folder error>"
}

/** Full rooted tree, including empty and hidden directories. */
internal class SyncGroupFolderInventory(val local: SyncReconciliationSnapshot, directories: Map<String, FileStamp>) {
    val directories = directories.syncMapCopy()
    override fun toString(): String = "<sync folder inventory>"
}

/** Preparations keep old UUID/cursors; cleanup may drop/reset cursors before recollection. */
internal object SyncGroupFolders {
    fun inventory(binding: SyncLibraryIdentity, availability: SyncReconciliationSnapshot.Availability,
                  heldPaths: Set<String> = emptySet(), mutations: SyncLibraryMutations): SyncGroupFolderInventory {
        if (availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        return SyncGroupFolderInventory(SyncReconciliationSnapshot(binding, mutations.listedFiles(), heldPaths = heldPaths),
            mutations.directoryIdentities())
    }

    /** Retained ownership reserves the roots across sign-out; children have separate ownership. */
    fun preflight(inventory: SyncGroupFolderInventory, ownership: SyncLibraryBinding?) {
        validate(inventory, null, ownership)
        if (ownership != null) return
        val occupied = (inventory.local.files.map { it.path } + inventory.directories.keys).filter {
            '/' !in it && SyncNaming.pathKey(it) in setOf("groups", "conflicts")
        }.sortedWith(::comparePaths)
        if (occupied.isNotEmpty()) throw SyncGroupFolderError.ReservedFolders(occupied)
    }

    fun update(memberships: List<GroupMembership>, state: SyncState?, ownership: SyncLibraryBinding?,
               inventory: SyncGroupFolderInventory, mutations: SyncLibraryMutations): SyncApplyPlan {
        validate(inventory, state, ownership)
        val binding = inventory.local.binding
        if (ownership != null && ownership.owner != binding.account) throw SyncError.BindingMismatch
        if (state == null) preflight(inventory, ownership)
        val old = state ?: SyncState(binding)
        var next = old
        var owned = ownership ?: SyncLibraryBinding(binding.root, binding.account)
        val directories = mutableListOf<SyncDirectoryEdit>()
        val edits = mutableListOf<SyncLibraryEdit>()
        val seen = mutableSetOf<ULID>()
        val occupied = (inventory.directories.keys + inventory.local.files.map { it.path } +
            old.groups.values.map { "Groups/" + it.folder } + owned.managedFolders.values.map { "Groups/" + it.folder }).toMutableList()

        for (membership in memberships.sortedBy { it.groupID }) {
            val id = SyncIdentifiers.ulid(membership.groupID)
            if (!seen.add(id)) throw SyncError.InvalidState
            val previous = old.groups[id]
            val retained = owned.managedFolders[id]
            if (retained != null && retained.owner != binding.account ||
                previous != null && retained != null && previous.folder != retained.folder) throw SyncGroupFolderError.RescueRequired
            val priorFolder = previous?.folder ?: retained?.folder
            val canonicalSource = priorFolder?.let { "Groups/$it" }
            val existing = canonicalSource?.let { source ->
                val key = SyncNaming.pathKey(source)
                val matches = inventory.directories.filterKeys { SyncNaming.pathKey(it) == key }
                if (matches.size > 1) throw SyncGroupFolderError.InvalidInventory
                matches.entries.singleOrNull()
            }
            // Persist the allocation, but mutate the actual disk spelling.
            val source = existing?.key ?: canonicalSource
            if (source != null && inventory.local.files.any { SyncNaming.pathKey(it.path) == SyncNaming.pathKey(source) }) {
                throw SyncGroupFolderError.RescueRequired
            }
            val folder = if (priorFolder != null && (previous == null || previous.name == membership.name)) priorFolder
                else SyncNaming.groupFolder(membership.name, occupied.filter {
                    source == null || SyncNaming.pathKey(it) != SyncNaming.pathKey(source)
                }.mapNotNull(::childFolder))
            val group = SyncGroupState(membership.name, folder, membership.role)
            val destination = "Groups/$folder"
            StorePath.validate(destination)
            if (source != null && source != destination && existing != null) {
                val intermediate = if (SyncNaming.pathKey(source) == SyncNaming.pathKey(destination)) {
                    ("Groups/_sync-" + UUID.randomUUID()).also { candidate ->
                        if (occupied.any { SyncNaming.pathKey(it) == SyncNaming.pathKey(candidate) }) throw SyncGroupFolderError.InvalidInventory
                    }
                } else null
                occupied.filter { contains(it, source) }.forEach { path ->
                    StorePath.validate(relocated(path, source, destination))
                    if (intermediate != null) StorePath.validate(relocated(path, source, intermediate))
                }
                val localFiles = inventory.local.files.filter { contains(it.path, source) && it.identity is PromptIdentity.Local }
                val rename = SyncDirectoryEdit(SyncDirectoryEdit.Kind.RENAME, source, existing.value, destination, intermediate, localFiles)
                    .also { it.validate() }
                directories.add(rename)
                rename.identityTransitions().forEach {
                    next = SyncLocalScanner.migrating(next, SyncIdentifiers.promptIdentity(it.source ?: throw SyncError.InvalidState),
                        SyncIdentifiers.promptIdentity(it.destination))
                }
                owned = owned.copy(holds = owned.holds.map { hold ->
                    if (!contains(hold.path, source)) hold else {
                        val path = relocated(hold.path, source, destination)
                        hold.copy(path = path, identity = if (hold.identity is PromptIdentity.Local) PromptIdentity.at(path) else hold.identity)
                    }
                })
            } else if (priorFolder == null || source != destination) {
                directories.add(SyncDirectoryEdit(SyncDirectoryEdit.Kind.RESERVE, destination).also { it.validate() })
            }
            if (source != null && (previous?.role != membership.role || membership.role == Role.VIEWER)) {
                inventory.local.files.filter { contains(it.path, source) }.forEach { file ->
                    val moved = SyncLibraryFile(relocated(file.path, source, destination), file.stamp, file.bytes)
                    edits.add(mutations.mode(if (membership.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL, moved))
                }
            }
            next = next.copy(groups = next.groups + (id to group))
            owned = owned.copy(managedFolders = owned.managedFolders + (id to SyncManagedFolder(binding.account, folder)))
            occupied.add(destination)
            // A checked first file publication materializes an empty new allocation.
        }
        return SyncApplyPlan(state, next, edits, directories, if (owned == ownership) null else SyncBindingChange(ownership, owned))
    }

    fun mode(scope: SyncScopeKey, groups: Map<ULID, SyncGroupState>): SyncFileMode {
        if (scope !is SyncScopeKey.Group) return SyncFileMode.NORMAL
        val group = groups[scope.id] ?: throw SyncError.InvalidScope
        return if (group.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL
    }

    fun validate(inventory: SyncGroupFolderInventory, state: SyncState?, ownership: SyncLibraryBinding?) {
        if (inventory.local.availability != SyncReconciliationSnapshot.Availability.AVAILABLE) throw SyncReconciliationError.UnavailableLibrary
        if (state != null && state.binding != inventory.local.binding ||
            ownership != null && ownership.root != inventory.local.binding.root) throw SyncError.BindingMismatch
        state?.validate()
        ownership?.validate()
        if (inventory.local.files.map { it.path }.toSet().size != inventory.local.files.size) throw SyncGroupFolderError.InvalidInventory
        inventory.local.files.forEach { it.validate() }
        inventory.directories.keys.forEach(StorePath::validate)
    }

    fun contains(path: String, directory: String): Boolean = SyncNaming.pathKey(path).startsWith(SyncNaming.pathKey(directory) + "/")

    fun relocated(path: String, source: String, destination: String): String =
        destination + "/" + path.split('/').drop(source.split('/').size).joinToString("/")

    private fun childFolder(path: String): String? {
        val parts = path.split('/')
        return if (parts.size == 2 && SyncNaming.pathKey(parts[0]) == "groups") parts[1] else null
    }
}

internal fun comparePaths(left: String, right: String): Int =
    ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order.compare(left.encodeToByteArray(), right.encodeToByteArray())
