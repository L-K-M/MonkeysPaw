package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.sync.InviteLink
import ch.lkmc.monkeyspaw.core.domain.sync.InviteLinkError
import ch.lkmc.monkeyspaw.core.domain.sync.SyncAccount
import ch.lkmc.monkeyspaw.core.sync.SyncHTTPClientError
import kotlinx.coroutines.CancellationException

enum class InviteAcceptance { EXISTING_ACCOUNT, NEW_ACCOUNT }

sealed class InviteAcceptanceIssue(message: String) : Exception(message, null, false, true) {
    data object InvalidLink : InviteAcceptanceIssue("Enter a valid invite link or token.")
    data object ServerRequired : InviteAcceptanceIssue("Select the server explicitly before entering a bare invite token.")
    data object AccountChanged : InviteAcceptanceIssue("Your account changed. Open the invite again and check the destination.")
    data object WrongServer : InviteAcceptanceIssue("Sign in to the invite's server before joining with an existing account.")
    data object UnavailableInvite : InviteAcceptanceIssue("This invite could not be used. It may have expired or already been used.")
    data object NoInvite : InviteAcceptanceIssue("Open an invite before accepting.")
    class Account(val failure: SyncAccountServiceError) : InviteAcceptanceIssue("The account operation could not be completed.")
    class RefreshIncomplete(val failure: SyncAccountServiceError) : InviteAcceptanceIssue("The invite was accepted. Refresh Account to finish.")
    class RegistrationIncomplete(val failure: SyncAccountServiceError) : InviteAcceptanceIssue("The account was created. Sign in to finish setup.")

    final override fun toString(): String = "<invite acceptance issue redacted>"
}

data class InviteDestination(val serverURL: String, val currentAccount: SyncAccount?, val canJoin: Boolean, val usesHTTP: Boolean) {
    override fun toString(): String = "<invite destination redacted>"
}

/** Clear on hide; the first Accept attempt consumes the token even on busy/failure/cancellation. */
class StagedInvite internal constructor(
    link: InviteLink, internal val expectedAccount: SyncAccount?, val destination: InviteDestination,
) {
    private var link: InviteLink? = link
    @Synchronized internal fun consume(): InviteLink? = link.also { link = null }
    @Synchronized fun clear() { link = null }
    @get:Synchronized val canAccept: Boolean get() = link != null
    override fun toString(): String = "<staged invite redacted>"
}

data class InviteAcceptanceResult(
    val snapshot: SyncAccountSnapshot, val issue: InviteAcceptanceIssue? = null,
    val cleanup: SyncAccountCleanup = snapshot.cleanup,
) {
    val accepted: Boolean get() = true
    override fun toString(): String = "<invite acceptance result redacted>"
}

/** Local staging only. The shared account service owns admission, credentials and compensation. */
class InviteAcceptanceService(private val account: SyncAccountService) {
    fun stage(input: String, server: String? = null): StagedInvite {
        val link = try { InviteLink(input, server) }
        catch (_: InviteLinkError.ServerRequired) { throw InviteAcceptanceIssue.ServerRequired }
        catch (_: InviteLinkError) { throw InviteAcceptanceIssue.InvalidLink }
        val snapshot = account.snapshot
        return StagedInvite(link, snapshot.account, InviteDestination(link.server.baseURL, snapshot.account,
            snapshot.enabled && snapshot.account?.identity?.serverURL == link.server.baseURL, link.server.usesPlaintextHTTP))
    }

    /** Presentation supplies SecretValue and clears its password draft before awaiting. */
    suspend fun accept(staged: StagedInvite, asAccount: InviteAcceptance, username: String = "",
                                password: SecretValue = SecretValue(""), deviceName: String = ""): InviteAcceptanceResult {
        val link = staged.consume() ?: throw InviteAcceptanceIssue.NoInvite
        try {
            return when (asAccount) {
                InviteAcceptance.EXISTING_ACCOUNT -> {
                    val expected = staged.expectedAccount ?: throw InviteAcceptanceIssue.Account(SyncAccountServiceError(SyncAccountIssue.SignedOut))
                    val (snapshot, failure) = account.joinInvite(link, expected)
                    InviteAcceptanceResult(snapshot, failure?.let(InviteAcceptanceIssue::RefreshIncomplete))
                }
                InviteAcceptance.NEW_ACCOUNT -> {
                    val snapshot = account.register(link, staged.expectedAccount, username, password, deviceName)
                    InviteAcceptanceResult(snapshot)
                }
            }
        } catch (error: CancellationException) { throw error }
        catch (error: SyncAccountServiceError) {
            if (error.registrationCommitted) return InviteAcceptanceResult(account.snapshot,
                InviteAcceptanceIssue.RegistrationIncomplete(error), error.cleanup)
            // Registration also returns 400 for a taken username; it cannot identify an unusable invite.
            if (asAccount == InviteAcceptance.EXISTING_ACCOUNT &&
                (error.issue as? SyncAccountIssue.Http)?.error == SyncHTTPClientError.MalformedRequest) throw InviteAcceptanceIssue.UnavailableInvite
            throw InviteAcceptanceIssue.Account(error)
        }
    }

    override fun toString(): String = "<invite acceptance service redacted>"
}
