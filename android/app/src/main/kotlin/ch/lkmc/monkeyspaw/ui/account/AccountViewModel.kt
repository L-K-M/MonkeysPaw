package ch.lkmc.monkeyspaw.ui.account

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncHTTPClientError
import ch.lkmc.monkeyspaw.core.syncapi.LoginRequest
import ch.lkmc.monkeyspaw.data.AndroidSyncRepository
import ch.lkmc.monkeyspaw.data.SyncForegroundOwner
import ch.lkmc.monkeyspaw.data.SyncWorkScheduler
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject

@HiltViewModel
internal class AccountViewModel @Inject constructor(
    private val repository: AndroidSyncRepository,
    private val scheduler: SyncWorkScheduler,
) : ViewModel() {
    private val mutableState = MutableStateFlow(AccountUiState())
    val state = mutableState.asStateFlow()
    private val settingsMutex = Mutex()
    private var command: Job? = null
    private var signOutCommand: Job? = null
    private var commandVersion = 0L
    private var draftVersion = 0L
    private var serverVersion = 0L
    private var draftInitialized = false
    private var foreground: SyncForegroundOwner? = null
    private var foregroundJob: Job? = null
    private var failureCondition: AccountCondition? = null
    private var stagedInvite: StagedInvite? = null
    private var inviteVersion = 0L

    init {
        viewModelScope.launch { repository.accounts.collect { snapshot ->
            if (snapshot != null) {
                if (state.value.inviteReady && stagedInvite?.destination?.currentAccount != snapshot.account)
                    clearInvite(R.string.invite_account_changed)
                mutableState.value = state.value.copy(account = snapshot, cleanup = snapshot.cleanup)
                projectCondition()
            }
        } }
        viewModelScope.launch { repository.reports.collect {
            val becameEnabled = it?.enabled == true && !state.value.sync.enabled
            mutableState.value = state.value.copy(sync = syncStatus(it))
            projectCondition()
            if (becameEnabled && foreground != null && foregroundJob?.isActive != true) updateForeground()
        } }
    }

    /** Only the launcher Library/Account owns this lease. Fill and IME never construct this model. */
    fun setForeground(owner: SyncForegroundOwner?) {
        if (owner == null) hide()
        if (foreground == owner) return
        val wasHidden = foreground == null
        foreground = owner
        if (owner != null && wasHidden && state.value.busy == null) refresh() else updateForeground()
    }

    fun hide() {
        clearInvite()
        mutableState.value = state.value.copy(draft = state.value.draft.copy(password = ""),
            revokeConfirmation = null, signOutConfirmation = false, includeConfirmation = false)
        cancelCommand()
    }

    fun cancel() { hide() }

    fun setInviteDraft(value: String) {
        if (state.value.busy != null) return
        clearInvite()
        mutableState.value = state.value.copy(inviteDraft = value)
    }

    fun setInviteMode(mode: InviteAcceptance) {
        if (state.value.busy != null) return
        mutableState.value = state.value.copy(inviteMode = mode, draft = state.value.draft.copy(password = ""))
    }

    fun stageInvite(input: String = state.value.inviteDraft) {
        val previous = command
        val signOut = signOutCommand
        if (previous !== signOut) previous?.cancel()
        val server = state.value.server?.baseURL
        clearInvite()
        val version = inviteVersion
        run(AccountAction.STAGE_INVITE, replace = true) {
            // Replacement links still wait for the separately retained, confirmed sign-out.
            signOut?.join()
            previous?.join()
            try {
                // Account entry may restore its own session; an invite never redeems during this refresh.
                try { repository.resume() }
                catch (error: Exception) {
                    if (error is CancellationException) throw error
                    if (version == inviteVersion) showFailure(error)
                }
                val invite = repository.stageInvite(input, server)
                if (version != inviteVersion) { invite.clear(); return@run }
                stagedInvite = invite
                setServer(invite.destination.serverURL)
                mutableState.value = state.value.copy(invite = invite.destination, inviteReady = true,
                    inviteMode = InviteAcceptance.EXISTING_ACCOUNT, inviteMessage = null)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (version == inviteVersion) showInviteFailure(error)
            }
        }
    }

    fun acceptInvite() {
        if (!state.value.canAcceptInvite) return
        val invite = stagedInvite ?: return
        val mode = state.value.inviteMode
        val draft = state.value.draft
        val password = SecretValue(draft.password)
        val version = inviteVersion
        mutableState.value = state.value.copy(inviteDraft = "", inviteReady = false, draft = draft.copy(password = ""))
        run(AccountAction.ACCEPT_INVITE) {
            val result = try {
                settingsMutex.withLock {
                    repository.acceptInvite(invite, mode, draft.username, password, draft.deviceName)
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (version == inviteVersion) showInviteFailure(error)
                return@run
            } finally {
                invite.clear()
                if (stagedInvite === invite) stagedInvite = null
            }
            if (version != inviteVersion) return@run
            mutableState.value = state.value.copy(cleanup = result.cleanup, inviteMessage = when (result.issue) {
                is InviteAcceptanceIssue.RegistrationIncomplete -> R.string.invite_registration_incomplete
                is InviteAcceptanceIssue.RefreshIncomplete -> R.string.invite_refresh_incomplete
                else -> R.string.invite_accepted
            })
            // A later local read failure cannot turn known redemption into a retry invitation.
            try { loadLocal() }
            catch (error: Exception) {
                if (error is CancellationException) throw error
                if (version == inviteVersion) showFailure(error)
            }
        }
    }

    fun dismissInvite() {
        clearInvite()
        if (state.value.busy == AccountAction.STAGE_INVITE || state.value.busy == AccountAction.ACCEPT_INVITE) cancelCommand()
    }

    private fun clearInvite(message: Int? = null) {
        inviteVersion++
        stagedInvite?.clear()
        stagedInvite = null
        mutableState.value = state.value.copy(inviteDraft = "", invite = null, inviteReady = false, inviteMessage = message,
            draft = state.value.draft.copy(password = ""))
    }

    private fun showInviteFailure(error: Exception) {
        val message = when (error) {
            InviteAcceptanceIssue.InvalidLink -> R.string.invite_invalid
            InviteAcceptanceIssue.ServerRequired -> R.string.invite_server_required
            InviteAcceptanceIssue.AccountChanged -> R.string.invite_account_changed
            InviteAcceptanceIssue.WrongServer -> R.string.invite_authenticate
            InviteAcceptanceIssue.UnavailableInvite -> R.string.invite_unavailable
            InviteAcceptanceIssue.NoInvite -> R.string.invite_reopen
            is InviteAcceptanceIssue.Account -> { showFailure(error.failure); R.string.invite_reopen }
            else -> { showFailure(error); R.string.invite_reopen }
        }
        mutableState.value = state.value.copy(inviteReady = false, inviteMessage = message)
    }

    override fun onCleared() {
        clearInvite()
    }

    fun setServer(value: String) {
        if (value == state.value.draft.server) return
        val old = state.value.server
        edit(state.value.draft.copy(server = value))
        val server = state.value.server
        if (old == server) return
        val version = ++serverVersion
        mutableState.value = state.value.copy(trust = SyncTLSTrust.SYSTEM)
        viewModelScope.launch {
            try {
                settingsMutex.withLock {
                    if (version != serverVersion) return@withLock
                    // An intervening draft deployment revokes consent even when its write was coalesced away.
                    repository.selectServer(null)
                    val selected = repository.selectServer(server)
                    if (version == serverVersion) mutableState.value = state.value.copy(trust = selected?.trust ?: SyncTLSTrust.SYSTEM)
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (version == serverVersion) mutableState.value = state.value.copy(failure = R.string.account_trust_failed)
            }
        }
    }

    fun setUsername(value: String) = edit(state.value.draft.copy(username = value))
    fun setDeviceName(value: String) = edit(state.value.draft.copy(deviceName = value))
    fun setPassword(value: String) = edit(state.value.draft.copy(password = value))

    private fun edit(draft: AccountDraft) {
        draftInitialized = true
        draftVersion++
        mutableState.value = state.value.copy(draft = draft)
    }

    fun refresh() = run(AccountAction.REFRESH) {
        val edit = draftVersion
        val alreadyActive = state.value.account.enabled
        var snapshot = repository.resume()
        if (alreadyActive && snapshot.enabled) snapshot = repository.refreshAccount()
        if (!draftInitialized && edit == draftVersion) {
            snapshot.account?.let { account ->
                mutableState.value = state.value.copy(draft = AccountDraft(account.identity.serverURL, account.username, account.deviceName))
                draftInitialized = true
            }
        }
        loadLocal()
    }

    fun signIn() {
        if (state.value.busy != null) return
        val draft = state.value.draft
        val server = state.value.server
        val version = serverVersion
        val password = SecretValue(draft.password)
        mutableState.value = state.value.copy(draft = draft.copy(password = ""))
        val valid = try {
            if (server == null) false else {
                LoginRequest.codec.encode(LoginRequest(draft.username, draft.password, draft.deviceName))
                true
            }
        } catch (_: Exception) { false }
        if (!valid) { mutableState.value = state.value.copy(failure = R.string.account_invalid_input); return }
        run(AccountAction.SIGN_IN) {
            settingsMutex.withLock {
                if (version != serverVersion) throw CancellationException()
                repository.login(checkNotNull(server).baseURL, draft.username, password, draft.deviceName)
            }
            loadLocal()
        }
    }

    fun setTrust(enabled: Boolean) {
        val server = state.value.server ?: return
        if (server.usesPlaintextHTTP) return
        val version = serverVersion
        run(AccountAction.TRUST) {
            settingsMutex.withLock {
                if (version != serverVersion) throw CancellationException()
                repository.selectServer(server)
                val settings = repository.setTlsTrust(server, if (enabled) SyncTLSTrust.SYSTEM_AND_USER else SyncTLSTrust.SYSTEM)
                if (version == serverVersion) mutableState.value = state.value.copy(trust = settings.trust)
                if (state.value.account.enabled && state.value.account.account?.identity?.serverURL == server.baseURL) repository.reconnect()
            }
        }
    }

    fun requestSignOut() {
        if (state.value.canSignOut)
            mutableState.value = state.value.copy(signOutConfirmation = true)
    }

    fun dismissConfirmation() {
        mutableState.value = state.value.copy(signOutConfirmation = false, revokeConfirmation = null, includeConfirmation = false)
    }

    fun signOut() {
        if (!state.value.signOutConfirmation || state.value.busy == AccountAction.SIGN_OUT) return
        dismissConfirmation()
        val previous = command
        previous?.cancel()
        run(AccountAction.SIGN_OUT, replace = true) {
            previous?.join()
            val cleanup = repository.signOut()
            mutableState.value = state.value.copy(cleanup = cleanup, holds = emptyList(), selectedHolds = emptySet())
        }
        signOutCommand = command
    }

    fun requestRevoke(id: String) {
        if (state.value.busy == null && state.value.account.enabled && state.value.account.me?.devices?.any { it.id == id && it.revokedAt == null } == true)
            mutableState.value = state.value.copy(revokeConfirmation = id)
    }

    fun revokeDevice() {
        val id = state.value.revokeConfirmation ?: return
        if (state.value.busy != null) return
        dismissConfirmation()
        run(AccountAction.REVOKE) {
            val snapshot = repository.revokeDevice(checkNotNull(ULID.parse(id)))
            if (snapshot.account == null) {
                mutableState.value = state.value.copy(cleanup = snapshot.cleanup, holds = emptyList(), selectedHolds = emptySet())
            } else repository.refreshAccount()
        }
    }

    fun selectHold(identity: PromptIdentity) {
        if (state.value.busy != null || state.value.holds.none { it.identity == identity }) return
        val selected = state.value.selectedHolds
        mutableState.value = state.value.copy(selectedHolds = if (identity in selected) selected - identity else selected + identity)
    }

    fun requestInclude() {
        if (state.value.busy == null && state.value.account.enabled && state.value.selectedHolds.isNotEmpty())
            mutableState.value = state.value.copy(includeConfirmation = true)
    }

    fun includeSelected() {
        if (!state.value.includeConfirmation || state.value.busy != null) return
        val identities = state.value.selectedHolds.toSet()
        dismissConfirmation()
        run(AccountAction.INCLUDE) { repository.includeHeld(identities); loadLocal() }
    }

    fun syncNow() {
        if (state.value.canSync) run(AccountAction.SYNC) { repository.syncNow() }
    }

    fun recover() {
        if (state.value.condition != AccountCondition.RECOVERY) return
        run(AccountAction.RECOVER) { repository.recoverLocal(); repository.resume(); loadLocal() }
    }

    private suspend fun loadLocal() {
        val holds = repository.heldPrompts()
        val settings = settingsMutex.withLock { repository.tlsSettings() }
        mutableState.value = state.value.copy(holds = holds, selectedHolds = state.value.selectedHolds.intersect(holds.map { it.identity }.toSet()),
            trust = settings?.takeIf { it.server == state.value.server }?.trust ?: SyncTLSTrust.SYSTEM)
    }

    private fun cancelCommand() {
        if (state.value.busy == null || state.value.busy == AccountAction.SIGN_OUT) return
        // A job cancelled before first dispatch never enters run's finally.
        ++commandVersion
        command?.cancel()
        mutableState.value = state.value.copy(busy = null)
        projectCondition()
        if (repository.reports.value?.enabled == true) updateForeground()
    }

    private fun run(action: AccountAction, replace: Boolean = false, body: suspend () -> Unit) {
        if (!replace && state.value.busy != null) return
        val version = ++commandVersion
        failureCondition = null
        mutableState.value = state.value.copy(busy = action, failure = null,
            draft = state.value.draft.copy(password = ""))
        command = viewModelScope.launch {
            var completed = false
            try { body(); completed = true }
            catch (error: Exception) {
                if (error is CancellationException) throw error
                if (version == commandVersion) showFailure(error)
            } finally {
                if (version == commandVersion) {
                    mutableState.value = state.value.copy(busy = null, draft = state.value.draft.copy(password = ""))
                    projectCondition()
                    // A transient /me refresh failure must not strand an already authenticated foreground session.
                    if (completed || repository.reports.value?.enabled == true) updateForeground()
                }
            }
        }
    }

    private fun updateForeground() {
        val previous = foregroundJob
        previous?.cancel()
        val owner = foreground
        val pending = command
        foregroundJob = viewModelScope.launch {
            previous?.join()
            if (owner == null) return@launch
            pending?.join()
            try {
                scheduler.enter(owner)
                awaitCancellation()
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                showFailure(error)
            } finally {
                withContext(NonCancellable) {
                    try { scheduler.leave(owner) }
                    catch (error: Exception) { showFailure(error) }
                }
            }
        }
    }

    private fun projectCondition() {
        val report = repository.reports.value
        val condition = when {
            report?.needsSignIn == true -> AccountCondition.NEEDS_SIGN_IN
            report?.blockingIssue != null -> AccountCondition.RECOVERY
            failureCondition != null -> checkNotNull(failureCondition)
            report?.offline == true -> AccountCondition.OFFLINE
            state.value.account.enabled -> AccountCondition.ACTIVE
            else -> AccountCondition.INACTIVE
        }
        mutableState.value = state.value.copy(condition = condition)
    }

    private fun showFailure(error: Exception) {
        val service = error as? SyncAccountServiceError
        val issue = service?.issue
        val http = (issue as? SyncAccountIssue.Http)?.error ?: error as? SyncHTTPClientError
        val message = when {
            issue is SyncAccountIssue.ReservedFolders -> R.string.account_reserved_folders
            issue == SyncAccountIssue.CredentialsRequired || issue == SyncAccountIssue.TokenBindingMismatch ||
                issue == SyncAccountIssue.InvalidAccount || http == SyncHTTPClientError.Unauthorized -> {
                failureCondition = AccountCondition.NEEDS_SIGN_IN
                R.string.sync_needs_sign_in
            }
            http is SyncHTTPClientError.Transport && http.error in setOf(HttpTransportError.NetworkFailure, HttpTransportError.DeadlineExceeded) -> {
                failureCondition = AccountCondition.OFFLINE
                R.string.sync_offline
            }
            issue == SyncAccountIssue.RecoveryRequired || issue is SyncAccountIssue.Metadata || error is SyncError || error is LibraryError -> {
                failureCondition = AccountCondition.RECOVERY
                R.string.sync_recovery_required
            }
            issue is SyncAccountIssue.Secret -> R.string.account_secret_failed
            issue == SyncAccountIssue.Busy -> R.string.account_busy
            issue == SyncAccountIssue.InvalidInput -> R.string.account_invalid_input
            else -> R.string.account_operation_failed
        }
        mutableState.value = state.value.copy(failure = message,
            cleanup = service?.cleanup?.takeUnless { it.isComplete } ?: state.value.cleanup)
        projectCondition()
    }
}
