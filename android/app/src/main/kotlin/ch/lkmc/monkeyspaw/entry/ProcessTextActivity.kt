package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.os.Bundle
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
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.data.CopyTextDelivery
import ch.lkmc.monkeyspaw.ui.fill.FillViewModelFactory
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Hosts Fill in the caller's result activity, without forwarding or starting another task. */
@AndroidEntryPoint
class ProcessTextActivity : ComponentActivity() {
    @Inject internal lateinit var fillFactory: FillViewModelFactory
    @Inject internal lateinit var copy: CopyTextDelivery
    private val entry: ProcessTextEntry by viewModels {
        object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                require(modelClass == ProcessTextEntry::class.java)
                @Suppress("UNCHECKED_CAST")
                return ProcessTextEntry(fillFactory::create, copy) as T
            }
        }
    }
    private val library: LibraryViewModel by viewModels()
    private val seedOffer: SeedOfferViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()
        setResult(RESULT_CANCELED)
        if (!entry.initialized) {
            // A retained model survives rotation; lost process memory never replays a selection.
            entry.start(if (savedInstanceState == null) ProcessTextIntentDecoder.read(intent) else null)
        }
        setIntent(Intent())
        entry.attach(this) { text ->
            if (text == null) setResult(RESULT_CANCELED)
            else setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, text))
        }
        if (entry.form.value == null) {
            finish()
            return
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                entry.form.collectLatest { form ->
                    if (form == null) finish()
                    else form.state.collect { if (entry.form.value === form && it.shouldFinish) finish() }
                }
            }
        }
        setContent {
            val form = entry.form.collectAsStateWithLifecycle().value
            BackHandler { form?.cancel() }
            MonkeysPawTheme {
                Scaffold { padding ->
                    form?.let { FillRouteContent(it, library, seedOffer, Modifier.padding(padding).consumeWindowInsets(padding)) }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (entry.form.value == null) return
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
    }

    override fun onResume() {
        super.onResume()
        entry.setForeground(this, true)
    }

    override fun onPause() {
        entry.setForeground(this, false)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!isFinishing) entry.start(ProcessTextIntentDecoder.read(intent))
        setIntent(Intent())
    }

    override fun onDestroy() {
        entry.detach(this)
        if (isFinishing) entry.close()
        super.onDestroy()
    }
}
