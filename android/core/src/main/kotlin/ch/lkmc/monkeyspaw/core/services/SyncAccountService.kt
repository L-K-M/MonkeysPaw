package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal enum class SyncAccountIntent { LOGIN, STARTUP }
internal enum class SyncRemoteRevocation { NOT_NEEDED, REVOKED, UNCONFIRMED }

internal sealed interface SyncAccountIssue {
    data object Busy : SyncAccountIssue
    data object SignedOut : SyncAccountIssue
    data object CredentialsRequired : SyncAccountIssue
    data object InvalidInput : SyncAccountIssue
    data object TokenBindingMismatch : SyncAccountIssue
    data object InvalidAccount : SyncAccountIssue
    data object RecoveryRequired : SyncAccountIssue
    class ReservedFolders(paths: List<String>) : SyncAccountIssue { val paths = paths.syncListCopy() }
    data class Secret(val error: SecretStoreError) : SyncAccountIssue
    data class Metadata(val error: SyncError) : SyncAccountIssue
    data class Http(val error: SyncHTTPClientError) : SyncAccountIssue
}

/** Only fixed failures and non-secret references survive incomplete compensation. */
internal data class SyncAccountCleanup(
    val remote: SyncRemoteRevocation = SyncRemoteRevocation.NOT_NEEDED,
    val secretFailures: List<UUID> = emptyList(),
    val secretIssue: SecretStoreError? = null,
    val metadataIssue: SyncError? = null,
    val recoveryRequired: Boolean = false,
) {
    val isComplete: Boolean get() = remote != SyncRemoteRevocation.UNCONFIRMED && secretFailures.isEmpty() &&
        metadataIssue == null && !recoveryRequired
    override fun toString(): String = "<sync account cleanup redacted>"
}

internal class SyncAccountServiceError(
    val issue: SyncAccountIssue,
    val cleanup: SyncAccountCleanup = SyncAccountCleanup(),
    val registrationCommitted: Boolean = false,
) : Exception("Sync account operation failed.", null, false, true) {
    override fun toString(): String = "<sync account error redacted>"
}

internal data class SyncAccountSnapshot(
    val account: SyncAccount? = null, val me: MeResponse? = null, val tier: SecretTier? = null,
    val enabled: Boolean = false, val cleanup: SyncAccountCleanup = SyncAccountCleanup(),
) {
    override fun toString(): String = "<sync account snapshot redacted>"
}

/** One admitted operation owns compensation. Composition must share this engine's account store. */
class SyncAccountService internal constructor(
    private val sync: SyncEngine, private val accounts: SyncAccountStore,
    private val secrets: SecretStore, private val transport: HttpTransport,
    private val root: SyncLibraryRoot, private val io: CoroutineDispatcher,
    private val clock: MonotonicClock, private val connectionID: () -> UUID,
) {
    constructor(sync: SyncEngine, accounts: SyncAccountStore, secrets: SecretStore, transport: HttpTransport,
                libraryRoot: String, io: CoroutineDispatcher = Dispatchers.IO,
                monotonicClock: MonotonicClock = MonotonicClock(System::nanoTime)) :
        this(sync, accounts, secrets, transport, SyncLibraryRoot(libraryRoot), io, monotonicClock, UUID::randomUUID)

    private class Session(val account: SyncAccount, val client: SyncHTTPClient, val tier: SecretTier)
    private enum class AuthenticationKind { LOGIN, REGISTER }
    private val lock = ReentrantLock()
    private var busy = false
    private var active: Session? = null
    private val cached = MutableStateFlow(SyncAccountSnapshot())
    internal val snapshots = cached.asStateFlow()
    internal val snapshot: SyncAccountSnapshot get() = cached.value
    internal val isBusy: Boolean get() = lock.withLock { busy }

    init { if (sync.graph.accounts !== accounts) throw SyncError.InvalidAccount }
    override fun toString(): String = "<sync account service redacted>"

    /** Passwords/invites are transient SecretValues; presentation clears its drafts before awaiting. */
    internal suspend fun login(server: String, username: String, password: SecretValue, deviceName: String): SyncAccountSnapshot =
        authenticate(server, AuthenticationKind.LOGIN) { client ->
            client.login(password.withValue { LoginRequest(username, it, deviceName) })
        }

    internal suspend fun register(invite: InviteLink, expectedAccount: SyncAccount?, username: String, password: SecretValue,
                                  deviceName: String): SyncAccountSnapshot = authenticate(invite.server.baseURL, AuthenticationKind.REGISTER, { previous ->
        if (previous.account != expectedAccount || snapshot.account != expectedAccount) throw InviteAcceptanceIssue.AccountChanged
    }) { client ->
        client.register(invite.token.withValue { token -> password.withValue { RegisterRequest(token, username, it, deviceName) } })
    }

    private suspend fun authenticate(input: String, kind: AuthenticationKind,
                                     checkAccount: (SyncConnectionDocument) -> Unit = {},
                                     authenticate: suspend (SyncHTTPClient) -> SyncAuthentication): SyncAccountSnapshot = withContext(io) {
        enter()
        try {
            val previous: SyncConnectionDocument
            val server: SyncServerURL
            val authentication: SyncAuthentication
            try {
                previous = accounts.recoverConnection()
                server = SyncServerURL(input)
                checkAccount(previous)
                authentication = authenticate(SyncHTTPClient(server, transport, clock = clock))
            } catch (error: InviteAcceptanceIssue) { throw error }
            catch (error: Throwable) { throwFailure(error) }
            val client = SyncHTTPClient(server, transport, authentication.credential, clock)
            var candidate: SyncAccount? = null
            var staged = false
            var secretAttempted = false
            try {
                val me = client.me()
                val current = validate(me, SyncIdentifiers.ulid(authentication.user.id))
                val id = connectionID()
                if (id == previous.account?.connectionID || id in previous.cleanupConnections) throw SyncAccountServiceError(SyncAccountIssue.InvalidInput)
                val account = SyncAccount(SyncAccountIdentity(server.baseURL, SyncIdentifiers.ulid(me.user.id)),
                    me.user.username, SyncIdentifiers.ulid(current.id), current.name, id)
                candidate = account
                if (readSecret(account.secretAccount, SecretReadSource.EFFECTIVE) != null ||
                    readSecret(account.secretAccount, SecretReadSource.PERSISTED) != null) {
                    throw SyncAccountServiceError(SyncAccountIssue.Secret(SecretStoreError.ReadOnly))
                }
                sync.stop()
                sync.drain()
                staged = true
                accounts.disableAutomaticResume()
                secretAttempted = true
                // Mutations finish before compensation; a late write must never recreate a deleted token.
                val tier = withContext(NonCancellable) { writeSecret(bind(authentication.credential, account), account.secretAccount) }
                currentCoroutineContext().ensureActive()
                accounts.setAccount(account, SyncAccountActivation.INACTIVE, listOfNotNull(previous.account?.connectionID))
                val binding = SyncLibraryIdentity(account.identity, root)
                sync.prepareAccount(binding, client, account.deviceName, SyncAccountIntent.LOGIN)
                currentCoroutineContext().ensureActive()
                accounts.setAccount(account, SyncAccountActivation.ENABLED)
                sync.start(binding, client, account.deviceName)
                val old = lock.withLock {
                    val old = active
                    active = Session(account, client, tier)
                    cached.value = SyncAccountSnapshot(account, me, tier, enabled = true)
                    old
                }
                val cleanup = withContext(NonCancellable) {
                    val remote = remoteCleanup(old?.takeIf { it.account == previous.account }, previous.account,
                        readFailed = false, device = null)
                    deleteSecrets(previous.cleanupConnections + listOfNotNull(previous.account?.connectionID), SyncAccountCleanup(remote))
                }
                cached.value = snapshot.copy(cleanup = cleanup)
                snapshot
            } catch (error: Throwable) {
                val result = failure(error)
                val cleanup = withContext(NonCancellable) {
                    var cleanup = result.cleanup
                    if (staged) {
                        sync.stopAccountSession()
                        sync.drain()
                        lock.withLock { active = null; cached.value = SyncAccountSnapshot(account = previous.account) }
                        try { accounts.saveInactive(previous.account, if (secretAttempted) listOfNotNull(candidate?.connectionID) else emptyList()) }
                        catch (fault: Throwable) { cleanup = cleanup.copy(metadataIssue = metadataError(fault)) }
                    }
                    cleanup = cleanup.copy(remote = revoke(client))
                    if (secretAttempted) cleanup = deleteSecrets(listOfNotNull(candidate?.connectionID), cleanup)
                    cleanup
                }
                cached.value = snapshot.copy(cleanup = cleanup)
                currentCoroutineContext().ensureActive()
                throw SyncAccountServiceError(result.issue, cleanup, registrationCommitted = kind == AuthenticationKind.REGISTER)
            }
        } finally { leave() }
    }

    /** Reauthentication changes the UUID too, invalidating an older staged redemption. */
    internal suspend fun joinInvite(invite: InviteLink, expectedAccount: SyncAccount): Pair<SyncAccountSnapshot, SyncAccountServiceError?> = operation {
        if (snapshot.account != expectedAccount) throw InviteAcceptanceIssue.AccountChanged
        if (expectedAccount.identity.serverURL != invite.server.baseURL) throw InviteAcceptanceIssue.WrongServer
        val current = session()
        if (current.account != expectedAccount || !snapshot.enabled) throw InviteAcceptanceIssue.AccountChanged
        try {
            current.client.joinGroup(invite.token.withValue(::JoinGroupRequest))
        } catch (error: Throwable) {
            val result = inviteFailure(error)
            currentCoroutineContext().ensureActive()
            if (error is CancellationException) throw error
            throw result
        }
        // Redemption committed. A failed refresh must not expose cached roles or retry the invite.
        cached.value = snapshot.copy(me = null)
        try {
            val me = current.client.me()
            validateCurrent(me, current.account)
            cached.value = snapshot.copy(me = me)
            sync.syncNow()
            snapshot to null
        } catch (error: Throwable) {
            val result = inviteFailure(error)
            sync.syncNow()
            currentCoroutineContext().ensureActive()
            if (error is CancellationException) throw error
            snapshot to result
        }
    }

    private suspend fun inviteFailure(error: Throwable): SyncAccountServiceError {
        val result = failure(error)
        if (requiresSignIn(result.issue)) {
            sync.stopAccountSession()
            sync.requireSignIn()
            withContext(NonCancellable) { sync.drain() }
            lock.withLock { active = null; cached.value = snapshot.copy(enabled = false, me = null, tier = null) }
        }
        return result
    }

    /** Inactive/signed-out startup performs no secret read or HTTP, including pending cleanup. */
    internal suspend fun startup(): SyncAccountSnapshot = operation {
        sync.stopAccountSession()
        sync.drain()
        lock.withLock { active = null; cached.value = snapshot.copy(enabled = false, me = null, tier = null) }
        try {
            val connection = accounts.loadConnection()
            cached.value = SyncAccountSnapshot(account = connection.account,
                cleanup = SyncAccountCleanup(secretFailures = connection.cleanupConnections))
            val account = connection.account
            if (account == null || connection.activation != SyncAccountActivation.ENABLED) return@operation snapshot
            val resolved = resolve(account) ?: throw SyncAccountServiceError(SyncAccountIssue.CredentialsRequired)
            val me = resolved.client.me()
            validateCurrent(me, account)
            sync.prepareAccount(SyncLibraryIdentity(account.identity, root), resolved.client, account.deviceName, SyncAccountIntent.STARTUP)
            currentCoroutineContext().ensureActive()
            sync.start(SyncLibraryIdentity(account.identity, root), resolved.client, account.deviceName)
            lock.withLock { active = resolved; cached.value = snapshot.copy(me = me, tier = resolved.tier, enabled = true) }
            snapshot
        } catch (error: Throwable) {
            withContext(NonCancellable) { sync.stopAccountSession(); sync.drain() }
            lock.withLock { active = null; cached.value = snapshot.copy(enabled = false) }
            val result = failure(error)
            if (requiresSignIn(result.issue)) sync.requireSignIn()
            throwFailure(error)
        }
    }

    internal suspend fun refresh(): SyncAccountSnapshot = operation {
        try {
            val session = session()
            val me = session.client.me()
            validateCurrent(me, session.account)
            cached.value = snapshot.copy(me = me)
            snapshot
        } catch (error: Throwable) {
            if (requiresSignIn(failure(error).issue)) {
                sync.stopAccountSession()
                sync.requireSignIn()
                withContext(NonCancellable) { sync.drain() }
                lock.withLock { active = null; cached.value = snapshot.copy(enabled = false, me = null, tier = null) }
            }
            throwFailure(error)
        }
    }

    internal suspend fun devices(): List<Device> = refresh().me?.devices.orEmpty()
    internal suspend fun heldPrompts(): List<SyncHeldPrompt> = withContext(io) {
        try { accounts.binding(root)?.holds.orEmpty() } catch (error: Throwable) { throwFailure(error) }
    }

    /** Only this explicit selected intent releases prior-account upload holds. */
    internal suspend fun includeHeld(identities: Set<PromptIdentity>): SyncAccountSnapshot = operation {
        val session = session()
        val binding = SyncLibraryIdentity(session.account.identity, root)
        try {
            sync.stop()
            sync.drain()
            cached.value = snapshot.copy(enabled = false)
            accounts.disableAutomaticResume()
            sync.prepareAccount(binding, session.client, session.account.deviceName, SyncAccountIntent.LOGIN)
            accounts.updateBinding(root) { current ->
                if (current == null || current.owner != binding.account || !current.holds.map { it.identity }.containsAll(identities)) {
                    throw SyncError.BindingMismatch
                }
                current.copy(holds = current.holds.filter { it.identity !in identities })
            }
            currentCoroutineContext().ensureActive()
            accounts.setAccount(session.account, SyncAccountActivation.ENABLED)
            sync.start(binding, session.client, session.account.deviceName)
            cached.value = snapshot.copy(enabled = true)
            snapshot
        } catch (error: Throwable) {
            withContext(NonCancellable) { sync.stopAccountSession(); sync.drain() }
            val signIn = requiresSignIn(failure(error).issue)
            if (signIn) sync.requireSignIn()
            lock.withLock {
                if (signIn) active = null
                cached.value = snapshot.copy(enabled = false, tier = if (signIn) null else snapshot.tier,
                    me = if (signIn) null else snapshot.me)
            }
            throwFailure(error)
        }
    }

    internal suspend fun revokeDevice(id: ULID): SyncAccountSnapshot = operation {
        val session = session()
        if (id == session.account.deviceID) {
            val cleanup = withContext(NonCancellable) { signOut(session, id) }
            cached.value = snapshot.copy(cleanup = cleanup)
        } else {
            try { session.client.revokeDevice(id) } catch (error: Throwable) { throwFailure(error) }
            cached.value = snapshot.copy(me = null)
        }
        snapshot
    }

    internal suspend fun signOut(): SyncAccountCleanup = operation {
        val cleanup = withContext(NonCancellable) { signOut(lock.withLock { active }, null) }
        cached.value = snapshot.copy(cleanup = cleanup)
        cleanup
    }

    private suspend fun signOut(session: Session?, device: ULID?): SyncAccountCleanup {
        sync.stopAccountSession()
        sync.drain()
        var cleanup = SyncAccountCleanup()
        var connection: SyncConnectionDocument? = null
        var readFailed = false
        try { connection = accounts.connectionForSignOut() }
        catch (error: Throwable) { readFailed = true; cleanup = cleanup.copy(metadataIssue = metadataError(error)) }
        try { accounts.disableAutomaticResume() }
        catch (error: Throwable) { cleanup = cleanup.copy(metadataIssue = metadataError(error)) }
        lock.withLock { active = null; cached.value = SyncAccountSnapshot() }
        // Resolving a persisted credential and /me share the remote five-second budget.
        cleanup = cleanup.copy(remote = remoteCleanup(session, connection?.account, readFailed, device))
        val ids = (connection?.cleanupConnections.orEmpty() + listOfNotNull(connection?.account?.connectionID, session?.account?.connectionID)).distinct()
        try {
            accounts.saveInactive(null, ids)
            // A failed read may have hidden cleanup references preserved by this write.
            if (!readFailed) cleanup = cleanup.copy(metadataIssue = null)
        } catch (error: Throwable) { cleanup = cleanup.copy(metadataIssue = metadataError(error)) }
        try { sync.prepareSignOut(root) }
        catch (_: Throwable) { cleanup = cleanup.copy(recoveryRequired = true) }
        return deleteSecrets(ids, cleanup)
    }

    private fun bind(credential: SyncCredential, account: SyncAccount): SecretValue = credential.token.withValue { token ->
        SecretValue(WireJson.canonical(wireObject("version" to wireLong(Limits.syncDeviceSecretVersion.toLong()),
            "server_url" to wireString(account.identity.serverURL), "user_id" to wireString(account.identity.userID.rawValue),
            "connection_id" to wireString(account.connectionID.toString()), "token" to wireString(token))).decodeToString())
    }

    private suspend fun resolve(account: SyncAccount): Session? {
        val stored = readSecret(account.secretAccount, SecretReadSource.EFFECTIVE) ?: return null
        val server = SyncServerURL(account.identity.serverURL)
        val token = try {
            stored.value.withValue { raw ->
                if (raw.length > Limits.httpRequestCap) throw WireContractException()
                val value = WireObject(WireJson.parse(raw.encodeToByteArray(throwOnInvalidSequence = true)))
                if (value.long("version") != Limits.syncDeviceSecretVersion.toLong() || value.string("server_url") != server.baseURL ||
                    value.string("user_id") != account.identity.userID.rawValue || value.string("connection_id") != account.connectionID.toString()) {
                    throw WireContractException()
                }
                SecretValue(value.string("token", WireValidation::token))
            }
        } catch (_: Exception) { throw SyncAccountServiceError(SyncAccountIssue.TokenBindingMismatch) }
        return Session(account, SyncHTTPClient(server, transport, SyncCredential(server, token), clock), stored.tier)
    }

    /** Cancellation/deadline can finish even when a native read remains blocked. */
    private suspend fun readSecret(account: SecretAccount, source: SecretReadSource): StoredSecret? {
        return try { cancellableSecret { secrets.read(account, source) } }
        catch (error: CancellationException) { throw error }
        catch (error: Throwable) { throw SyncAccountServiceError(SyncAccountIssue.Secret(error as? SecretStoreError ?: SecretStoreError.ReadFailed)) }
    }

    private suspend fun writeSecret(value: SecretValue, account: SecretAccount): SecretTier = try { secrets.write(value, account) }
    catch (error: Throwable) { throw SyncAccountServiceError(SyncAccountIssue.Secret(error as? SecretStoreError ?: SecretStoreError.WriteFailed)) }

    private suspend fun deleteSecrets(ids: List<UUID>, initial: SyncAccountCleanup): SyncAccountCleanup {
        var cleanup = initial
        val deadline = clock.nowNanos() + Limits.syncSecretCleanupTimeoutMillis * 1_000_000
        for (id in ids.distinct().sortedBy { it.toString() }) {
            try {
                val remaining = ((deadline - clock.nowNanos()).coerceAtLeast(0) + 999_999) / 1_000_000
                // A timed-out delete can touch only this unused UUID; its durable reference remains for retry.
                withTimeoutOrNull(remaining) { cancellableSecret { secrets.delete(SecretAccount.device(id)) } }
                    ?: throw SecretStoreError.DeleteFailed
            }
            catch (error: Throwable) {
                cleanup = cleanup.copy(secretFailures = (cleanup.secretFailures + id).distinct().syncListCopy(),
                    secretIssue = error as? SecretStoreError ?: SecretStoreError.DeleteFailed)
                continue
            }
            try { accounts.finishSecretCleanup(id) }
            catch (error: Throwable) { cleanup = cleanup.copy(metadataIssue = metadataError(error)) }
        }
        return cleanup
    }

    private suspend fun <T> cancellableSecret(work: suspend () -> T): T {
        val task = CoroutineScope(currentCoroutineContext().minusKey(Job)).async { work() }
        return try { task.await() } finally { if (!task.isCompleted) task.cancel() }
    }

    private suspend fun revoke(client: SyncHTTPClient): SyncRemoteRevocation = withTimeoutOrNull(Limits.syncLogoutTimeoutMillis) {
        revoke(client, null, clock.nowNanos() + Limits.syncLogoutTimeoutMillis * 1_000_000)
    } ?: SyncRemoteRevocation.UNCONFIRMED

    private suspend fun remoteCleanup(session: Session?, account: SyncAccount?, readFailed: Boolean, device: ULID?): SyncRemoteRevocation =
        withTimeoutOrNull(Limits.syncLogoutTimeoutMillis) {
            val deadline = clock.nowNanos() + Limits.syncLogoutTimeoutMillis * 1_000_000
            try {
                val resolved = session ?: account?.let { resolve(it) }
                if (resolved == null) return@withTimeoutOrNull if (readFailed || account != null) SyncRemoteRevocation.UNCONFIRMED else SyncRemoteRevocation.NOT_NEEDED
                if (session == null) validateCurrent(resolved.client.me(deadline), resolved.account)
                revoke(resolved.client, device, deadline)
            } catch (error: SyncHTTPClientError) {
                if (error == SyncHTTPClientError.Unauthorized) SyncRemoteRevocation.REVOKED else SyncRemoteRevocation.UNCONFIRMED
            } catch (_: Throwable) { SyncRemoteRevocation.UNCONFIRMED }
        } ?: SyncRemoteRevocation.UNCONFIRMED

    private suspend fun revoke(client: SyncHTTPClient, device: ULID?, deadline: Long): SyncRemoteRevocation = try {
        if (device == null) client.logout(deadline) else client.revokeDevice(device, deadline)
        SyncRemoteRevocation.REVOKED
    } catch (error: SyncHTTPClientError) {
        if (error == SyncHTTPClientError.Unauthorized) SyncRemoteRevocation.REVOKED else SyncRemoteRevocation.UNCONFIRMED
    } catch (_: Throwable) { SyncRemoteRevocation.UNCONFIRMED }

    private fun validate(me: MeResponse, user: ULID): Device {
        val current = me.devices.singleOrNull { it.isCurrent }
        if (me.user.id != user.rawValue || me.user.disabledAt != null || me.devices.map { it.id }.toSet().size != me.devices.size ||
            current == null || current.revokedAt != null) throw SyncAccountServiceError(SyncAccountIssue.InvalidAccount)
        return current
    }
    private fun validateCurrent(me: MeResponse, account: SyncAccount) {
        if (validate(me, account.identity.userID).id != account.deviceID.rawValue) throw SyncAccountServiceError(SyncAccountIssue.TokenBindingMismatch)
    }
    private fun requiresSignIn(issue: SyncAccountIssue): Boolean = issue == SyncAccountIssue.CredentialsRequired ||
        issue == SyncAccountIssue.TokenBindingMismatch || issue == SyncAccountIssue.InvalidAccount ||
        issue is SyncAccountIssue.Http && issue.error == SyncHTTPClientError.Unauthorized
    private fun session(): Session = lock.withLock { active } ?: throw SyncAccountServiceError(SyncAccountIssue.SignedOut)
    private fun metadataError(error: Throwable): SyncError = error as? SyncError ?: SyncError.InvalidState
    private fun failure(error: Throwable): SyncAccountServiceError = if (error is SyncAccountServiceError) error else SyncAccountServiceError(when (error) {
        is SyncHTTPClientError -> SyncAccountIssue.Http(error)
        is SyncError -> SyncAccountIssue.Metadata(error)
        is SecretStoreError -> SyncAccountIssue.Secret(error)
        is SyncGroupFolderError.ReservedFolders -> SyncAccountIssue.ReservedFolders(error.paths)
        is LibraryError, is SyncFileOperationError, is SyncCoordinatorError, is SyncReconciliationError -> SyncAccountIssue.RecoveryRequired
        is SyncPushError -> SyncAccountIssue.Busy
        is CancellationException -> SyncAccountIssue.Http(SyncHTTPClientError.Transport(HttpTransportError.Cancelled))
        else -> SyncAccountIssue.InvalidInput
    })
    private suspend fun throwFailure(error: Throwable): Nothing {
        currentCoroutineContext().ensureActive()
        if (error is CancellationException) throw error
        throw failure(error)
    }
    private suspend fun <T> operation(body: suspend () -> T): T = withContext(io) {
        enter()
        try { body() } finally { leave() }
    }
    private fun enter() = lock.withLock { if (busy) throw SyncAccountServiceError(SyncAccountIssue.Busy); busy = true }
    private fun leave() = lock.withLock { busy = false }
}
