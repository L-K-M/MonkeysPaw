package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.UUID

internal enum class SyncAccountActivation(val rawValue: String) { INACTIVE("inactive"), ENABLED("enabled") }

/** The final Swift version-1 extension keeps cleanup references with account publication. */
internal class SyncConnectionDocument(
    val account: SyncAccount?,
    activation: SyncAccountActivation = SyncAccountActivation.ENABLED,
    cleanupConnections: List<UUID> = emptyList(),
) {
    val activation = if (account == null) SyncAccountActivation.INACTIVE else activation
    val cleanupConnections = cleanupConnections.syncListCopy()

    init {
        if (cleanupConnections.toSet().size != cleanupConnections.size ||
            this.activation == SyncAccountActivation.ENABLED && account?.connectionID in cleanupConnections) throw SyncError.InvalidState
    }

    override fun equals(other: Any?): Boolean = other is SyncConnectionDocument && account == other.account &&
        activation == other.activation && cleanupConnections == other.cleanupConnections
    override fun hashCode(): Int = listOf(account, activation, cleanupConnections).hashCode()
    override fun toString(): String = "<sync connection metadata>"
}

/** Connection and ownership writes are independent, never a cross-document transaction.
 * Share one graph; account transition services own journal preparation and secret compensation.
 */
class SyncAccountStore(files: StateStore, operations: SyncFileFlushing) {
    private val connection = SyncPersistence(files, operations, "sync/account.json", connectionCodec)
    private val ownership = SyncPersistence(files, operations, "sync/binding.json", bindingCodec)

    /** Cached diagnostics can be stale. Load and check errors before any sync decision. */
    internal val cachedAccount: SyncAccount? get() = connection.snapshot.value?.account
    internal val cachedBindings: List<SyncLibraryBinding> get() = ownership.snapshot.value.orEmpty()
    internal val readOnlyError: SyncError? get() = connection.snapshot.error ?: ownership.snapshot.error

    internal fun loadAccount(): SyncAccount? = loadConnection().account

    internal fun loadConnection(): SyncConnectionDocument {
        ownership.load()
        return connection.load() ?: SyncConnectionDocument(null)
    }

    internal fun recoverConnection(): SyncConnectionDocument {
        ownership.recover()
        return connection.recover() ?: SyncConnectionDocument(null)
    }

    /** Corrupt ownership must not hide the secret reference needed for explicit sign-out. */
    internal fun connectionForSignOut(): SyncConnectionDocument = connection.load() ?: SyncConnectionDocument(null)

    internal fun setAccount(account: SyncAccount?, activation: SyncAccountActivation = SyncAccountActivation.ENABLED,
                            retiring: List<UUID> = emptyList()) {
        ownership.load()
        connection.update { current ->
            SyncConnectionDocument(account, activation, cleanupIDs(current?.cleanupConnections.orEmpty() + retiring))
        }
    }

    internal fun disableAutomaticResume() = connection.update { current ->
        SyncConnectionDocument(current?.account, SyncAccountActivation.INACTIVE, current?.cleanupConnections.orEmpty())
    }

    internal fun saveInactive(account: SyncAccount?, retiring: List<UUID>) {
        val cached = connection.snapshot.value
        connection.recover()
        connection.update { current ->
            SyncConnectionDocument(account, SyncAccountActivation.INACTIVE,
                cleanupIDs((current?.cleanupConnections ?: cached?.cleanupConnections).orEmpty() + retiring))
        }
    }

    internal fun finishSecretCleanup(id: UUID) = connection.update { current ->
        SyncConnectionDocument(current?.account, current?.activation ?: SyncAccountActivation.INACTIVE,
            current?.cleanupConnections.orEmpty() - id)
    }

    /** Ownership reads ignore connection health; account reads/edits and ownership edits require both. */
    internal fun binding(root: SyncLibraryRoot): SyncLibraryBinding? = ownership.load()?.firstOrNull { it.root == root }

    internal fun updateBinding(root: SyncLibraryRoot, change: (SyncLibraryBinding?) -> SyncLibraryBinding) {
        connection.load()
        ownership.update { current ->
            val libraries = current.orEmpty().toMutableList()
            val index = libraries.indexOfFirst { it.root == root }
            val next = change(libraries.getOrNull(index))
            if (next.root != root) throw SyncError.BindingMismatch
            if (index >= 0) libraries[index] = next else libraries.add(next)
            libraries.syncListCopy()
        }
    }

    internal fun resetAccount() = connection.reset(SyncConnectionDocument(null))
    internal fun resetBindings() = ownership.reset(emptyList())

    private fun cleanupIDs(ids: List<UUID>): List<UUID> = ids.distinct().sortedBy { it.toString() }

    private companion object {
        val connectionCodec = SyncDocumentCodec(Limits.syncAccountVersion, { value ->
            val o = WireObject(value)
            SyncIdentifiers.version(o.long("version"), Limits.syncAccountVersion)
            val account = value.required("account").takeUnless { it == WireValue.Null }?.objectValue()?.let(SyncAccountJson::account)
            val activation = value.optional("activation")?.stringValue()?.let { raw ->
                SyncAccountActivation.entries.firstOrNull { it.rawValue == raw } ?: throw SyncError.InvalidState
            } ?: if (account == null) SyncAccountActivation.INACTIVE else SyncAccountActivation.ENABLED
            if (account == null && activation != SyncAccountActivation.INACTIVE) throw SyncError.InvalidState
            val cleanup = value.optional("cleanup_connections")?.arrayValue().orEmpty().map { SyncIdentifiers.uuid(it.stringValue()) }
            SyncConnectionDocument(account, activation, cleanup)
        }, { value: SyncConnectionDocument ->
            syncObject("version" to wireLong(Limits.syncAccountVersion.toLong()),
                "account" to (value.account?.let(SyncAccountJson::account) ?: WireValue.Null),
                "activation" to wireString(value.activation.rawValue),
                "cleanup_connections" to WireValue.ArrayValue(value.cleanupConnections.map { wireString(it.toString()) }))
        })

        val bindingCodec = SyncDocumentCodec(Limits.syncBindingVersion, { value ->
            SyncIdentifiers.version(WireObject(value).long("version"), Limits.syncBindingVersion)
            value.required("libraries").arrayValue().map { SyncAccountJson.binding(it.objectValue()) }.also { libraries ->
                if (libraries.map { it.root }.toSet().size != libraries.size) throw SyncError.InvalidState
            }.syncListCopy()
        }, { libraries: List<SyncLibraryBinding> ->
            if (libraries.map { it.root }.toSet().size != libraries.size) throw SyncError.InvalidState
            syncObject("version" to wireLong(Limits.syncBindingVersion.toLong()),
                "libraries" to WireValue.ArrayValue(libraries.map(SyncAccountJson::binding)))
        })
    }
}
