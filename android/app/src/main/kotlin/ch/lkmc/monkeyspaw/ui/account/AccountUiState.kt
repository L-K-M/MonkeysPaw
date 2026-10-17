package ch.lkmc.monkeyspaw.ui.account

import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.sync.SyncHeldPrompt
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.services.SyncAccountCleanup
import ch.lkmc.monkeyspaw.core.services.SyncAccountSnapshot
import ch.lkmc.monkeyspaw.core.services.SyncRemoteRevocation
import ch.lkmc.monkeyspaw.core.services.InviteAcceptance
import ch.lkmc.monkeyspaw.core.services.InviteDestination
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL

internal enum class AccountAction { REFRESH, SIGN_IN, SIGN_OUT, REVOKE, INCLUDE, TRUST, SYNC, RECOVER, STAGE_INVITE, ACCEPT_INVITE }
internal enum class AccountCondition { INACTIVE, ACTIVE, OFFLINE, NEEDS_SIGN_IN, RECOVERY }
internal typealias HeldIdentity = PromptIdentity
internal typealias InviteMode = InviteAcceptance

/** Memory only. In particular, this draft never enters a saved-state handle or Bundle. */
internal data class AccountDraft(
    val server: String = "", val username: String = "", val deviceName: String = "Android", val password: String = "",
) {
    override fun toString(): String = "<account draft redacted>"
}

internal data class AccountUiState(
    val draft: AccountDraft = AccountDraft(),
    val account: SyncAccountSnapshot = SyncAccountSnapshot(),
    val condition: AccountCondition = AccountCondition.INACTIVE,
    val busy: AccountAction? = null,
    val failure: Int? = null,
    val cleanup: SyncAccountCleanup = SyncAccountCleanup(),
    val trust: SyncTLSTrust = SyncTLSTrust.SYSTEM,
    val holds: List<SyncHeldPrompt> = emptyList(),
    val selectedHolds: Set<PromptIdentity> = emptySet(),
    val revokeConfirmation: String? = null,
    val signOutConfirmation: Boolean = false,
    val includeConfirmation: Boolean = false,
    val sync: SyncStatusUiState = SyncStatusUiState(),
    val inviteDraft: String = "",
    val invite: InviteDestination? = null,
    val inviteMode: InviteAcceptance = InviteAcceptance.EXISTING_ACCOUNT,
    val inviteReady: Boolean = false,
    val inviteMessage: Int? = null,
) {
    val server: SyncServerURL? get() = try { SyncServerURL(draft.server) } catch (_: Exception) { null }
    val httpWarning: Boolean get() = server?.usesPlaintextHTTP == true
    val trustsUserCAs: Boolean get() = trust == SyncTLSTrust.SYSTEM_AND_USER
    val remoteCleanupUnconfirmed: Boolean get() = cleanup.remote == SyncRemoteRevocation.UNCONFIRMED
    val canSignIn: Boolean get() = busy == null && server != null && draft.username.isNotBlank() &&
        draft.deviceName.isNotBlank() && draft.password.isNotEmpty()
    val canSync: Boolean get() = busy == null && account.enabled && sync.canSync
    val canSignOut: Boolean get() = account.account != null || !cleanup.isComplete || condition == AccountCondition.RECOVERY
    val canAcceptInvite: Boolean get() = busy == null && inviteReady && invite != null &&
        if (inviteMode == InviteAcceptance.EXISTING_ACCOUNT) invite.canJoin && account.enabled && account.account == invite.currentAccount
        else draft.username.isNotBlank() && draft.deviceName.isNotBlank() && draft.password.isNotEmpty()
    val conditionText: Int get() = when (condition) {
        AccountCondition.INACTIVE -> R.string.account_inactive
        AccountCondition.ACTIVE -> R.string.account_active
        AccountCondition.OFFLINE -> R.string.sync_offline
        AccountCondition.NEEDS_SIGN_IN -> R.string.sync_needs_sign_in
        AccountCondition.RECOVERY -> R.string.sync_recovery_required
    }
    override fun toString(): String = "<account UI state redacted>"
}
