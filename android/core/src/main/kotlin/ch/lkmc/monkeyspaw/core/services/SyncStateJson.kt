package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*

internal typealias SyncObject = WireValue.ObjectValue

/** Storage codecs accept supported unknown members; wire DTOs retain their closed shapes. */
internal class SyncDocumentCodec<T>(val version: Int, val decode: (SyncObject) -> T, val encode: (T) -> SyncObject)

internal object SyncStateJson {
    val codec = SyncDocumentCodec(Limits.syncStateVersion, ::decode, ::encode)

    private fun decode(value: SyncObject): SyncState {
        val o = WireObject(value)
        SyncIdentifiers.version(o.long("version"), Limits.syncStateVersion)
        val binding = SyncLibraryIdentity(SyncAccountIdentity(o.string("server_url"), SyncIdentifiers.ulid(o.string("user_id"))),
            SyncLibraryRoot(o.string("library_root")))
        return SyncState(binding, value.optional("database_id")?.stringValue()?.let(SyncIdentifiers::uuid),
            value.map("cursors") { key, item -> SyncScopeKey.parse(key) to item.stringValue() },
            value.map("groups") { key, item ->
                val group = WireObject(item)
                SyncIdentifiers.ulid(key) to SyncGroupState(group.string("name"), group.string("folder"), group.dto("role", Role.codec))
            },
            value.map("prompts") { key, item -> SyncIdentifiers.promptIdentity(key) to prompt(item.objectValue()) },
            value.map("favorites") { key, item ->
                SyncIdentifiers.promptIdentity(key) to ((item as? WireValue.BooleanValue)?.value ?: throw SyncError.InvalidState)
            })
    }

    private fun encode(state: SyncState): SyncObject {
        state.validate()
        return syncObject("version" to wireLong(state.version.toLong()),
            "server_url" to wireString(state.binding.account.serverURL), "user_id" to wireString(state.binding.account.userID.rawValue),
            "library_root" to wireString(state.binding.root.path), "database_id" to wireNullable(state.databaseID?.toString()),
            "cursors" to SyncObject(state.cursors.map { it.key.rawValue to wireString(it.value) }.toMap()),
            "groups" to SyncObject(state.groups.map { (id, group) ->
                id.rawValue to syncObject("name" to wireString(group.name), "folder" to wireString(group.folder),
                    "role" to wireString(group.role.wireValue))
            }.toMap()),
            "prompts" to SyncObject(state.prompts.map { it.key.storageKey to prompt(it.value) }.toMap()),
            "favorites" to SyncObject(state.favorites.map { it.key.storageKey to wireBoolean(it.value) }.toMap()))
    }

    private fun prompt(value: SyncObject): SyncPromptState {
        val o = WireObject(value)
        return SyncPromptState(SyncScopeKey.parse(o.string("scope_key")), o.string("path"), o.long("rev"),
            value.optional("canonical_hash")?.stringValue()?.let(::SyncHash),
            value.optional("origin")?.objectValue()?.let(::origin),
            value.optional("last_error")?.objectValue()?.let { error ->
                val fields = WireObject(error)
                SyncPromptError(SyncIssueCode.parse(fields.string("code")), fingerprint(error.required("fingerprint").objectValue()))
            })
    }

    private fun prompt(value: SyncPromptState): SyncObject = syncObject(
        "scope_key" to wireString(value.scope.rawValue), "path" to wireString(value.path), "rev" to wireLong(value.rev),
        "canonical_hash" to wireNullable(value.canonicalHash?.rawValue),
        "origin" to (value.origin?.let(::origin) ?: WireValue.Null),
        "last_error" to (value.lastError?.let {
            syncObject("code" to wireString(it.code.rawValue), "fingerprint" to fingerprint(it.fingerprint))
        } ?: WireValue.Null))

    fun origin(value: SyncPromptOrigin): SyncObject = when (value) {
        SyncPromptOrigin.Rescued -> syncObject("kind" to wireString("rescued"))
        is SyncPromptOrigin.ConflictOf -> syncObject("kind" to wireString("conflict_of"), "prompt_id" to wireString(value.promptID.rawValue))
    }

    fun origin(value: SyncObject): SyncPromptOrigin = when (WireObject(value).string("kind")) {
        "conflict_of" -> SyncPromptOrigin.ConflictOf(SyncIdentifiers.ulid(WireObject(value).string("prompt_id")))
        "rescued" -> {
            if ("prompt_id" in value.fields) throw SyncError.InvalidState
            SyncPromptOrigin.Rescued
        }
        else -> throw SyncError.InvalidState
    }

    private fun fingerprint(value: SyncObject): SyncInputFingerprint {
        val o = WireObject(value)
        return SyncInputFingerprint(SyncHash(o.string("content_hash")), SyncHash(o.string("path_hash")),
            SyncScopeKey.parse(o.string("scope_key")), o.long("access_generation"),
            SyncOperation.entries.firstOrNull { it.rawValue == o.string("operation") } ?: throw SyncError.InvalidState)
    }

    private fun fingerprint(value: SyncInputFingerprint): SyncObject = syncObject(
        "content_hash" to wireString(value.contentHash.rawValue), "path_hash" to wireString(value.pathHash.rawValue),
        "scope_key" to wireString(value.scope.rawValue), "access_generation" to wireLong(value.accessGeneration),
        "operation" to wireString(value.operation.rawValue))
}

internal object SyncAccountJson {
    fun identity(value: SyncObject): SyncAccountIdentity = WireObject(value).let {
        SyncAccountIdentity(it.string("server_url"), SyncIdentifiers.ulid(it.string("user_id")))
    }

    fun identity(value: SyncAccountIdentity): SyncObject = syncObject(
        "server_url" to wireString(value.serverURL), "user_id" to wireString(value.userID.rawValue))

    fun account(value: SyncObject): SyncAccount = WireObject(value).let {
        SyncAccount(identity(value), it.string("username"), SyncIdentifiers.ulid(it.string("device_id")),
            it.string("device_name"), SyncIdentifiers.uuid(it.string("connection_id")))
    }

    fun account(value: SyncAccount): SyncObject = SyncObject(identity(value.identity).fields + mapOf(
        "username" to wireString(value.username), "device_id" to wireString(value.deviceID.rawValue),
        "device_name" to wireString(value.deviceName), "connection_id" to wireString(value.connectionID.toString())))

    fun binding(value: SyncObject): SyncLibraryBinding = WireObject(value).let { o ->
        SyncLibraryBinding(SyncLibraryRoot(o.string("library_root")), identity(value.required("owner").objectValue()),
            value.map("managed_folders") { key, item ->
                val folder = item.objectValue()
                SyncIdentifiers.ulid(key) to SyncManagedFolder(identity(folder.required("owner").objectValue()), WireObject(folder).string("folder"))
            }, value.required("holds").arrayValue().map { item ->
                val hold = item.objectValue()
                val h = WireObject(hold)
                SyncHeldPrompt(SyncIdentifiers.promptIdentity(h.string("identity")), h.string("path"),
                    identity(hold.required("source_account").objectValue()), SyncHash(h.string("content_hash")))
            })
    }

    fun binding(value: SyncLibraryBinding): SyncObject {
        value.validate()
        return syncObject("library_root" to wireString(value.root.path), "owner" to identity(value.owner),
            "managed_folders" to SyncObject(value.managedFolders.map { (id, folder) ->
                id.rawValue to syncObject("owner" to identity(folder.owner), "folder" to wireString(folder.folder))
            }.toMap()),
            "holds" to WireValue.ArrayValue(value.holds.map { hold ->
                syncObject("identity" to wireString(hold.identity.storageKey), "path" to wireString(hold.path),
                    "source_account" to identity(hold.sourceAccount), "content_hash" to wireString(hold.contentHash.rawValue))
            }))
    }
}

internal fun syncObject(vararg fields: Pair<String, WireValue>): SyncObject = SyncObject(mapOf(*fields))
internal fun WireValue.objectValue(): SyncObject = this as? SyncObject ?: throw SyncError.InvalidState
internal fun WireValue.arrayValue(): List<WireValue> = (this as? WireValue.ArrayValue)?.values ?: throw SyncError.InvalidState
internal fun SyncObject.required(key: String): WireValue = fields[key] ?: throw SyncError.InvalidState
internal fun SyncObject.optional(key: String): WireValue? = fields[key]?.takeUnless { it == WireValue.Null }
internal fun <K, V> SyncObject.map(key: String, transform: (String, WireValue) -> Pair<K, V>): Map<K, V> =
    required(key).objectValue().fields.map { (name, item) -> transform(name, item) }.toMap()
