package ch.lkmc.monkeyspaw.entry

import ch.lkmc.monkeyspaw.core.domain.format.PromptBuiltinValues
import ch.lkmc.monkeyspaw.core.ports.LearningPolicy
import ch.lkmc.monkeyspaw.core.services.LibraryEntry
import ch.lkmc.monkeyspaw.ui.fill.CapturedTextFieldChoice
import ch.lkmc.monkeyspaw.ui.fill.FillFieldState
import ch.lkmc.monkeyspaw.ui.fill.FillWarning
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/** Content only, never a delivery endpoint, validity callback or framework connection. */
internal class FillFormSnapshot(
    val entry: LibraryEntry,
    val fields: List<FillFieldState>,
    val builtins: PromptBuiltinValues,
    val capturedText: CapturedTextFieldChoice?,
    val warnings: List<FillWarning>,
) {
    override fun toString(): String = "FillFormSnapshot(<redacted>)"
}

internal class FillHandoff(
    val learning: LearningPolicy,
    val capture: CapturedTextRequest?,
    val form: FillFormSnapshot?,
) {
    override fun toString(): String = "FillHandoff(<redacted>)"
}

/** One process-local slot: consuming, cancelling or replacing it drops the held payload. */
@Singleton
internal class FillHandoffStore @Inject constructor() {
    private var pending: Pair<String, FillHandoff>? = null

    @Synchronized
    fun offer(handoff: FillHandoff): String {
        val token = UUID.randomUUID().toString()
        pending = token to handoff
        return token
    }

    @Synchronized
    fun consume(token: String): FillHandoff? {
        val current = pending?.takeIf { it.first == token } ?: return null
        pending = null
        return current.second
    }

    @Synchronized
    fun clear(token: String) {
        if (pending?.first == token) pending = null
    }
}
