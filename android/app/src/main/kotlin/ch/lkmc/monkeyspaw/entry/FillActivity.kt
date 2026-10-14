package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.ui.fill.FillPhase
import ch.lkmc.monkeyspaw.ui.fill.FillScreen
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryScreen
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch

/** One pick → fill → copy session; repeated entries bring its existing draft to the foreground. */
@AndroidEntryPoint
class FillActivity : ComponentActivity() {
    private val fill: FillViewModel by viewModels()
    private val library: LibraryViewModel by viewModels()
    private val seedOffer: SeedOfferViewModel by viewModels()

    override fun onStart() {
        super.onStart()
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
    }

    override fun onResume() {
        super.onResume()
        fill.setForeground(true)
    }

    override fun onPause() {
        fill.setForeground(false)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A Library selection can activate a picker; the model preserves any held form and snapshot.
        FillRoute.read(intent).promptPath?.let(fill::open)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()
        val requestedPath = FillRoute.read(intent).promptPath
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    seedOffer.state.collect { startup ->
                        if (startup == SeedOfferUiState.Ready && requestedPath != null) fill.open(requestedPath)
                    }
                }
                launch { fill.state.collect { if (it.shouldFinish) finish() } }
            }
        }
        setContent {
            val form = fill.state.collectAsStateWithLifecycle().value
            val startup = seedOffer.state.collectAsStateWithLifecycle().value
            BackHandler { fill.cancel() }
            MaterialTheme {
                Scaffold { padding ->
                    if (form.phase != FillPhase.PICKING) {
                        FillScreen(state = form, onValue = fill::setValue, onCopy = fill::copy,
                            onCancel = fill::cancel, onRetry = fill::retry, modifier = Modifier.padding(padding))
                    } else if (startup == SeedOfferUiState.Ready) {
                        LibraryScreen(state = library.state.collectAsStateWithLifecycle().value,
                            onQuery = library::setQuery, onFilter = library::setFilter, onSelect = library::select,
                            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
                            onRefresh = library::refresh, onOpen = { fill.open(it.relativePath) },
                            modifier = Modifier.padding(padding))
                    } else {
                        SeedOfferScreen(state = startup, onAccept = seedOffer::accept, onDecline = seedOffer::decline,
                            onRefresh = seedOffer::refresh, modifier = Modifier.padding(padding))
                    }
                }
            }
        }
    }

    companion object {
        const val promptPathExtra = "ch.lkmc.monkeyspaw.PROMPT_PATH"
    }
}
