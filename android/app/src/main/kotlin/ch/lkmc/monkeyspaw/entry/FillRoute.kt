package ch.lkmc.monkeyspaw.entry

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ch.lkmc.monkeyspaw.ui.fill.*
import ch.lkmc.monkeyspaw.ui.library.LibraryScreen
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel

internal enum class EntrySource(val requestCode: Int) {
    LIBRARY(0), TILE(1), SHORTCUT(2), WIDGET(3), IME_HANDOFF(4);

    val action: String get() = "ch.lkmc.monkeyspaw.FILL.$name"
}

internal data class FillRequest(val source: EntrySource, val promptPath: String? = null, val handoffToken: String? = null) {
    override fun toString(): String = "FillRequest(source=$source, payload=<redacted>)"
}

/** Fresh explicit intents carry only the entry action. External entries always start at the picker. */
internal class FillRoute(val source: EntrySource, private val handoffToken: String? = null) {
    val targetClass = FillActivity::class.java
    val activityFlags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
    val pendingIntentFlags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    fun intent(context: Context): Intent = Intent(context, targetClass)
        .setAction(source.action)
        .setFlags(activityFlags)
        .apply {
            if (source == EntrySource.IME_HANDOFF && handoffToken != null) putExtra(handoffTokenExtra, handoffToken)
        }

    fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
        context, source.requestCode, intent(context), pendingIntentFlags,
    )

    companion object {
        const val handoffTokenExtra = "ch.lkmc.monkeyspaw.FILL_HANDOFF"
        private val tokenPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        fun read(intent: Intent): FillRequest = try {
            val action = intent.action
            // The K15 library caller has no action. Do not even unpack extras for external entries.
            val path = if (action == null || action == EntrySource.LIBRARY.action) {
                intent.getStringExtra(FillActivity.promptPathExtra)
            } else null
            val token = if (action == EntrySource.IME_HANDOFF.action) intent.getStringExtra(handoffTokenExtra) else null
            sanitize(action, path, token)
        } catch (_: RuntimeException) {
            // Malformed handoff extras cannot turn an ephemeral session into normal learning.
            if (intent.action == EntrySource.IME_HANDOFF.action) FillRequest(EntrySource.IME_HANDOFF)
            else FillRequest(EntrySource.LIBRARY)
        }

        fun sanitize(action: String?, promptPath: String?, handoffToken: String? = null): FillRequest {
            val source = EntrySource.entries.firstOrNull { it.action == action } ?: EntrySource.LIBRARY
            val path = promptPath.takeIf { action == null || action == EntrySource.LIBRARY.action }
            val token = handoffToken?.takeIf { source == EntrySource.IME_HANDOFF && tokenPattern.matches(it) }
            return FillRequest(source, path, token)
        }
    }
}

/** Shared activity content for Copy, selection results and share capture; the host owns its effect. */
@Composable
internal fun FillRouteContent(fill: FillViewModel, library: LibraryViewModel, seedOffer: SeedOfferViewModel,
    modifier: Modifier = Modifier) {
    val form = fill.state.collectAsStateWithLifecycle().value
    val startup = seedOffer.state.collectAsStateWithLifecycle().value
    if (form.phase != FillPhase.PICKING) {
        FillScreen(state = form, onValue = fill::setValue, onCopy = fill::copy, onInsert = fill::insert,
            onCapturedField = fill::selectCapturedField, onCancel = fill::cancel, onRetry = fill::retry,
            modifier = modifier)
    } else if (startup == SeedOfferUiState.Ready) {
        LibraryScreen(state = library.state.collectAsStateWithLifecycle().value,
            onQuery = library::setQuery, onFilter = library::setFilter, onSelect = library::select,
            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
            onRefresh = library::refresh, onOpen = { fill.open(it.relativePath) }, modifier = modifier)
    } else {
        SeedOfferScreen(state = startup, onAccept = seedOffer::accept, onDecline = seedOffer::decline,
            onRefresh = seedOffer::refresh, modifier = modifier)
    }
}
