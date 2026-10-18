package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.syncapi.Role
import ch.lkmc.monkeyspaw.core.syncapi.WireValidation
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID

/** Full lowercase SHA-256 of exact canonical bytes, distinct from adoption equality. */
internal data class SyncHash(val rawValue: String) {
    init {
        if (rawValue.length != 64 || rawValue.any { it !in '0'..'9' && it !in 'a'..'f' }) throw SyncError.InvalidHash
    }

    companion object {
        fun of(bytes: ByteArray): SyncHash = SyncHash(MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) })
    }
}

internal sealed interface SyncScopeKey {
    val id: ULID
    data class User(override val id: ULID) : SyncScopeKey
    data class Group(override val id: ULID) : SyncScopeKey
    val rawValue: String get() = (if (this is User) "user:" else "group:") + id.rawValue
    val pathScope: SyncPathValidator.Scope get() =
        if (this is User) SyncPathValidator.Scope.USER else SyncPathValidator.Scope.GROUP

    companion object {
        fun parse(raw: String): SyncScopeKey {
            syncValidated { WireValidation.scopeKey(raw) }
            val id = SyncIdentifiers.ulid(raw.substringAfter(':'))
            return if (raw.startsWith("user:")) User(id) else Group(id)
        }
    }
}

sealed interface SyncPromptOrigin {
    data class ConflictOf(val promptID: ULID) : SyncPromptOrigin
    data object Rescued : SyncPromptOrigin
}

internal data class SyncGroupState(val name: String, val folder: String, val role: Role) {
    init {
        syncValidated { WireValidation.name(name) }
        SyncIdentifiers.folder(folder)
    }
}

/** Suppress an unchanged raw key after a newer personal favourite intent. Null means absent. */
internal data class SyncFavoriteInput(val value: Boolean?) {
    companion object {
        fun preferred(favorite: Boolean?, after: SyncFavoriteInput?): Boolean? =
            if (after != null && after.value == favorite) null else favorite
    }
}

internal data class SyncPromptState(
    val scope: SyncScopeKey,
    val path: String,
    val rev: Long,
    val canonicalHash: SyncHash? = null,
    val origin: SyncPromptOrigin? = null,
    val lastError: SyncPromptError? = null,
    val favoriteInput: SyncFavoriteInput? = null,
) {
    init {
        if (rev < 0 || (rev == 0L) != (canonicalHash == null) ||
            origin != null && scope !is SyncScopeKey.User ||
            favoriteInput != null && scope !is SyncScopeKey.Group) throw SyncError.InvalidState
        syncValidated {
            if (rev == 0L) StorePath.validate(path)
            else if (SyncPathValidator.validate(path, scope.pathScope).path != path) throw SyncError.InvalidState
        }
    }
}

/** Immutable snapshots own their maps; an edit returns a newly validated value. */
internal class SyncState(
    val binding: SyncLibraryIdentity,
    val databaseID: UUID? = null,
    cursors: Map<SyncScopeKey, String> = emptyMap(),
    groups: Map<ULID, SyncGroupState> = emptyMap(),
    prompts: Map<PromptIdentity, SyncPromptState> = emptyMap(),
    favorites: Map<PromptIdentity, Boolean> = emptyMap(),
) {
    val cursors = cursors.syncMapCopy()
    val groups = groups.syncMapCopy()
    val prompts = prompts.syncMapCopy()
    val favorites = favorites.syncMapCopy()
    val version: Int get() = Limits.syncStateVersion

    init { validate() }

    fun applyGroupFavorite(favorite: Boolean?, id: PromptIdentity): SyncState {
        if (favorite == null) return this
        if (prompts[id]?.scope !is SyncScopeKey.Group) throw SyncError.InvalidState
        return copy(favorites = if (favorite) favorites + (id to true) else favorites - id)
    }

    fun validate() {
        fun check(scope: SyncScopeKey) {
            when (scope) {
                is SyncScopeKey.User -> if (scope.id != binding.account.userID) throw SyncError.InvalidScope
                is SyncScopeKey.Group -> if (scope.id !in groups) throw SyncError.InvalidScope
            }
        }
        cursors.forEach { (scope, cursor) ->
            check(scope)
            syncValidated { WireValidation.nonempty(cursor) }
        }
        if (groups.values.map { SyncPathCaseFold.fold(it.folder) }.toSet().size != groups.size) throw SyncError.InvalidState
        prompts.forEach { (identity, prompt) ->
            syncValidated { identity.storageKey }
            if (identity is PromptIdentity.Local && prompt.rev != 0L) throw SyncError.InvalidState
            check(prompt.scope)
            val errorScope = prompt.lastError?.fingerprint?.scope
            if (errorScope is SyncScopeKey.User && errorScope.id != binding.account.userID) throw SyncError.InvalidScope
        }
        favorites.forEach { (id, favorite) ->
            if (!favorite || prompts[id]?.scope !is SyncScopeKey.Group) throw SyncError.InvalidState
        }
    }

    fun copy(
        binding: SyncLibraryIdentity = this.binding, databaseID: UUID? = this.databaseID,
        cursors: Map<SyncScopeKey, String> = this.cursors, groups: Map<ULID, SyncGroupState> = this.groups,
        prompts: Map<PromptIdentity, SyncPromptState> = this.prompts, favorites: Map<PromptIdentity, Boolean> = this.favorites,
    ): SyncState = SyncState(binding, databaseID, cursors, groups, prompts, favorites)

    override fun equals(other: Any?): Boolean = other is SyncState && binding == other.binding &&
        databaseID == other.databaseID && cursors == other.cursors && groups == other.groups &&
        prompts == other.prompts && favorites == other.favorites
    override fun hashCode(): Int = listOf(binding, databaseID, cursors, groups, prompts, favorites).hashCode()
    override fun toString(): String = "<sync state>"

    companion object { const val snapshotResetCursor = "0" }
}

internal object SyncIdentifiers {
    fun ulid(raw: String): ULID = ULID.parse(raw)?.takeIf { it.rawValue == raw } ?: throw SyncError.InvalidState

    fun uuid(raw: String): UUID = syncValidated {
        UUID.fromString(raw).also { if (it.toString() != raw) throw SyncError.InvalidState }
    }

    fun promptIdentity(raw: String): PromptIdentity =
        if (raw.length == 64) PromptIdentity.Local(SyncHash(raw).rawValue) else PromptIdentity.Assigned(ulid(raw))

    fun version(version: Long, current: Int) {
        if (version > current) throw SyncError.FutureVersion(version)
        if (version != current.toLong()) throw SyncError.UnsupportedVersion(version)
    }

    fun folder(folder: String) = syncValidated {
        if ('/' in folder || folder.startsWith('.') || folder.startsWith('_') ||
            SyncPathValidator.validate("$folder/check.md", SyncPathValidator.Scope.GROUP).path != "$folder/check.md") {
            throw SyncError.InvalidState
        }
    }
}

internal fun <K, V> Map<K, V>.syncMapCopy(): Map<K, V> = Collections.unmodifiableMap(LinkedHashMap(this))
internal fun <T> List<T>.syncListCopy(): List<T> = Collections.unmodifiableList(ArrayList(this))
