package ch.lkmc.monkeyspaw.ui.assistant

import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.ui.settings.settingsErrorResource

internal fun assistantUnavailableResource(reason: AssistantUnavailable): Int = when (reason) {
    AssistantUnavailable.PROVIDER -> R.string.assistant_setup
    AssistantUnavailable.LIBRARY -> R.string.assistant_graph_failed
    AssistantUnavailable.ACCESS -> R.string.assistant_access_denied
    AssistantUnavailable.BUSY -> R.string.assistant_editor_busy
    AssistantUnavailable.CONFLICT -> R.string.assistant_editor_conflict
}

/** Only static typed messages reach the UI; provider diagnostics and stop reasons stay redacted. */
internal fun assistantFailureResource(failure: AssistantFailure): Int = when (failure) {
    is AssistantFailure.Assistant -> when (val error = failure.error) {
        AssistantError.NotConfigured -> R.string.assistant_setup
        AssistantError.AccessDenied -> R.string.assistant_access_denied
        AssistantError.PrivatePrompt -> R.string.assistant_private
        AssistantError.Authentication -> R.string.assistant_authentication
        AssistantError.ModelNotFound -> R.string.assistant_model_missing
        is AssistantError.RateLimited -> R.string.assistant_rate_limited
        AssistantError.Overloaded -> R.string.assistant_overloaded
        is AssistantError.ProviderFailure -> R.string.assistant_provider_failed
        AssistantError.ProviderState -> R.string.assistant_provider_state_failed
        AssistantError.Truncated -> R.string.assistant_truncated
        AssistantError.Declined -> R.string.assistant_declined
        AssistantError.EmptyResponse -> R.string.assistant_empty_response
        is AssistantError.UnexpectedStop -> R.string.assistant_unexpected_stop
        AssistantError.InvalidOutput -> R.string.assistant_invalid_output
        is AssistantError.Transport -> when (error.error) {
            HttpTransportError.Cancelled -> R.string.assistant_cancelled
            HttpTransportError.DeadlineExceeded -> R.string.assistant_timeout
            else -> R.string.assistant_network_failed
        }
    }
    is AssistantFailure.Settings -> settingsErrorResource(failure.error)
    is AssistantFailure.Invalid -> R.string.assistant_invalid_draft
    is AssistantFailure.ReadOnly -> R.string.editor_read_only_failed
    is AssistantFailure.Write -> R.string.assistant_serialization_failed
    is AssistantFailure.Identity -> R.string.assistant_identity_failed
    is AssistantFailure.Diff -> R.string.assistant_diff_failed
    AssistantFailure.NoEditor -> R.string.assistant_no_editor
    AssistantFailure.EditorBusy -> R.string.assistant_editor_busy
    AssistantFailure.EditorConflict -> R.string.assistant_editor_conflict
    AssistantFailure.StaleContext -> R.string.assistant_context_changed
}

internal fun assistantOutcomeResource(outcome: AssistantAcceptanceOutcome): Int = when (outcome) {
    is AssistantAcceptanceOutcome.Saved -> R.string.assistant_saved
    is AssistantAcceptanceOutcome.CommittedWithProvenanceWarning -> R.string.assistant_provenance_warning
    is AssistantAcceptanceOutcome.Conflict -> when (outcome.reason) {
        AssistantAcceptanceConflict.ChangedBuffer -> R.string.assistant_stale
        is AssistantAcceptanceConflict.Modified -> R.string.assistant_editor_conflict
        AssistantAcceptanceConflict.Deleted -> R.string.assistant_source_deleted
    }
    is AssistantAcceptanceOutcome.Failed -> when (outcome.reason) {
        AssistantAcceptanceFailure.NotReady -> R.string.assistant_not_ready
        AssistantAcceptanceFailure.Cancelled -> R.string.assistant_cancelled
        AssistantAcceptanceFailure.Inactive, AssistantAcceptanceFailure.StaleContext -> R.string.assistant_context_changed
        AssistantAcceptanceFailure.AccessDenied -> R.string.assistant_access_denied
        AssistantAcceptanceFailure.EditorBusy -> R.string.assistant_editor_busy
        is AssistantAcceptanceFailure.Editing -> R.string.assistant_save_failed
        is AssistantAcceptanceFailure.Invalid -> R.string.assistant_invalid_draft
        is AssistantAcceptanceFailure.ReadOnly -> R.string.editor_read_only_failed
    }
}
