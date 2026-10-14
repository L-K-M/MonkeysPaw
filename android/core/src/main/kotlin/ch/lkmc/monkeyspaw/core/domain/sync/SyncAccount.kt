package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import ch.lkmc.monkeyspaw.core.ports.StorePath
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.syncapi.WireValidation
import java.net.URI
import java.util.UUID

/** Already normalized deployment base. This syntax check does not authorize HTTP. */
internal data class SyncAccountIdentity(val serverURL: String, val userID: ULID) {
    init {
        val valid = try {
            val url = URI(serverURL)
            // URI's DNS grammar omits Foundation-valid reg-names such as my_host.
            val host = url.host ?: url.rawAuthority.orEmpty().substringBefore(':').takeIf { name ->
                name.isNotEmpty() && name.all { it in "abcdefghijklmnopqrstuvwxyz0123456789-_." }
            }.orEmpty()
            val port = if (url.host != null || ':' !in url.rawAuthority.orEmpty()) url.port else {
                url.rawAuthority.substringAfter(':').toIntOrNull() ?: -2
            }
            val path = url.path.orEmpty()
            serverURL.isNotEmpty() && '\\' !in serverURL &&
                serverURL.none { it.isWhitespace() || Character.isSpaceChar(it) } &&
                url.scheme in setOf("https", "http") && host.isNotEmpty() &&
                host == host.lowercase(java.util.Locale.ROOT) && !host.endsWith('.') &&
                host.all { it.code < 128 } && '%' !in host &&
                url.rawUserInfo == null && url.rawQuery == null && url.rawFragment == null &&
                (port == -1 || port in 1..65535) && port != (if (url.scheme == "https") 443 else 80) &&
                url.rawAuthority == host + (if (port == -1) "" else ":$port") &&
                (path.isEmpty() || path.startsWith('/') && !path.endsWith('/')) &&
                '\\' !in path && "//" !in path && !path.codePoints().anyMatch(UnicodeText::isControlOrFormat) &&
                path.split('/').none { it == "." || it == ".." } &&
                !url.rawPath.orEmpty().contains("%2f", ignoreCase = true) && !path.endsWith("/api/v1") &&
                url.toASCIIString() == serverURL
        } catch (_: Exception) { false }
        if (!valid) throw SyncError.InvalidAccount
    }
}

/** Composition supplies an absolute lexical spelling, without any filesystem lookup. */
internal data class SyncLibraryRoot(val path: String) {
    init {
        val valid = try {
            path.encodeToByteArray(throwOnInvalidSequence = true)
            path.startsWith('/') && '\\' !in path && !path.codePoints().anyMatch(UnicodeText::isControlOrFormat) &&
                (path == "/" || path.drop(1).split('/').none { it.isEmpty() || it == "." || it == ".." })
        } catch (_: Exception) { false }
        if (!valid) throw SyncError.InvalidRoot
    }
}

internal data class SyncLibraryIdentity(val account: SyncAccountIdentity, val root: SyncLibraryRoot)

/** Only metadata: the server device ID is distinct from the local secret connection UUID. */
internal data class SyncAccount(
    val identity: SyncAccountIdentity,
    val username: String,
    val deviceID: ULID,
    val deviceName: String,
    val connectionID: UUID,
) {
    init { syncValidated { WireValidation.username(username); WireValidation.name(deviceName) } }
    val secretAccount: SecretAccount get() = SecretAccount.device(connectionID)
}

internal data class SyncManagedFolder(val owner: SyncAccountIdentity, val folder: String) {
    init { SyncIdentifiers.folder(folder) }
}

/** Edits never release a hold; transition/scanner code migrates its identity and path. */
internal data class SyncHeldPrompt(
    val identity: PromptIdentity,
    val path: String,
    val sourceAccount: SyncAccountIdentity,
    val contentHash: SyncHash,
) {
    init { syncValidated { identity.storageKey; StorePath.validate(path) } }
}

internal class SyncLibraryBinding(
    val root: SyncLibraryRoot,
    val owner: SyncAccountIdentity,
    managedFolders: Map<ULID, SyncManagedFolder> = emptyMap(),
    holds: List<SyncHeldPrompt> = emptyList(),
) {
    val managedFolders = managedFolders.syncMapCopy()
    val holds = holds.syncListCopy()

    init { validate() }

    fun isHeld(identity: PromptIdentity, path: String, contentHash: SyncHash): Boolean =
        holds.any { it.identity == identity || it.path == path || it.contentHash == contentHash }

    fun validate() {
        if (holds.map { it.path }.toSet().size != holds.size ||
            managedFolders.values.map { SyncPathCaseFold.fold(it.folder) }.toSet().size != managedFolders.size) {
            throw SyncError.InvalidState
        }
    }

    fun copy(root: SyncLibraryRoot = this.root, owner: SyncAccountIdentity = this.owner,
             managedFolders: Map<ULID, SyncManagedFolder> = this.managedFolders,
             holds: List<SyncHeldPrompt> = this.holds): SyncLibraryBinding = SyncLibraryBinding(root, owner, managedFolders, holds)

    override fun equals(other: Any?): Boolean = other is SyncLibraryBinding && root == other.root &&
        owner == other.owner && managedFolders == other.managedFolders && holds == other.holds
    override fun hashCode(): Int = listOf(root, owner, managedFolders, holds).hashCode()
    override fun toString(): String = "<sync library binding>"
}
