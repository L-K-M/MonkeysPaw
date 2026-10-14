package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.services.*
import java.util.UUID

/** Renames retain a stable incarnation and the entire unknown subtree. */
internal class SyncDirectoryEdit(
    val kind: Kind,
    val source: String,
    val identity: FileStamp? = null,
    val destination: String? = null,
    val intermediate: String? = null,
    localFiles: List<SyncLibraryFile> = emptyList(),
    val id: UUID = UUID.randomUUID(),
) {
    enum class Kind(val rawValue: String) { RESERVE("reserve"), RENAME("rename"), REMOVE_EMPTY("removeEmpty") }
    val localFiles = localFiles.syncListCopy()

    fun validate() {
        StorePath.validate(source)
        identity?.journalToken()
        val parts = source.split('/')
        if (syncPathKey(parts[0]) != "groups") throw SyncError.InvalidState
        if (kind == Kind.RESERVE) {
            if (parts.size != 2 || !source.startsWith("Groups/") || identity != null || destination != null ||
                intermediate != null || localFiles.isNotEmpty()) throw SyncError.InvalidState
            SyncIdentifiers.folder(parts[1])
            return
        }
        if (identity == null) throw SyncError.InvalidState
        if (kind == Kind.REMOVE_EMPTY) {
            if (destination != null || intermediate != null || localFiles.isNotEmpty() || source == "Groups") throw SyncError.InvalidState
            return
        }
        val destination = destination ?: throw SyncError.InvalidState
        StorePath.validate(destination)
        if (source == destination || parts.size != 2 || !source.startsWith("Groups/") ||
            !destination.startsWith("Groups/") || destination.split('/').size != 2) throw SyncError.InvalidState
        SyncIdentifiers.folder(destination.removePrefix("Groups/"))
        if (intermediate != null) {
            StorePath.validate(intermediate)
            if (!intermediate.startsWith("Groups/_sync-") || intermediate.split('/').size != 2 ||
                syncPathKey(intermediate) in setOf(syncPathKey(source), syncPathKey(destination))) throw SyncError.InvalidState
        } else if (syncPathKey(source) == syncPathKey(destination)) throw SyncError.InvalidState
        if (localFiles.map { it.path }.toSet().size != localFiles.size) throw SyncError.InvalidState
        localFiles.forEach {
            it.validate()
            if (it.identity !is PromptIdentity.Local || !it.path.startsWith("$source/")) throw SyncError.InvalidState
            StorePath.validate(relocatedPath(it))
        }
    }

    fun relocatedPath(file: SyncLibraryFile): String = (destination ?: source) + file.path.removePrefix(source)
    fun identityTransitions(): List<SyncIdentityTransition> = localFiles.map {
        SyncIdentityTransition(it.identity, PromptIdentity.at(relocatedPath(it)))
    }
    override fun toString(): String = "<sync directory edit>"
}

internal class SyncDirectoryStep(
    val edit: SyncDirectoryEdit,
    migrations: List<SyncKeyedMigration> = emptyList(),
    val started: Boolean = false,
    val completed: Boolean = false,
) {
    val migrations = migrations.syncListCopy()
    fun progress(started: Boolean = this.started, completed: Boolean = this.completed) =
        SyncDirectoryStep(edit, migrations, started, completed)
    override fun toString(): String = "<sync directory step>"
}

internal fun syncPathKey(path: String): String = UnicodeText.nfc(SyncPathCaseFold.fold(UnicodeText.nfc(path)))
