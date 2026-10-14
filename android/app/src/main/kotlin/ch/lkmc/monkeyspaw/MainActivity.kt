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
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private val seedOffer: SeedOfferViewModel by viewModels()

    override fun onStart() {
        super.onStart()
        seedOffer.refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()

        setContent {
            MaterialTheme {
                Scaffold { padding ->
                    SeedOfferScreen(
                        state = seedOffer.state.collectAsStateWithLifecycle().value,
                        promptCount = seedOffer.libraryState.collectAsStateWithLifecycle().value.snapshot.prompts.size,
                        onAccept = seedOffer::accept,
                        onDecline = seedOffer::decline,
                        onRefresh = seedOffer::refresh,
                        modifier = Modifier.padding(padding),
                    )
                }
            }
        }
    }
}
