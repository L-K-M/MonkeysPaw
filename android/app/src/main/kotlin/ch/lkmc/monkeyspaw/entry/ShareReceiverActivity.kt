package ch.lkmc.monkeyspaw.entry

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.data.CopyTextDelivery
import ch.lkmc.monkeyspaw.ui.editor.EditorScreen
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModelFactory
import ch.lkmc.monkeyspaw.ui.fill.FillViewModelFactory
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import ch.lkmc.monkeyspaw.ui.theme.MonkeysPawTheme
import ch.lkmc.monkeyspaw.ui.theme.PawSpacing
import ch.lkmc.monkeyspaw.ui.components.PawScreen
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

/** Capture-only entry: hosts the existing Fill or editor without a sender result or forwarding. */
@AndroidEntryPoint
class ShareReceiverActivity : ComponentActivity() {
    @Inject internal lateinit var fillFactory: FillViewModelFactory
    @Inject internal lateinit var editorFactory: EditorViewModelFactory
    @Inject internal lateinit var copy: CopyTextDelivery
    private val entry: ShareEntry by viewModels {
        object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                require(modelClass == ShareEntry::class.java)
                @Suppress("UNCHECKED_CAST")
                return ShareEntry(fillFactory::create, copy, editorFactory) as T
            }
        }
    }
    private val library: LibraryViewModel by viewModels()
    private val seedOffer: SeedOfferViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = AppIdentity.displayName
        enableEdgeToEdge()
        if (!entry.initialized) {
            // Rotation retains the entry; process loss drops the capture rather than replaying it.
            entry.start(if (savedInstanceState == null) ShareIntentDecoder.read(intent) else null)
        }
        setIntent(Intent())
        entry.attach(this)
        if (entry.destination.value == ShareDestination.Closed) {
            finish()
            return
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                entry.destination.collectLatest { destination ->
                    when (destination) {
                        ShareDestination.Closed -> finish()
                        is ShareDestination.Filling -> {
                            refreshPicker()
                            destination.form.state.collect {
                                if (entry.destination.value === destination && it.shouldFinish) finish()
                            }
                        }
                        is ShareDestination.Editing -> destination.editor.state.collect {
                            if (entry.destination.value === destination && !it.isOpen) finish()
                        }
                        ShareDestination.Choosing -> Unit
                    }
                }
            }
        }
        setContent {
            BackHandler { entry.back() }
            MonkeysPawTheme {
                Scaffold { padding ->
                    val modifier = Modifier.padding(padding).consumeWindowInsets(padding)
                    when (val destination = entry.destination.collectAsStateWithLifecycle().value) {
                        ShareDestination.Choosing -> PawScreen(stringResource(R.string.share_title), modifier, onBack = entry::back) {
                            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(PawSpacing.section),
                                verticalArrangement = Arrangement.spacedBy(PawSpacing.section)) {
                                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) {
                                    Icon(Icons.Rounded.ContentPaste, null, Modifier.padding(PawSpacing.large).size(32.dp),
                                        tint = MaterialTheme.colorScheme.onPrimaryContainer)
                                }
                                Text(stringResource(R.string.share_help), style = MaterialTheme.typography.bodyLarge)
                                Button(onClick = entry::useInPrompt, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.share_use_in_prompt)) }
                                OutlinedButton(onClick = entry::saveAsNewPrompt, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.share_save_as_new)) }
                                TextButton(onClick = entry::back) { Text(stringResource(R.string.share_cancel)) }
                            }
                        }
                        is ShareDestination.Filling -> FillRouteContent(destination.form, library, seedOffer, modifier)
                        is ShareDestination.Editing -> {
                            val editor = destination.editor
                            EditorScreen(state = editor.state.collectAsStateWithLifecycle().value,
                                onEdit = editor::edit, onNewPath = editor::setNewPath, onTab = editor::setTab,
                                onSave = editor::save, onBack = editor::close, onReload = editor::reload,
                                onRename = editor::rename, onMove = editor::move,
                                onPrivateCopy = editor::privateCopy, onDelete = editor::delete,
                                onHistory = editor::loadHistory, onRevision = { editor.selectRevision(it.revision) },
                                onRestore = { editor.restore(it.revision) }, onDecision = editor::resolveDecision,
                                onConflict = editor::resolveConflict, onClearQuote = editor::clearReviewQuote,
                                modifier = modifier, backLabel = R.string.share_back)
                        }
                        ShareDestination.Closed -> Unit
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        entry.setForeground(this, true)
        when (val destination = entry.destination.value) {
            is ShareDestination.Filling -> {
                refreshPicker()
            }
            is ShareDestination.Editing -> destination.editor.refresh()
            else -> Unit
        }
    }

    override fun onPause() {
        entry.setForeground(this, false)
        super.onPause()
    }

    private fun refreshPicker() {
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!isFinishing) entry.start(ShareIntentDecoder.read(intent))
        setIntent(Intent())
    }

    override fun onDestroy() {
        entry.detach(this)
        if (isFinishing) entry.close()
        super.onDestroy()
    }
}
