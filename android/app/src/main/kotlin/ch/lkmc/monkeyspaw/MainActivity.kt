package ch.lkmc.monkeyspaw

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.ui.library.LibraryScreen
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private val seedOffer: SeedOfferViewModel by viewModels()
    private val library: LibraryViewModel by viewModels()

    override fun onStart() {
        super.onStart()
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()

        setContent {
            MaterialTheme {
                Scaffold { padding ->
                    val startup = seedOffer.state.collectAsStateWithLifecycle().value
                    if (startup == SeedOfferUiState.Ready) {
                        LibraryScreen(
                            state = library.state.collectAsStateWithLifecycle().value,
                            onQuery = library::setQuery, onFilter = library::setFilter, onSelect = library::select,
                            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
                            onRefresh = library::refresh, modifier = Modifier.padding(padding),
                        )
                    } else {
                        SeedOfferScreen(state = startup, onAccept = seedOffer::accept, onDecline = seedOffer::decline,
                            onRefresh = seedOffer::refresh, modifier = Modifier.padding(padding))
                    }
                }
            }
        }
    }
}
