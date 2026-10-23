package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.consumeWindowInsets
import ch.lkmc.monkeyspaw.ui.theme.MonkeysPawTheme
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.data.ImeActivityGuard
import ch.lkmc.monkeyspaw.ui.fill.FillViewModel
import ch.lkmc.monkeyspaw.ui.fill.FillViewModelFactory
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import javax.inject.Inject

/** One pick → fill → copy session; repeated entries bring its existing draft to the foreground. */
@AndroidEntryPoint
class FillActivity : ComponentActivity() {
    @Inject internal lateinit var fillFactory: FillViewModelFactory
    @Inject internal lateinit var handoffs: FillHandoffStore
    @Inject internal lateinit var imeActivityGuard: ImeActivityGuard
    private val fill: FillViewModel by viewModels { fillFactory }
    private val library: LibraryViewModel by viewModels()
    private val seedOffer: SeedOfferViewModel by viewModels()

    override fun onStart() {
        super.onStart()
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
    }

    override fun onResume() {
        super.onResume()
        imeActivityGuard.resume(this, Build.VERSION.SDK_INT)
        fill.setForeground(true)
    }

    override fun onPause() {
        imeActivityGuard.pause(this)
        fill.setForeground(false)
        super.onPause()
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        super.onTopResumedActivityChanged(isTopResumedActivity)
        imeActivityGuard.topResumed(this, isTopResumedActivity)
    }

    override fun onDestroy() {
        imeActivityGuard.pause(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val request = FillRoute.read(intent)
        if (request.source == EntrySource.IME_HANDOFF) {
            setIntent(FillRoute(EntrySource.IME_HANDOFF, request.handoffToken).intent(this))
            adoptHandoff(request)
            return
        }
        // A Library selection can activate a picker; the model preserves any held form and snapshot.
        FillRoute.read(intent).promptPath?.let(fill::open)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()
        val request = FillRoute.read(intent)
        if (request.source == EntrySource.IME_HANDOFF && !fill.handoffInitialized) adoptHandoff(request)
        val requestedPath = request.promptPath
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    seedOffer.state.collect { startup ->
                        if (startup == SeedOfferUiState.Ready && requestedPath != null && !fill.handoffInitialized) {
                            fill.open(requestedPath)
                        }
                    }
                }
                launch { fill.state.collect { if (it.shouldFinish) finish() } }
            }
        }
        setContent {
            BackHandler { fill.cancel() }
            MonkeysPawTheme {
                Scaffold { padding ->
                    FillRouteContent(fill, library, seedOffer, Modifier.padding(padding).consumeWindowInsets(padding))
                }
            }
        }
    }

    private fun adoptHandoff(request: FillRequest) {
        fillFactory.restoreHandoff(fill, request.handoffToken?.let(handoffs::consume))
    }

    companion object {
        const val promptPathExtra = "ch.lkmc.monkeyspaw.PROMPT_PATH"
    }
}
